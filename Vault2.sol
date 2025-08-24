// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title BrokexVault - Gestion de marges, commissions et PnL pour Brokex
/// @notice Déployez avec l'ERC20 utilisé (USDT/USDC), l'adresse commissionReceiver et l'adresse pnlVault.
/// @dev Compatible EVM (ex: Pharos Testnet chainId 688688). Aucune import externe requise.

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address a) external view returns (uint256);
    function transfer(address to, uint256 v) external returns (bool);
    function allowance(address o, address s) external view returns (uint256);
    function approve(address s, uint256 v) external returns (bool);
    function transferFrom(address f, address t, uint256 v) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        bytes memory data = abi.encodeWithSelector(token.transfer.selector, to, value);
        (bool ok, bytes memory ret) = address(token).call(data);
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "TRANSFER_FAILED");
    }
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        bytes memory data = abi.encodeWithSelector(token.transferFrom.selector, from, to, value);
        (bool ok, bytes memory ret) = address(token).call(data);
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "TRANSFER_FROM_FAILED");
    }
}

abstract contract Ownable {
    address public owner;
    modifier onlyOwner() { require(msg.sender == owner, "ONLY_OWNER"); _; }
    constructor() { owner = msg.sender; }
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "ZERO_OWNER");
        owner = newOwner;
    }
}

abstract contract ReentrancyGuard {
    uint256 private _status;
    constructor() { _status = 1; }
    modifier nonReentrant() {
        require(_status == 1, "REENTRANCY");
        _status = 2;
        _;
        _status = 1;
    }
}

