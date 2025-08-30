// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * BrokexStorage
 * - Stocke l'état minimal (ordres/positions + SL/TP/LIQ)
 * - Relie le flux financier au BrokexVault:
 *     createOrder          -> vault.depositForOrder
 *     cancelOrder          -> vault.refundOrder
 *     executeOrderToPosition -> vault.convertOrderToPosition
 *     deletePosition       -> vault.closePosition
 *
 * Notes:
 * - CHAIN_ID attendu: 688688 (Pharos). Pas utilisé dans la logique.
 * - Le prix de liquidation est figé à la création de la position et correspond
 *   à une marge restante de 20% (perte tolérée = 80% de la marge initiale).
 */

import "@openzeppelin/contracts/access/Ownable.sol";

interface IBrokexVault {
    function depositForOrder(
        uint256 orderId,
        address trader,
        uint256 margin,
        uint256 commission
    ) external;

    function refundOrder(uint256 orderId) external;

    function convertOrderToPosition(uint256 orderId, uint256 positionId) external;

    function closePosition(
        uint256 positionId,
        int256 pnl,
        uint256 closingCommission
    ) external;
}

contract BrokexStorage is Ownable {
    // -------------------------------------------------------
    // Roles & wiring
    // -------------------------------------------------------
    IBrokexVault public immutable vault;
    address public executor;

    modifier onlyExecutor() {
        require(msg.sender == executor, "ONLY_EXECUTOR");
        _;
    }

    constructor(address _vault, address _executor) Ownable(msg.sender) {
        require(_vault != address(0), "VAULT_0");
        require(_executor != address(0), "EXEC_0");
        vault = IBrokexVault(_vault);
        executor = _executor;
    }

    function setExecutor(address _exec) external onlyOwner {
        require(_exec != address(0), "EXEC_0");
        executor = _exec;
    }

    // -------------------------------------------------------
    // Core data
    // -------------------------------------------------------

    struct Order {
        uint256 orderId;        // unique
        address trader;
        uint32  assetIndex;
        bool    isLong;
        uint256 targetPrice;    // 0 => market, !=0 => limit
        uint256 stopLoss;       // peut être 0
        uint256 takeProfit;     // peut être 0
        uint256 commission;     // payé via Vault
        uint256 margin;         // bloquée dans Vault
        uint256 sizeInAsset;    // ex: 1e18 pour "1"
        uint32  leverageX;      // levier demandé
    }

    struct Position {
        uint256 positionId;     // unique
        address trader;
        uint32  assetIndex;
        bool    isLong;
        uint256 openPrice;
        uint256 margin;         // immobilisée dans Vault
        uint256 sizeInAsset;
        uint64  openedAt;       // seconds
        uint32  leverageX;
    }

    // Orders / Positions stores
    mapping(uint256 => Order)   public orders;     // orderId => Order
    mapping(uint256 => Position) public positions; // positionId => Position

    // Id counters
    uint256 public nextOrderId = 1;
    uint256 public nextPositionId = 1;

    // Trader indexes
    mapping(address => uint256[]) private _traderOrders;    // includes canceled until removed
    mapping(address => uint256[]) private _traderPositions;

    // -------------------------------------------------------
    // Triggers (SL/TP/LIQ) — single id space
    // -------------------------------------------------------

    enum TriggerType { StopLoss, TakeProfit, Liquidation }

    struct Trigger {
        uint256 positionId;
        uint256 price;
        TriggerType ttype;
        bool exists;
    }

    uint256 public nextTriggerId = 1; // shared for SL / TP / LIQ

    // id => Trigger
    mapping(uint256 => Trigger) public triggers;

    // position => trigger ids
    mapping(uint256 => uint256) public positionSLId;
    mapping<uint256 => uint256) public positionTPId;
    mapping<uint256 => uint256) public positionLIQId;

    // -------------------------------------------------------
    // Events
    // -------------------------------------------------------
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

    // -------------------------------------------------------
    // Helpers (arrays)
    // -------------------------------------------------------
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

    // -------------------------------------------------------
    // Public views
    // -------------------------------------------------------
    function getTraderOrderIds(address trader) external view returns (uint256[] memory) {
        return _traderOrders[trader];
    }

    function getTraderPositionIds(address trader) external view returns (uint256[] memory) {
        return _traderPositions[trader];
    }

    // Trigger reads (by trigger id)
    function getTriggerPosition(uint256 triggerId) external view returns (uint256) {
        require(triggers[triggerId].exists, "TRIGGER_NOT_FOUND");
        return triggers[triggerId].positionId;
    }

    function getTriggerPrice(uint256 triggerId) external view returns (uint256) {
        require(triggers[triggerId].exists, "TRIGGER_NOT_FOUND");
        return triggers[triggerId].price;
    }

    // Trigger reads (by position id)
    function getPositionTriggerIds(uint256 positionId)
        external
        view
        returns (uint256 slId, uint256 tpId, uint256 liqId)
    {
        return (positionSLId[positionId], positionTPId[positionId], positionLIQId[positionId]);
    }

    // Convenience reads
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

    // -------------------------------------------------------
    // Order lifecycle
    // -------------------------------------------------------

    /// @notice Crée un ordre et débite marge+commission via le Vault.
    /// @dev Le trader doit avoir fait approve(vault, margin+commission).
    function createOrder(
        uint32 assetIndex,
        bool   isLong,
        uint256 targetPrice,   // 0->market
        uint256 stopLoss,
        uint256 takeProfit,
        uint256 commission,
        uint256 margin,
        uint256 sizeInAsset,
        uint32  leverageX
    ) external returns (uint256 orderId) {
        require(margin > 0, "MARGIN_0");
        require(sizeInAsset > 0, "SIZE_0");
        require(leverageX > 0, "LEV_0");

        orderId = nextOrderId++;
        orders[orderId] = Order({
            orderId: orderId,
            trader: msg.sender,
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

        // lock funds in the vault (pulls from trader)
        vault.depositForOrder(orderId, msg.sender, margin, commission);

        _pushId(_traderOrders, msg.sender, orderId);

        emit OrderCreated(
            orderId, msg.sender, assetIndex, isLong, targetPrice, stopLoss, takeProfit,
            commission, margin, sizeInAsset, leverageX
        );
    }

    /// @notice Annule un ordre LIMIT uniquement (targetPrice != 0) et rembourse via Vault.
    function cancelOrder(uint256 orderId) external {
        Order memory o = orders[orderId];
        require(o.trader != address(0), "ORDER_NOT_FOUND");
        require(o.targetPrice != 0, "ONLY_LIMIT");
        require(msg.sender == o.trader || msg.sender == executor, "NOT_AUTH");

        delete orders[orderId];
        _removeId(_traderOrders, o.trader, orderId);

        vault.refundOrder(orderId);
        emit OrderCancelled(orderId, o.trader);
    }

    // -------------------------------------------------------
    // Execution -> Position
    // -------------------------------------------------------

    /// @notice Convertit un ordre exécuté en position ouverte.
    /// @dev Appelé par l'executor après preuve FIX/Oracle off-chain.
    ///      - Supprime l'ordre
    ///      - Crée la position
    ///      - Enregistre SL/TP si fournis
    ///      - Calcule et fige le prix de liquidation (20% de marge restante)
    function executeOrderToPosition(
        uint256 orderId,
        uint256 openPrice,
        uint64  openedAt
    ) external onlyExecutor returns (uint256 positionId) {
        Order memory o = orders[orderId];
        require(o.trader != address(0), "ORDER_NOT_FOUND");
        require(openPrice > 0, "OPEN_PRICE_0");
        require(openedAt != 0, "OPENED_AT_0");

        // new position id
        positionId = nextPositionId++;

        // convert funds state in vault
        vault.convertOrderToPosition(orderId, positionId);

        // delete order
        delete orders[orderId];
        _removeId(_traderOrders, o.trader, orderId);

        // create position
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

        // set SL if provided
        if (o.stopLoss > 0) {
            uint256 idSL = _mintTrigger(positionId, o.stopLoss, TriggerType.StopLoss);
            positionSLId[positionId] = idSL;
            emit StopLossChanged(positionId, 0, idSL, o.stopLoss);
        }

        // set TP if provided
        if (o.takeProfit > 0) {
            uint256 idTP = _mintTrigger(positionId, o.takeProfit, TriggerType.TakeProfit);
            positionTPId[positionId] = idTP;
            emit TakeProfitChanged(positionId, 0, idTP, o.takeProfit);
        }

        // compute and set LIQ (immutable)
        uint256 liqPrice = _computeLiquidationPrice(openPrice, o.leverageX, o.isLong);
        uint256 idLiq = _mintTrigger(positionId, liqPrice, TriggerType.Liquidation);
        positionLIQId[positionId] = idLiq;
        emit LiquidationPriceSet(positionId, idLiq, liqPrice);

        emit OrderExecutedToPosition(orderId, positionId, o.trader, openPrice, openedAt);
    }

    // -------------------------------------------------------
    // Update SL / TP (create new id, delete old one)
    // -------------------------------------------------------

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

    // -------------------------------------------------------
    // Close / Delete position (calls vault.closePosition)
    // -------------------------------------------------------

    /// @notice Ferme une position et nettoie SL/TP/LIQ locaux.
    /// @dev pnl et commission de clôture sont calculés/validés off-chain.
    function deletePosition(
        uint256 positionId,
        int256 pnl,
        uint256 closingCommission
    ) external onlyExecutor {
        Position memory p = positions[positionId];
        require(p.trader != address(0), "POS_NOT_FOUND");

        // erase local state
        delete positions[positionId];
        _removeId(_traderPositions, p.trader, positionId);

        // purge triggers
        uint256 sl = positionSLId[positionId];
        uint256 tp = positionTPId[positionId];
        uint256 liq = positionLIQId[positionId];
        if (sl != 0) delete triggers[sl];
        if (tp != 0) delete triggers[tp];
        if (liq != 0) delete triggers[liq];
        delete positionSLId[positionId];
        delete positionTPId[positionId];
        delete positionLIQId[positionId];

        // settle funds via vault
        vault.closePosition(positionId, pnl, closingCommission);

        emit PositionDeleted(positionId, p.trader, pnl, closingCommission);
    }

    // -------------------------------------------------------
    // Internals
    // -------------------------------------------------------
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

    /// @dev maintenance = 20% de la marge initiale => perte tolérée = 80% de la marge.
    /// Approximation en % de prix: delta% ~= 0.8 / leverageX
    /// - Long:  liq = open - open * (0.8 / L)
    /// - Short: liq = open + open * (0.8 / L)
    function _computeLiquidationPrice(
        uint256 openPrice,
        uint32 leverageX,
        bool isLong
    ) internal pure returns (uint256) {
        // delta = openPrice * 80 / (100 * L)
        uint256 delta = (openPrice * 80) / (uint256(leverageX) * 100);
        if (isLong) {
            // eviter underflow si leverage énorme/arrondi: borne minimale à 1
            return openPrice > delta ? (openPrice - delta) : 1;
        } else {
            return openPrice + delta;
        }
    }
}
