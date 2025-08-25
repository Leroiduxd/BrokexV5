// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * Brokex Vault
 * - Stocke et règle la marge, les commissions et le PnL des ordres/positions.
 * - Les fonctions critiques sont appelables uniquement par brokexStorage.
 * - Compliant avec l'exigence réseau: CHAIN_ID = 688688 (constante exposée).
 */

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract BrokexVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---- Constantes / Config ----
    uint256 public constant CHAIN_ID = 688688;

    IERC20 public immutable asset;            // stablecoin utilisé pour les règlements
    address public brokexStorage;             // seul cet addr peut appeler les fonctions cœur
    address public commissionReceiver;        // reçoit les commissions (solde interne + retrait)
    address public pnlBank;                   // banque PnL (receiver/payeur)

    // ---- Etats ----
    struct LockedOrder {
        address trader;
        uint256 margin;
        uint256 commission;
    }

    struct Position {
        address trader;
        uint256 margin; // marge encore immobilisée (hors commissions déjà envoyées)
    }

    mapping(uint256 => LockedOrder) private orders;     // orderId => LockedOrder
    mapping(uint256 => Position)    private positions;  // positionId => Position

    // soldes internes par adresse (on garde historiques si on change de receiver)
    mapping(address => uint256) public accruedCommission;
    mapping(address => uint256) public pnlBankBalance; // solde disponible pour payer PnL positifs

    // ---- Events ----
    event StorageUpdated(address indexed oldAddr, address indexed newAddr);
    event CommissionReceiverUpdated(address indexed oldAddr, address indexed newAddr);
    event PnlBankUpdated(address indexed oldAddr, address indexed newAddr);

    event OrderDeposited(uint256 indexed orderId, address indexed trader, uint256 margin, uint256 commission);
    event OrderRefunded(uint256 indexed orderId, address indexed trader, uint256 amount);
    event OrderConverted(uint256 indexed orderId, uint256 indexed positionId, address indexed trader, uint256 margin, uint256 commissionToReceiver);

    event PositionClosed(
            uint256 indexed positionId,
            address indexed trader,
            int256 pnl,
            uint256 closingCommission,
            uint256 traderPayout,
            int256 pnlBankDelta // + : la banque encaisse, - : la banque paie
        );

    event CommissionWithdrawn(address indexed receiver, uint256 amount);
    event PnlBankReplenished(address indexed bank, uint256 amount);
    event PnlBankWithdrawn(address indexed bank, uint256 amount);

    // ---- Modifiers ----
    modifier onlyStorage() {
        require(msg.sender == brokexStorage, "BrokexVault: only storage");
        _;
    }

    // ---- Constructor ----
    constructor(
        address _asset,
        address _brokexStorage,
        address _commissionReceiver,
        address _pnlBank
    ) Ownable(msg.sender) {
        require(_asset != address(0), "asset=0");
        require(_brokexStorage != address(0), "storage=0");
        require(_commissionReceiver != address(0), "commissionReceiver=0");
        require(_pnlBank != address(0), "pnlBank=0");

        asset = IERC20(_asset);
        brokexStorage = _brokexStorage;
        commissionReceiver = _commissionReceiver;
        pnlBank = _pnlBank;
    }

    // ---- Admin (owner) ----
    function setBrokexStorage(address _storage) external onlyOwner {
        require(_storage != address(0), "storage=0");
        emit StorageUpdated(brokexStorage, _storage);
        brokexStorage = _storage;
    }

    function setCommissionReceiver(address _receiver) external onlyOwner {
        require(_receiver != address(0), "receiver=0");
        emit CommissionReceiverUpdated(commissionReceiver, _receiver);
        commissionReceiver = _receiver;
    }

    function setPnlBank(address _pnlBank) external onlyOwner {
        require(_pnlBank != address(0), "pnlBank=0");
        emit PnlBankUpdated(pnlBank, _pnlBank);
        pnlBank = _pnlBank;
    }

    // ---- Flux PnL bank (le bank peut alimenter ou retirer son solde) ----

    /// @notice Dépose des fonds dans la banque PnL (réserve pour payer les PnL positifs)
    /// @dev nécessite allowance vers ce contrat
    function pnlBankReplenish(uint256 amount) external nonReentrant {
        require(msg.sender == pnlBank, "only pnlBank");
        require(amount > 0, "amount=0");
        asset.safeTransferFrom(msg.sender, address(this), amount);
        pnlBankBalance[pnlBank] += amount;
        emit PnlBankReplenished(pnlBank, amount);
    }

    /// @notice Retire des fonds disponibles de la banque PnL
    function pnlBankWithdraw(uint256 amount) external nonReentrant {
        require(msg.sender == pnlBank, "only pnlBank");
        require(amount > 0, "amount=0");
        require(pnlBankBalance[pnlBank] >= amount, "pnl reserve insufficient");
        pnlBankBalance[pnlBank] -= amount;
        asset.safeTransfer(pnlBank, amount);
        emit PnlBankWithdrawn(pnlBank, amount);
    }

    // ---- Commission receiver ----
    function withdrawCommission(uint256 amount) external nonReentrant {
        address receiver = msg.sender;
        require(accruedCommission[receiver] >= amount, "insufficient commission");
        accruedCommission[receiver] -= amount;
        asset.safeTransfer(receiver, amount);
        emit CommissionWithdrawn(receiver, amount);
    }

    // ---- Cœur: Ordres & Positions (uniquement brokexStorage) ----

    /**
     * @notice Dépose marge + commission pour un ordre.
     * @dev Le prélèvement se fait sur le TRADER via transferFrom, donc
     *      le trader doit avoir approuvé le Vault au préalable.
     */
    function depositForOrder(
        uint256 orderId,
        address trader,
        uint256 margin,
        uint256 commission
    ) external onlyStorage nonReentrant {
        require(trader != address(0), "trader=0");
        require(margin > 0, "margin=0");
        require(orders[orderId].trader == address(0), "order exists");
        require(positions[orderId].trader == address(0), "id collision");

        uint256 total = margin + commission;
        asset.safeTransferFrom(trader, address(this), total);

        orders[orderId] = LockedOrder({
            trader: trader,
            margin: margin,
            commission: commission
        });

        emit OrderDeposited(orderId, trader, margin, commission);
    }

    /**
     * @notice Rembourse marge + commission d'un ordre en attente.
     */
    function refundOrder(uint256 orderId) external onlyStorage nonReentrant {
        LockedOrder memory o = orders[orderId];
        require(o.trader != address(0), "order not found");

        delete orders[orderId];

        uint256 refundAmount = o.margin + o.commission;
        asset.safeTransfer(o.trader, refundAmount);

        emit OrderRefunded(orderId, o.trader, refundAmount);
    }

    /**
     * @notice Convertit un ordre en position :
     *  - supprime le mapping de l'ordre
     *  - crée la position avec la marge
     *  - crédite la commission au solde du commissionReceiver
     */
    function convertOrderToPosition(uint256 orderId, uint256 positionId) external onlyStorage nonReentrant {
        LockedOrder memory o = orders[orderId];
        require(o.trader != address(0), "order not found");
        require(positions[positionId].trader == address(0), "position exists");

        delete orders[orderId];

        positions[positionId] = Position({ trader: o.trader, margin: o.margin });
        accruedCommission[commissionReceiver] += o.commission;

        emit OrderConverted(orderId, positionId, o.trader, o.margin, o.commission);
    }

    /**
     * @notice Ferme une position.
     * @param positionId id de la position
     * @param pnl PnL du trader (positif = gain pour le trader, négatif = perte pour le trader)
     * @param closingCommission commission à prélever à la fermeture (soustraite de la marge)
     *
     * Règles:
     *  - closingCommission est ajoutée au solde du commissionReceiver.
     *  - Si pnl < 0: la perte est créditée à la banque PnL (dans la limite de la marge restante),
     *                le reste de marge (s'il en reste) est remboursé au trader.
     *  - Si pnl > 0: on paie le trader (marge restante + pnl) et on débite la banque PnL du montant pnl.
     *                Nécessite que la banque PnL ait un solde suffisant.
     *  - Si pnl == 0: la marge restante (après commission) est remboursée au trader.
     */
    function closePosition(
        uint256 positionId,
        int256 pnl,
        uint256 closingCommission
    ) external onlyStorage nonReentrant {
        Position memory p = positions[positionId];
        require(p.trader != address(0), "position not found");

        // Retirer la position AVANT transferts (sécurité reentrancy)
        delete positions[positionId];

        // 1) Prélever la commission de fermeture sur la marge disponible
        require(p.margin >= closingCommission, "closing fee > margin");
        uint256 marginAfterFee = p.margin - closingCommission;
        accruedCommission[commissionReceiver] += closingCommission;

        uint256 traderPayout = 0;
        int256 pnlBankDelta = 0;

        if (pnl < 0) {
            uint256 loss = uint256(-pnl);

            // La perte est prélevée sur la marge restante et "va" à la banque PnL
            uint256 toBank = loss > marginAfterFee ? marginAfterFee : loss;
            if (toBank > 0) {
                pnlBankBalance[pnlBank] += toBank;
                pnlBankDelta = int256(toBank); // + : banque augmente
                marginAfterFee -= toBank;
            }

            // Tout reste de marge va au trader
            if (marginAfterFee > 0) {
                traderPayout = marginAfterFee;
                asset.safeTransfer(p.trader, traderPayout);
            }
        } else if (pnl > 0) {
            uint256 profit = uint256(pnl);

            // La banque PnL doit disposer du profit à payer
            require(pnlBankBalance[pnlBank] >= profit, "pnl bank insufficient");

            // Payer trader: marge restante + profit
            traderPayout = marginAfterFee + profit;
            pnlBankBalance[pnlBank] -= profit;
            pnlBankDelta = -int256(profit); // - : banque diminue

            asset.safeTransfer(p.trader, traderPayout);
        } else {
            // pnl == 0 → rembourser la marge restante
            if (marginAfterFee > 0) {
                traderPayout = marginAfterFee;
                asset.safeTransfer(p.trader, traderPayout);
            }
        }

        emit PositionClosed(positionId, p.trader, pnl, closingCommission, traderPayout, pnlBankDelta);
    }

    // ---- Lectures utilitaires ----
    function getOrder(uint256 orderId) external view returns (LockedOrder memory) {
        return orders[orderId];
    }

    function getPosition(uint256 positionId) external view returns (Position memory) {
        return positions[positionId];
    }
}