contract BrokexVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // === Config & rôles ===
    IERC20  public immutable token;            // ex: USDT/USDC
    address public executor;                   // autorisé à convertir/fermer/rembourser
    address public commissionReceiver;         // celui qui encaisse les commissions
    address public pnlVault;                   // récepteur/payeur de PnL (pool)

    modifier onlyExecutor() { require(msg.sender == executor, "ONLY_EXECUTOR"); _; }
    modifier onlyCommissionReceiver() { require(msg.sender == commissionReceiver, "ONLY_COMMISSION_RECEIVER"); _; }
    modifier onlyPnlVault() { require(msg.sender == pnlVault, "ONLY_PNL_VAULT"); _; }

    constructor(IERC20 _token, address _commissionReceiver, address _pnlVault) {
        require(address(_token) != address(0), "ZERO_TOKEN");
        require(_commissionReceiver != address(0), "ZERO_COMM");
        require(_pnlVault != address(0), "ZERO_PNL");
        token = _token;
        commissionReceiver = _commissionReceiver;
        pnlVault = _pnlVault;
        executor = msg.sender; // par défaut
    }

    function setExecutor(address _exec) external onlyOwner {
        require(_exec != address(0), "ZERO_EXEC");
        executor = _exec;
    }
    function setCommissionReceiver(address _cr) external onlyOwner {
        require(_cr != address(0), "ZERO_COMM");
        commissionReceiver = _cr;
    }
    function setPnlVault(address _pnl) external onlyOwner {
        require(_pnl != address(0), "ZERO_PNL");
        pnlVault = _pnl;
    }

    // === États ===

    struct OrderFunds {
        uint256 margin;        // marge bloquée pour l'ordre
        uint256 commission;    // commission associée à l'ordre
        address trader;        // propriétaire
    }

    // Ordres en attente (marge+commission conservées ici jusqu'à conversion/annulation)
    mapping(uint256 => OrderFunds) public orders; // orderId => funds

    // Positions ouvertes (marge immobilisée sur la position)
    mapping(uint256 => uint256) public positionMargin; // positionId => margin
    mapping(uint256 => address) public positionTrader; // positionId => trader

    // Commissions cumulées (retirables par commissionReceiver)
    uint256 public commissionAccrued;

    // Solde interne du pnlVault détenu dans ce contrat (sert à payer les profits)
    uint256 public pnlVaultBalance;

    // === Events ===

    event OrderDeposited(uint256 indexed orderId, address indexed trader, uint256 margin, uint256 commission);
    event OrderRefunded(uint256 indexed orderId, address indexed trader, uint256 amount);
    event OrderConverted(uint256 indexed orderId, uint256 indexed positionId, address indexed trader, uint256 margin, uint256 commission);
    event CommissionAccrued(uint256 amount);
    event CommissionWithdrawn(address indexed to, uint256 amount);
    event PnlVaultDeposited(uint256 amount);
    event PnlVaultWithdrawn(address indexed to, uint256 amount);
    event PositionClosed(
        uint256 indexed positionId,
        address indexed trader,
        int256 pnl,
        uint256 closingCommission,
        uint256 traderPayout,
        int256 poolDelta // +ve = le pool encaisse, -ve = le pool paye
    );

    // === Helpers vue ===
    function getOrderLocked(uint256 orderId) external view returns (uint256 margin, uint256 commission, address trader) {
        OrderFunds memory f = orders[orderId];
        return (f.margin, f.commission, f.trader);
    }

    function getPosition(uint256 positionId) external view returns (address trader, uint256 margin) {
        return (positionTrader[positionId], positionMargin[positionId]);
    }

    // === 1) Dépôt pour un ordre: prélève marge + commission du trader ===
    function depositForOrder(uint256 orderId, uint256 margin, uint256 commission) external nonReentrant {
        require(orderId != 0, "ORDERID_0");
        require(orders[orderId].trader == address(0), "ORDER_EXISTS");
        require(margin > 0, "MARGIN_0");
        // commission peut être 0 si nécessaire

        uint256 total = margin + commission;
        token.safeTransferFrom(msg.sender, address(this), total);

        orders[orderId] = OrderFunds({
            margin: margin,
            commission: commission,
            trader: msg.sender
        });

        emit OrderDeposited(orderId, msg.sender, margin, commission);
    }

    // === 2) Remboursement d'un ordre (marge + commission) ===
    function refundOrder(uint256 orderId, address to) external onlyExecutor nonReentrant {
        OrderFunds memory f = orders[orderId];
        require(f.trader != address(0), "ORDER_NOT_FOUND");
        require(to == f.trader, "TO_NEQ_TRADER"); // sécurité: on renvoie au vrai trader

        delete orders[orderId];

        uint256 amount = f.margin + f.commission;
        token.safeTransfer(to, amount);

        emit OrderRefunded(orderId, to, amount);
    }

    // === 3) Transformer un ordre en position ===
    /// @dev Commission de l'ordre est accumulée pour commissionReceiver, marge devient marge de la position.
    function convertOrderToPosition(uint256 orderId, uint256 positionId) external onlyExecutor nonReentrant {
        require(positionId != 0, "POSITIONID_0");
        require(positionTrader[positionId] == address(0), "POSITION_EXISTS");

        OrderFunds memory f = orders[orderId];
        require(f.trader != address(0), "ORDER_NOT_FOUND");

        // Accumule commission pour retrait ultérieur
        if (f.commission > 0) {
            commissionAccrued += f.commission;
            emit CommissionAccrued(f.commission);
        }

        // Crée la position
        positionMargin[positionId] = f.margin;
        positionTrader[positionId] = f.trader;

        // Supprime l'ordre
        delete orders[orderId];

        emit OrderConverted(orderId, positionId, f.trader, f.margin, f.commission);
    }

    // === 4) Retrait de commission par le commissionReceiver ===
    function withdrawCommission(uint256 amount, address to) external onlyCommissionReceiver nonReentrant {
        require(to != address(0), "ZERO_TO");
        require(amount > 0 && amount <= commissionAccrued, "BAD_AMOUNT");
        commissionAccrued -= amount;
        token.safeTransfer(to, amount);
        emit CommissionWithdrawn(to, amount);
    }

    // === 5) Gestion du PnL Vault (dépôt/retrait) ===
    function pnlVaultDeposit(uint256 amount) external onlyPnlVault nonReentrant {
        require(amount > 0, "AMOUNT_0");
        token.safeTransferFrom(msg.sender, address(this), amount);
        pnlVaultBalance += amount;
        emit PnlVaultDeposited(amount);
    }

    function pnlVaultWithdraw(uint256 amount, address to) external onlyPnlVault nonReentrant {
        require(to != address(0), "ZERO_TO");
        require(amount > 0 && amount <= pnlVaultBalance, "BAD_AMOUNT");
        pnlVaultBalance -= amount;
        token.safeTransfer(to, amount);
        emit PnlVaultWithdrawn(to, amount);
    }

    // === 6) Fermer une position ===
    /// @param positionId id de la position à fermer
    /// @param pnl PnL du trader (positif => on lui doit; négatif => il perd)
    /// @param closingCommission commission de clôture (prélevée sur la marge)
    ///
    /// Logique:
    /// - closingCommission est ajoutée à commissionAccrued et retirée de la marge.
    /// - Si pnl >= 0: on paie profit au trader depuis pnlVaultBalance; il reçoit (marginNet + pnl).
    /// - Si pnl < 0: le pool encaisse min(|pnl|, marginNet); le trader récupère le reliquat éventuel.
    function closePosition(uint256 positionId, int256 pnl, uint256 closingCommission)
        external
        onlyExecutor
        nonReentrant
    {
        address trader = positionTrader[positionId];
        require(trader != address(0), "POSITION_NOT_FOUND");

        uint256 margin = positionMargin[positionId];
        delete positionMargin[positionId];
        delete positionTrader[positionId];

        // Commission de clôture prélevée sur la marge
        require(closingCommission <= margin, "FEE_GT_MARGIN");
        uint256 marginNet = margin - closingCommission;

        if (closingCommission > 0) {
            commissionAccrued += closingCommission;
            emit CommissionAccrued(closingCommission);
        }

        uint256 traderPayout;
        int256 poolDelta;

        if (pnl >= 0) {
            // Profit pour le trader: payé par le pool
            uint256 profit = uint256(pnl);
            require(pnlVaultBalance >= profit, "POOL_INSUFF");
            pnlVaultBalance -= profit;                    // le pool paye
            traderPayout = marginNet + profit;            // trader récupère marge nette + profit
            poolDelta = -int256(profit);                  // delta pool négatif (il a payé)
            token.safeTransfer(trader, traderPayout);
        } else {
            // Perte pour le trader: le pool encaisse jusqu'à la marge dispo
            uint256 loss = uint256(-pnl);
            uint256 poolGain = loss > marginNet ? marginNet : loss; // ce que le pool encaisse effectivement
            pnlVaultBalance += poolGain;                 // le pool reçoit
            poolDelta = int256(poolGain);                // delta pool positif (il encaisse)
            uint256 refund = marginNet > loss ? (marginNet - loss) : 0; // reliquat éventuel pour le trader
            traderPayout = refund;
            if (refund > 0) {
                token.safeTransfer(trader, refund);
            }
            // Si loss > marginNet, le surplus de perte n'est pas prélevé (aucune dette créée ici).
        }

        emit PositionClosed(positionId, trader, pnl, closingCommission, traderPayout, poolDelta);
    }
}

