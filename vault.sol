// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Interface ERC20 minimale + SafeERC20 (compat USDT)
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address a) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address s, uint256 v) external returns (bool);
    function transfer(address to, uint256 v) external returns (bool);
    function transferFrom(address f, address t, uint256 v) external returns (bool);
}

library SafeERC20 {
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        bool ok = token.transferFrom(from, to, value);
        require(ok, "transferFrom failed");
    }
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        bool ok = token.transfer(to, value);
        require(ok, "transfer failed");
    }
}

/// @notice Ownable minimal
abstract contract Ownable {
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    address public owner;
    modifier onlyOwner() {
        require(msg.sender == owner, "only owner");
        _;
    }
    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero addr");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}

/// @title BrokexVault — gestion des dépôts USDT (marge + commission) et association aux positions
/// @dev Dépôt: prélève marge + commission séparément.
///      - Commission envoyée directement au feeReceiver
///      - Marge retenue dans le vault, d'abord associée à un ordre (market/limit) par son id
///      - Quand l'ordre s’exécute, on map l’id de position -> marge (sans la commission)
contract BrokexVault is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdt;

    /// @dev Compte qui reçoit les commissions
    address public feeReceiver;

    /// ========= États =========

    // Marge en attente par ID d'ordre
    mapping(uint256 => uint256) public pendingMarginMarket; // orderId (market) -> marge
    mapping(uint256 => uint256) public pendingMarginLimit;  // orderId (limit)  -> marge

    // Marge associée aux positions (sans commission)
    mapping(uint256 => uint256) public positionMargin;      // positionId -> marge

    // Comptage (optionnel / monitoring)
    uint256 public totalFeesAccrued;   // cumul des commissions envoyées au feeReceiver
    uint256 public totalVaultMargin;   // somme des marges détenues par le vault (pending + positions)

    /// ========= Events =========
    event FeeReceiverChanged(address indexed oldReceiver, address indexed newReceiver);

    event DepositedForOrder(
        address indexed trader,
        uint256 indexed orderId,
        bool isLimit,
        uint256 marginAmount,
        uint256 commissionAmount
    );

    event OrderLinkedToPosition(
        uint256 indexed orderId,
        bool isLimit,
        uint256 indexed positionId,
        uint256 marginMoved
    );

    /// ========= Constructor =========
    constructor(address usdt_, address feeReceiver_) {
        require(usdt_ != address(0) && feeReceiver_ != address(0), "zero addr");
        usdt = IERC20(usdt_);
        feeReceiver = feeReceiver_;
    }

    /// ========= Admin =========
    function setFeeReceiver(address newReceiver) external onlyOwner {
        require(newReceiver != address(0), "zero addr");
        emit FeeReceiverChanged(feeReceiver, newReceiver);
        feeReceiver = newReceiver;
    }

    /// ========= Core logique =========

    /// @notice Dépose la marge et la commission pour un ordre (market ou limit).
    /// @param orderId      ID de l'ordre
    /// @param isLimit      true = limit, false = market
    /// @param marginAmount Montant de marge (USDT) à déposer
    /// @param feeAmount    Montant de commission (USDT) à prélever
    ///
    /// @dev Prélève `marginAmount` vers le vault et `feeAmount` vers le feeReceiver.
    ///      Le caller doit avoir fait approve(vault, marginAmount + feeAmount) côté USDT.
    function depositForOrder(
        uint256 orderId,
        bool isLimit,
        uint256 marginAmount,
        uint256 feeAmount
    ) external {
        require(orderId != 0, "orderId=0");
        require(marginAmount > 0, "margin=0");
        // Commission peut être 0 si promo, etc.

        // 1) Prélever la marge au vault
        usdt.safeTransferFrom(msg.sender, address(this), marginAmount);
        totalVaultMargin += marginAmount;

        // 2) Prélever/Envoyer la commission au feeReceiver
        if (feeAmount > 0) {
            usdt.safeTransferFrom(msg.sender, feeReceiver, feeAmount);
            totalFeesAccrued += feeAmount;
        }

        // 3) Enregistrer la marge côté ordre
        if (isLimit) {
            pendingMarginLimit[orderId] += marginAmount;
        } else {
            pendingMarginMarket[orderId] += marginAmount;
        }

        emit DepositedForOrder(msg.sender, orderId, isLimit, marginAmount, feeAmount);
    }

    /// @notice Associe la marge d’un ordre (market/limit) à une position une fois l’ordre exécuté.
    /// @param orderId    ID de l’ordre
    /// @param isLimit    true = limit, false = market
    /// @param positionId ID de la position créée
    ///
    /// @dev Déplace la marge pendante (liée à l’ordre) vers `positionMargin[positionId]`.
    ///      Commission déjà prélevée au dépôt, rien à bouger ici.
    function linkOrderToPosition(
        uint256 orderId,
        bool isLimit,
        uint256 positionId
    ) external {
        require(orderId != 0, "orderId=0");
        require(positionId != 0, "positionId=0");

        uint256 m;
        if (isLimit) {
            m = pendingMarginLimit[orderId];
            require(m > 0, "no limit margin");
            delete pendingMarginLimit[orderId];
        } else {
            m = pendingMarginMarket[orderId];
            require(m > 0, "no market margin");
            delete pendingMarginMarket[orderId];
        }

        // Associer à la position
        positionMargin[positionId] += m;

        emit OrderLinkedToPosition(orderId, isLimit, positionId, m);
    }

    /// @notice Vue utilitaire: marge pendante d’un ordre (market/limit)
    function getPendingMargin(uint256 orderId, bool isLimit) external view returns (uint256) {
        return isLimit ? pendingMarginLimit[orderId] : pendingMarginMarket[orderId];
    }

    /// @notice Vue utilitaire: marge totale détenue par le vault (pending + positions)
    /// @dev `totalVaultMargin` est maintenu à jour lors des dépôts; si vous ajoutez des retraits,
    ///      pensez à le décrémenter.
    function getTotalVaultMargin() external view returns (uint256) {
        return totalVaultMargin;
    }
}
