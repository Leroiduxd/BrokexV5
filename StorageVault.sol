// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * BrokexUnified
 * - Fusion de BrokexVault et BrokexStorage
 * - Stocke et règle la marge, les commissions et le PnL des ordres/positions
 * - Stocke l'état complet des ordres/positions + SL/TP/LIQ
 * - Toutes les opérations financières sont gérées en interne
 * - Compliant avec l'exigence réseau: CHAIN_ID = 688688
 */

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract BrokexUnified is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---- Constantes / Config ----
    uint256 public constant CHAIN_ID = 688688;

    IERC20 public immutable asset;            // stablecoin utilisé pour les règlements
    address public executor;                  // peut exécuter les ordres et fermer les positions
    address public commissionReceiver;        // reçoit les commissions
    address public pnlBank;                   // banque PnL (receiver/payeur)

    // ---- Structures de données ----
    
    // Structure pour les ordres en attente (avec fonds bloqués)
    struct LockedOrder {
        address trader;
        uint256 margin;
        uint256 commission;
    }

    // Structure complète des ordres
    struct Order {
        uint256 orderId;        // unique
        address trader;
        uint32  assetIndex;
        bool    isLong;
        uint256 targetPrice;    // 0 => market, !=0 => limit
        uint256 stopLoss;       // peut être 0
        uint256 takeProfit;     // peut être 0
        uint256 commission;     // payé via système interne
        uint256 margin;         // bloquée en interne
        uint256 sizeInAsset;    // ex: 1e18 pour "1"
        uint32  leverageX;      // levier demandé
    }

    // Structure pour les positions (avec fonds immobilisés)
    struct PositionVault {
        address trader;
        uint256 margin; // marge encore immobilisée (hors commissions déjà envoyées)
    }

    // Structure complète des positions
    struct Position {
        uint256 positionId;     // unique
        address trader;
        uint32  assetIndex;
        bool    isLong;
        uint256 openPrice;
        uint256 margin;         // immobilisée en interne
        uint256 sizeInAsset;
        uint64  openedAt;       // seconds
        uint32  leverageX;
    }

    // Structure pour les triggers (SL/TP/LIQ)
    enum TriggerType { StopLoss, TakeProfit, Liquidation }

    struct Trigger {
        uint256 positionId;
        uint256 price;
        TriggerType ttype;
        bool exists;
    }

    // ---- Mappings de stockage ----
    
    // Ordres avec fonds bloqués
    mapping(uint256 => LockedOrder) private lockedOrders;     // orderId => LockedOrder
    
    // Ordres complets
    mapping(uint256 => Order) public orders;                 // orderId => Order
    
    // Positions avec fonds immobilisés
    mapping(uint256 => PositionVault) private positionVaults; // positionId => PositionVault
    
    // Positions complètes
    mapping(uint256 => Position) public positions;           // positionId => Position

    // Soldes internes
    mapping(address => uint256) public accruedCommission;    // soldes commissions
    mapping(address => uint256) public pnlBankBalance;       // solde banque PnL

    // Compteurs d'IDs
    uint256 public nextOrderId = 1;
    uint256 public nextPositionId = 1;
    uint256 public nextTriggerId = 1;

    // Index par trader
    mapping(address => uint256[]) private _traderOrders;
    mapping(address => uint256[]) private _traderPositions;

    // Triggers
    mapping(uint256 => Trigger) public triggers;             // triggerId => Trigger
    mapping(uint256 => uint256) public positionSLId;         // positionId => stopLoss triggerId
    mapping(uint256 => uint256) public positionTPId;         // positionId => takeProfit triggerId
    mapping(uint256 => uint256) public positionLIQId;        // positionId => liquidation triggerId

    // ---- Modifiers ----
    modifier onlyExecutor() {
        require(msg.sender == executor, "ONLY_EXECUTOR");
        _;
    }

    // ---- Events ----
    
    // Events du Vault
    event ExecutorUpdated(address indexed oldAddr, address indexed newAddr);
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
        int256 pnlBankDelta
    );

    event CommissionWithdrawn(address indexed receiver, uint256 amount);
    event PnlBankReplenished(address indexed bank, uint256 amount);
    event PnlBankWithdrawn(address indexed bank, uint256 amount);

    // Events du Storage
    event OrderCreated(
        uint256 indexed orderId,
        address indexed trader,
        uint32 assetIndex,
        bool isLong,
        uint256 targetPrice,
        uint256 stopLoss,
        uint256 takeProfit,
        uint256 commission,
        uint256 margin,
        uint256 sizeInAsset,
        uint32 leverageX
    );

    event OrderCancelled(uint256 indexed orderId, address indexed trader);

    event OrderExecutedToPosition(
        uint256 indexed orderId,
        uint256 indexed positionId,
        address indexed trader,
        uint256 openPrice,
        uint64 openedAt
    );

    event StopLossChanged(
        uint256 indexed positionId,
        uint256 oldTriggerId,
        uint256 newTriggerId,
        uint256 newPrice
    );

    event TakeProfitChanged(
        uint256 indexed positionId,
        uint256 oldTriggerId,
        uint256 newTriggerId,
        uint256 newPrice
    );

    event LiquidationPriceSet(
        uint256 indexed positionId,
        uint256 triggerId,
        uint256 liqPrice
    );

    event PositionDeleted(
        uint256 indexed positionId,
        address indexed trader,
        int256 pnl,
        uint256 closingCommission
    );

    // ---- Constructor ----
    constructor(
        address _asset,
        address _executor,
        address _commissionReceiver,
        address _pnlBank
    ) Ownable(msg.sender) {
        require(_asset != address(0), "asset=0");
        require(_executor != address(0), "executor=0");
        require(_commissionReceiver != address(0), "commissionReceiver=0");
        require(_pnlBank != address(0), "pnlBank=0");

        asset = IERC20(_asset);
        executor = _executor;
        commissionReceiver = _commissionReceiver;
        pnlBank = _pnlBank;
    }

    // ---- Fonctions d'administration (owner) ----
    
    function setExecutor(address _exec) external onlyOwner {
        require(_exec != address(0), "EXEC_0");
        emit ExecutorUpdated(executor, _exec);
        executor = _exec;
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

    // ---- Gestion de la banque PnL ----

    /// @notice Dépose des fonds dans la banque PnL
    function pnlBankReplenish(uint256 amount) external nonReentrant {
        require(msg.sender == pnlBank, "only pnlBank");
        require(amount > 0, "amount=0");
        asset.safeTransferFrom(msg.sender, address(this), amount);
        pnlBankBalance[pnlBank] += amount;
        emit PnlBankReplenished(pnlBank, amount);
    }

    /// @notice Retire des fonds de la banque PnL
    function pnlBankWithdraw(uint256 amount) external nonReentrant {
        require(msg.sender == pnlBank, "only pnlBank");
        require(amount > 0, "amount=0");
        require(pnlBankBalance[pnlBank] >= amount, "pnl reserve insufficient");
        pnlBankBalance[pnlBank] -= amount;
        asset.safeTransfer(pnlBank, amount);
        emit PnlBankWithdrawn(pnlBank, amount);
    }

    // ---- Retrait des commissions ----
    
    function withdrawCommission(uint256 amount) external nonReentrant {
        address receiver = msg.sender;
        require(accruedCommission[receiver] >= amount, "insufficient commission");
        accruedCommission[receiver] -= amount;
        asset.safeTransfer(receiver, amount);
        emit CommissionWithdrawn(receiver, amount);
    }

    // ---- Fonctions utilitaires pour les arrays ----
    
    function _pushId(mapping(address => uint256[]) storage arr, address a, uint256 id_) internal {
        arr[a].push(id_);
    }

    function _removeId(mapping(address => uint256[]) storage arr, address a, uint256 id_) internal {
        uint256[] storage list = arr[a];
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == id_) {
                list[i] = list[list.length - 1];
                list.pop();
                break;
            }
        }
    }

    // ---- Fonctions internes remplaçant les appels au Vault ----

    /// @notice Dépose marge + commission pour un ordre (interne)
    function _depositForOrder(
        uint256 orderId,
        address trader,
        uint256 margin,
        uint256 commission
    ) internal {
        require(trader != address(0), "trader=0");
        require(margin > 0, "margin=0");
        require(lockedOrders[orderId].trader == address(0), "order exists");
        require(positionVaults[orderId].trader == address(0), "id collision");

        uint256 total = margin + commission;
        asset.safeTransferFrom(trader, address(this), total);

        lockedOrders[orderId] = LockedOrder({
            trader: trader,
            margin: margin,
            commission: commission
        });

        emit OrderDeposited(orderId, trader, margin, commission);
    }

    /// @notice Rembourse un ordre (interne)
    function _refundOrder(uint256 orderId) internal {
        LockedOrder memory o = lockedOrders[orderId];
        require(o.trader != address(0), "order not found");

        delete lockedOrders[orderId];

        uint256 refundAmount = o.margin + o.commission;
        asset.safeTransfer(o.trader, refundAmount);

        emit OrderRefunded(orderId, o.trader, refundAmount);
    }

    /// @notice Convertit un ordre en position (interne)
    function _convertOrderToPosition(uint256 orderId, uint256 positionId) internal {
        LockedOrder memory o = lockedOrders[orderId];
        require(o.trader != address(0), "order not found");
        require(positionVaults[positionId].trader == address(0), "position exists");

        delete lockedOrders[orderId];

        positionVaults[positionId] = PositionVault({ trader: o.trader, margin: o.margin });
        accruedCommission[commissionReceiver] += o.commission;

        emit OrderConverted(orderId, positionId, o.trader, o.margin, o.commission);
    }

    /// @notice Ferme une position (interne)
    function _closePosition(
        uint256 positionId,
        int256 pnl,
        uint256 closingCommission
    ) internal {
        PositionVault memory p = positionVaults[positionId];
        require(p.trader != address(0), "position not found");

        delete positionVaults[positionId];

        require(p.margin >= closingCommission, "closing fee > margin");
        uint256 marginAfterFee = p.margin - closingCommission;
        accruedCommission[commissionReceiver] += closingCommission;

        uint256 traderPayout = 0;
        int256 pnlBankDelta = 0;

        if (pnl < 0) {
            uint256 loss = uint256(-pnl);
            uint256 toBank = loss > marginAfterFee ? marginAfterFee : loss;
            if (toBank > 0) {
                pnlBankBalance[pnlBank] += toBank;
                pnlBankDelta = int256(toBank);
                marginAfterFee -= toBank;
            }
            if (marginAfterFee > 0) {
                traderPayout = marginAfterFee;
                asset.safeTransfer(p.trader, traderPayout);
            }
        } else if (pnl > 0) {
            uint256 profit = uint256(pnl);
            require(pnlBankBalance[pnlBank] >= profit, "pnl bank insufficient");
            traderPayout = marginAfterFee + profit;
            pnlBankBalance[pnlBank] -= profit;
            pnlBankDelta = -int256(profit);
            asset.safeTransfer(p.trader, traderPayout);
        } else {
            if (marginAfterFee > 0) {
                traderPayout = marginAfterFee;
                asset.safeTransfer(p.trader, traderPayout);
            }
        }

        emit PositionClosed(positionId, p.trader, pnl, closingCommission, traderPayout, pnlBankDelta);
    }

    // ---- Lifecycle des ordres ----

    /// @notice Crée un ordre et dépose les fonds
    /// @dev Le trader peut créer son propre ordre, ou l'executor peut créer un ordre au nom d'un trader
    function createOrder(
        address trader,
        uint32 assetIndex,
        bool   isLong,
        uint256 targetPrice,   // 0->market
        uint256 stopLoss,
        uint256 takeProfit,
        uint256 commission,
        uint256 margin,
        uint256 sizeInAsset,
        uint32  leverageX
    ) external nonReentrant returns (uint256 orderId) {
        require(trader != address(0), "TRADER_0");
        require(margin > 0, "MARGIN_0");
        require(sizeInAsset > 0, "SIZE_0");
        require(leverageX > 0, "LEV_0");
        
        // Seul le trader lui-même ou l'executor peut créer un ordre
        require(msg.sender == trader || msg.sender == executor, "NOT_AUTH");

        orderId = nextOrderId++;
        
        // Créer l'ordre complet
        orders[orderId] = Order({
            orderId: orderId,
            trader: trader,
            assetIndex: assetIndex,
            isLong: isLong,
            targetPrice: targetPrice,
            stopLoss: stopLoss,
            takeProfit: takeProfit,
            commission: commission,
            margin: margin,
            sizeInAsset: sizeInAsset,
            leverageX: leverageX
        });

        // Bloquer les fonds (appel interne au lieu de l'interface)
        _depositForOrder(orderId, trader, margin, commission);

        _pushId(_traderOrders, trader, orderId);

        emit OrderCreated(
            orderId, trader, assetIndex, isLong, targetPrice, stopLoss, takeProfit,
            commission, margin, sizeInAsset, leverageX
        );
    }

    /// @notice Annule un ordre LIMIT et rembourse
    function cancelOrder(uint256 orderId) external nonReentrant {
        Order memory o = orders[orderId];
        require(o.trader != address(0), "ORDER_NOT_FOUND");
        require(o.targetPrice != 0, "ONLY_LIMIT");
        require(msg.sender == o.trader || msg.sender == executor, "NOT_AUTH");

        delete orders[orderId];
        _removeId(_traderOrders, o.trader, orderId);

        // Rembourser (appel interne)
        _refundOrder(orderId);
        emit OrderCancelled(orderId, o.trader);
    }

    /// @notice Exécute un ordre en position
    function executeOrderToPosition(
        uint256 orderId,
        uint256 openPrice,
        uint64  openedAt
    ) external onlyExecutor nonReentrant returns (uint256 positionId) {
        Order memory o = orders[orderId];
        require(o.trader != address(0), "ORDER_NOT_FOUND");
        require(openPrice > 0, "OPEN_PRICE_0");
        require(openedAt != 0, "OPENED_AT_0");

        positionId = nextPositionId++;

        // Convertir les fonds (appel interne)
        _convertOrderToPosition(orderId, positionId);

        // Supprimer l'ordre
        delete orders[orderId];
        _removeId(_traderOrders, o.trader, orderId);

        // Créer la position
        positions[positionId] = Position({
            positionId: positionId,
            trader: o.trader,
            assetIndex: o.assetIndex,
            isLong: o.isLong,
            openPrice: openPrice,
            margin: o.margin,
            sizeInAsset: o.sizeInAsset,
            openedAt: openedAt,
            leverageX: o.leverageX
        });
        _pushId(_traderPositions, o.trader, positionId);

        // Définir SL si fourni
        if (o.stopLoss > 0) {
            uint256 idSL = _mintTrigger(positionId, o.stopLoss, TriggerType.StopLoss);
            positionSLId[positionId] = idSL;
            emit StopLossChanged(positionId, 0, idSL, o.stopLoss);
        }

        // Définir TP si fourni
        if (o.takeProfit > 0) {
            uint256 idTP = _mintTrigger(positionId, o.takeProfit, TriggerType.TakeProfit);
            positionTPId[positionId] = idTP;
            emit TakeProfitChanged(positionId, 0, idTP, o.takeProfit);
        }

        // Calculer et définir le prix de liquidation
        uint256 liqPrice = _computeLiquidationPrice(openPrice, o.leverageX, o.isLong);
        uint256 idLiq = _mintTrigger(positionId, liqPrice, TriggerType.Liquidation);
        positionLIQId[positionId] = idLiq;
        emit LiquidationPriceSet(positionId, idLiq, liqPrice);

        emit OrderExecutedToPosition(orderId, positionId, o.trader, openPrice, openedAt);
    }

    // ---- Gestion des Stop Loss / Take Profit ----

    function setStopLoss(uint256 positionId, uint256 newPrice) external {
        Position memory p = positions[positionId];
        require(p.trader != address(0), "POS_NOT_FOUND");
        require(msg.sender == p.trader || msg.sender == executor, "NOT_AUTH");

        uint256 oldId = positionSLId[positionId];
        if (oldId != 0) {
            delete triggers[oldId];
        }
        uint256 newId = 0;
        if (newPrice > 0) {
            newId = _mintTrigger(positionId, newPrice, TriggerType.StopLoss);
        }
        positionSLId[positionId] = newId;
        emit StopLossChanged(positionId, oldId, newId, newPrice);
    }

    function setTakeProfit(uint256 positionId, uint256 newPrice) external {
        Position memory p = positions[positionId];
        require(p.trader != address(0), "POS_NOT_FOUND");
        require(msg.sender == p.trader || msg.sender == executor, "NOT_AUTH");

        uint256 oldId = positionTPId[positionId];
        if (oldId != 0) {
            delete triggers[oldId];
        }
        uint256 newId = 0;
        if (newPrice > 0) {
            newId = _mintTrigger(positionId, newPrice, TriggerType.TakeProfit);
        }
        positionTPId[positionId] = newId;
        emit TakeProfitChanged(positionId, oldId, newId, newPrice);
    }

    // ---- Fermeture de position ----

    /// @notice Ferme une position et nettoie les triggers
    function deletePosition(
        uint256 positionId,
        int256 pnl,
        uint256 closingCommission
    ) external onlyExecutor nonReentrant {
        Position memory p = positions[positionId];
        require(p.trader != address(0), "POS_NOT_FOUND");

        // Supprimer l'état local
        delete positions[positionId];
        _removeId(_traderPositions, p.trader, positionId);

        // Nettoyer les triggers
        uint256 sl = positionSLId[positionId];
        uint256 tp = positionTPId[positionId];
        uint256 liq = positionLIQId[positionId];
        if (sl != 0) delete triggers[sl];
        if (tp != 0) delete triggers[tp];
        if (liq != 0) delete triggers[liq];
        delete positionSLId[positionId];
        delete positionTPId[positionId];
        delete positionLIQId[positionId];

        // Régler les fonds (appel interne)
        _closePosition(positionId, pnl, closingCommission);

        emit PositionDeleted(positionId, p.trader, pnl, closingCommission);
    }

    // ---- Fonctions utilitaires internes ----

    function _mintTrigger(
        uint256 positionId,
        uint256 price,
        TriggerType ttype
    ) internal returns (uint256 id_) {
        require(price > 0, "PRICE_0");
        id_ = nextTriggerId++;
        triggers[id_] = Trigger({
            positionId: positionId,
            price: price,
            ttype: ttype,
            exists: true
        });
    }

    /// @notice Calcule le prix de liquidation (20% de marge restante)
    function _computeLiquidationPrice(
        uint256 openPrice,
        uint32 leverageX,
        bool isLong
    ) internal pure returns (uint256) {
        uint256 delta = (openPrice * 80) / (uint256(leverageX) * 100);
        if (isLong) {
            return openPrice > delta ? (openPrice - delta) : 1;
        } else {
            return openPrice + delta;
        }
    }

    // ---- Fonctions de lecture ----

    function getTraderOrderIds(address trader) external view returns (uint256[] memory) {
        return _traderOrders[trader];
    }

    function getTraderPositionIds(address trader) external view returns (uint256[] memory) {
        return _traderPositions[trader];
    }

    function getTriggerPosition(uint256 triggerId) external view returns (uint256) {
        require(triggers[triggerId].exists, "TRIGGER_NOT_FOUND");
        return triggers[triggerId].positionId;
    }

    function getTriggerPrice(uint256 triggerId) external view returns (uint256) {
        require(triggers[triggerId].exists, "TRIGGER_NOT_FOUND");
        return triggers[triggerId].price;
    }

    function getPositionTriggerIds(uint256 positionId)
        external
        view
        returns (uint256 slId, uint256 tpId, uint256 liqId)
    {
        return (positionSLId[positionId], positionTPId[positionId], positionLIQId[positionId]);
    }

    function getStopLossPrice(uint256 positionId) external view returns (uint256) {
        uint256 id_ = positionSLId[positionId];
        return id_ == 0 ? 0 : triggers[id_].price;
    }

    function getTakeProfitPrice(uint256 positionId) external view returns (uint256) {
        uint256 id_ = positionTPId[positionId];
        return id_ == 0 ? 0 : triggers[id_].price;
    }

    function getLiquidationPrice(uint256 positionId) external view returns (uint256) {
        uint256 id_ = positionLIQId[positionId];
        return id_ == 0 ? 0 : triggers[id_].price;
    }

    // Fonctions de lecture pour les ordres/positions du vault
    function getLockedOrder(uint256 orderId) external view returns (LockedOrder memory) {
        return lockedOrders[orderId];
    }

    function getPositionVault(uint256 positionId) external view returns (PositionVault memory) {
        return positionVaults[positionId];
    }
}
