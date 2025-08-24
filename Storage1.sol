// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title BrokexStorage avec IDs uniques pour SL/TP/LIQ
/// @notice - Ordres -> Positions (exécution supprime l'ordre, crée la position)
///         - SL/TP/LIQ : un ID unique par cible (même compteur pour tous)
///         - Modifier SL/TP = supprimer ancien ID, créer nouveau ID, event old/new
///         - LIQ = figé à l'ouverture (inchangeable)
contract BrokexStorage {
    // === Réseau demandé ===
    uint256 public constant BROKEX_CHAIN_ID = 688688;

    // === Structs ===
    struct Order {
        uint256 orderId;
        address trader;
        uint32  assetIndex;
        bool    isLong;
        uint256 targetPrice;   // 0 => Market, !=0 => Limit
        uint256 stopLoss;      // 0 si non défini
        uint256 takeProfit;    // 0 si non défini
        uint256 commission;
        uint256 margin;
        uint256 sizeInAsset;   // ex 1e18
        uint32  leverageX;     // ex 50 => 50x
    }

    struct Position {
        uint256 positionId;
        address trader;
        uint32  assetIndex;
        bool    isLong;
        uint256 openPrice;
        uint256 margin;
        uint256 sizeInAsset;
        uint32  leverageX;
        uint64  openedAt;
    }

    // === Stockage principal ===
    uint256 private _nextOrderId    = 1;
    uint256 private _nextPositionId = 1;

    mapping(uint256 => Order)    public orders;       // orderId => Order
    mapping(uint256 => Position) public positions;    // positionId => Position

    // === IDs uniques pour SL/TP/LIQ ===
    // Un seul compteur partagé
    uint256 private _nextRiskId = 1;

    // Types: 0=SL, 1=TP, 2=LIQ (optionnel en lecture)
    mapping(uint256 => uint8)   public riskKindOf;     // riskId => {0,1,2}
    mapping(uint256 => uint256) public riskPriceOf;    // riskId => prix
    mapping(uint256 => uint256) public riskPositionOf; // riskId => positionId

    // Liens position -> riskId
    mapping(uint256 => uint256) public stopLossIdOfPosition;   // positionId => riskId(SL) ou 0
    mapping(uint256 => uint256) public takeProfitIdOfPosition; // positionId => riskId(TP) ou 0
    mapping(uint256 => uint256) public liquidationIdOfPosition;// positionId => riskId(LIQ)

    // === Indexation par trader (listing d’IDs) ===
    mapping(address => uint256[]) private _ordersByTrader;
    mapping(address => uint256[]) private _positionsByTrader;
    mapping(uint256 => uint256)  private _orderIndexByTrader;     // orderId => index+1
    mapping(uint256 => uint256)  private _positionIndexByTrader;  // positionId => index+1

    // === Events ===
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

    event PositionOpened(
        uint256 indexed positionId,
        address indexed trader,
        uint32 assetIndex,
        bool isLong,
        uint256 openPrice,
        uint256 margin,
        uint256 sizeInAsset,
        uint32 leverageX,
        uint64 openedAt
    );

    // Initialisations (à l'ouverture)
    event StopLossSet(uint256 indexed positionId, uint256 indexed riskId, uint256 newSL);
    event TakeProfitSet(uint256 indexed positionId, uint256 indexed riskId, uint256 newTP);
    event LiquidationPriceSet(uint256 indexed positionId, uint256 indexed riskId, uint256 liqPrice);

    // Changements (oldId -> newId)
    event StopLossChanged(
        uint256 indexed positionId,
        uint256 indexed oldRiskId,
        uint256 indexed newRiskId,
        uint256 oldSL,
        uint256 newSL
    );
    event TakeProfitChanged(
        uint256 indexed positionId,
        uint256 indexed oldRiskId,
        uint256 indexed newRiskId,
        uint256 oldTP,
        uint256 newTP
    );

    event PositionDeleted(uint256 indexed positionId, address indexed trader);

    // === Errors ===
    error NotTrader();
    error NotFound();
    error BadParams();
    error OnlyLimitCanCancel();

    // === Utils: indexation par trader ===
    function _pushOrderId(address trader, uint256 id) internal {
        _ordersByTrader[trader].push(id);
        _orderIndexByTrader[id] = _ordersByTrader[trader].length; // 1-based
    }
    function _removeOrderId(address trader, uint256 id) internal {
        uint256 idx1 = _orderIndexByTrader[id];
        if (idx1 == 0) return;
        uint256 idx = idx1 - 1;
        uint256 last = _ordersByTrader[trader].length - 1;
        if (idx != last) {
            uint256 moved = _ordersByTrader[trader][last];
            _ordersByTrader[trader][idx] = moved;
            _orderIndexByTrader[moved] = idx + 1;
        }
        _ordersByTrader[trader].pop();
        delete _orderIndexByTrader[id];
    }
    function _pushPositionId(address trader, uint256 id) internal {
        _positionsByTrader[trader].push(id);
        _positionIndexByTrader[id] = _positionsByTrader[trader].length; // 1-based
    }
    function _removePositionId(address trader, uint256 id) internal {
        uint256 idx1 = _positionIndexByTrader[id];
        if (idx1 == 0) return;
        uint256 idx = idx1 - 1;
        uint256 last = _positionsByTrader[trader].length - 1;
        if (idx != last) {
            uint256 moved = _positionsByTrader[trader][last];
            _positionsByTrader[trader][idx] = moved;
            _positionIndexByTrader[moved] = idx + 1;
        }
        _positionsByTrader[trader].pop();
        delete _positionIndexByTrader[id];
    }

    // === Création d'un ordre ===
    function createOrder(
        uint32  assetIndex,
        bool    isLong,
        uint256 targetPrice,  // 0 => Market, !=0 => Limit
        uint256 stopLoss,
        uint256 takeProfit,
        uint256 commission,
        uint256 margin,
        uint256 sizeInAsset,
        uint32  leverageX
    ) external returns (uint256 orderId) {
            if (leverageX == 0 || sizeInAsset == 0 || margin == 0) {
            revert BadParams();
        }
        orderId = _nextOrderId++;
        Order storage o = orders[orderId];
        o.orderId      = orderId;
        o.trader       = msg.sender;
        o.assetIndex   = assetIndex;
        o.isLong       = isLong;
        o.targetPrice  = targetPrice;
        o.stopLoss     = stopLoss;
        o.takeProfit   = takeProfit;
        o.commission   = commission;
        o.margin       = margin;
        o.sizeInAsset  = sizeInAsset;
        o.leverageX    = leverageX;

        _pushOrderId(msg.sender, orderId);

        emit OrderCreated(
            orderId, msg.sender, assetIndex, isLong, targetPrice,
            stopLoss, takeProfit, commission, margin, sizeInAsset, leverageX
        );
    }

    // === Annulation ordre (uniquement LIMIT) ===
    function cancelOrder(uint256 orderId) external {
        Order storage o = orders[orderId];
        if (o.trader == address(0)) revert NotFound();
        if (o.trader != msg.sender) revert NotTrader();
        if (o.targetPrice == 0) revert OnlyLimitCanCancel();

        _removeOrderId(o.trader, orderId);
        delete orders[orderId];
        emit OrderCancelled(orderId, msg.sender);
    }

    // === Exécution: ordre -> position (supprime l'ordre) ===
    function executeOrderToPosition(
        uint256 orderId,
        uint256 openPrice,
        uint64  openedAt
    ) external returns (uint256 positionId) {
        Order storage o = orders[orderId];
        if (o.trader == address(0)) revert NotFound();
        if (o.trader != msg.sender) revert NotTrader();
        if (openPrice == 0 || openedAt == 0) revert BadParams();

        // Créer position
        positionId = _nextPositionId++;
        Position storage p = positions[positionId];
        p.positionId  = positionId;
        p.trader      = o.trader;
        p.assetIndex  = o.assetIndex;
        p.isLong      = o.isLong;
        p.openPrice   = openPrice;
        p.margin      = o.margin;
        p.sizeInAsset = o.sizeInAsset;
        p.leverageX   = o.leverageX;
        p.openedAt    = openedAt;

        _pushPositionId(p.trader, positionId);

        // Initialiser SL/TP à partir de l'ordre via nouveaux riskIds
        if (o.stopLoss != 0) {
            uint256 slId = _newRiskId(positionId, 0, o.stopLoss); // kind=0 SL
            stopLossIdOfPosition[positionId] = slId;
            emit StopLossSet(positionId, slId, o.stopLoss);
        }
        if (o.takeProfit != 0) {
            uint256 tpId = _newRiskId(positionId, 1, o.takeProfit); // kind=1 TP
            takeProfitIdOfPosition[positionId] = tpId;
            emit TakeProfitSet(positionId, tpId, o.takeProfit);
        }

        // Calculer et figer la liquidation (kind=2)
        uint256 liqPrice = _calcLiqPrice(p.isLong, p.openPrice, p.leverageX);
        uint256 liqId = _newRiskId(positionId, 2, liqPrice);
        liquidationIdOfPosition[positionId] = liqId;
        emit LiquidationPriceSet(positionId, liqId, liqPrice);

        // Supprimer l'ordre
        _removeOrderId(o.trader, orderId);
        delete orders[orderId];

        emit PositionOpened(
            positionId, p.trader, p.assetIndex, p.isLong,
            p.openPrice, p.margin, p.sizeInAsset, p.leverageX, p.openedAt
        );
    }

    // === Modifier SL (supprime ancien ID, crée nouveau ID) ===
    function setStopLoss(uint256 positionId, uint256 newSL) external {
        Position storage p = positions[positionId];
        if (p.trader == address(0)) revert NotFound();
        if (p.trader != msg.sender) revert NotTrader();

        uint256 oldId = stopLossIdOfPosition[positionId];
        uint256 oldSL = (oldId == 0) ? 0 : riskPriceOf[oldId];

        // supprimer ancien id si existant
        if (oldId != 0) {
            _deleteRiskId(oldId);
        }

        uint256 newId = 0;
        if (newSL != 0) {
            newId = _newRiskId(positionId, 0, newSL); // kind=0 SL
        }
        stopLossIdOfPosition[positionId] = newId;

        emit StopLossChanged(positionId, oldId, newId, oldSL, newSL);
        if (newId != 0) {
            emit StopLossSet(positionId, newId, newSL);
        }
    }

    // === Modifier TP (supprime ancien ID, crée nouveau ID) ===
    function setTakeProfit(uint256 positionId, uint256 newTP) external {
        Position storage p = positions[positionId];
        if (p.trader == address(0)) revert NotFound();
        if (p.trader != msg.sender) revert NotTrader();

        uint256 oldId = takeProfitIdOfPosition[positionId];
        uint256 oldTP = (oldId == 0) ? 0 : riskPriceOf[oldId];

        if (oldId != 0) {
            _deleteRiskId(oldId);
        }

        uint256 newId = 0;
        if (newTP != 0) {
            newId = _newRiskId(positionId, 1, newTP); // kind=1 TP
        }
        takeProfitIdOfPosition[positionId] = newId;

        emit TakeProfitChanged(positionId, oldId, newId, oldTP, newTP);
        if (newId != 0) {
            emit TakeProfitSet(positionId, newId, newTP);
        }
    }

    // === Suppression position (nettoie aussi SL/TP/LIQ) ===
    function deletePosition(uint256 positionId) external {
        Position storage p = positions[positionId];
        if (p.trader == address(0)) revert NotFound();
        if (p.trader != msg.sender) revert NotTrader();

        // supprimer riskIds reliés
        uint256 slId  = stopLossIdOfPosition[positionId];
        uint256 tpId  = takeProfitIdOfPosition[positionId];
        uint256 liqId = liquidationIdOfPosition[positionId];

        if (slId  != 0) _deleteRiskId(slId);
        if (tpId  != 0) _deleteRiskId(tpId);
        if (liqId != 0) _deleteRiskId(liqId);

        delete stopLossIdOfPosition[positionId];
        delete takeProfitIdOfPosition[positionId];
        delete liquidationIdOfPosition[positionId];

        _removePositionId(p.trader, positionId);
        address t = p.trader;
        delete positions[positionId];

        emit PositionDeleted(positionId, t);
    }

    // === Lectures demandées ===

    /// @notice Depuis un riskId (SL/TP/LIQ), retrouve le positionId (0 si inconnu)
    function getPositionIdByRiskId(uint256 riskId) external view returns (uint256) {
        return riskPositionOf[riskId];
    }

    /// @notice Depuis un riskId, retrouve le prix visé (0 si inconnu)
    function getRiskPriceByRiskId(uint256 riskId) external view returns (uint256) {
        return riskPriceOf[riskId];
    }

    /// @notice Depuis une position, retrouve les riskIds (slId, tpId, liqId)
    function getRiskIdsByPosition(uint256 positionId)
        external
        view
        returns (uint256 slId, uint256 tpId, uint256 liqId)
    {
        slId  = stopLossIdOfPosition[positionId];
        tpId  = takeProfitIdOfPosition[positionId];
        liqId = liquidationIdOfPosition[positionId];
    }

    /// @notice Compat: lecture directe des prix par position
    function getStopLoss(uint256 positionId) external view returns (uint256) {
        uint256 id = stopLossIdOfPosition[positionId];
        return (id == 0) ? 0 : riskPriceOf[id];
    }
    function getTakeProfit(uint256 positionId) external view returns (uint256) {
        uint256 id = takeProfitIdOfPosition[positionId];
        return (id == 0) ? 0 : riskPriceOf[id];
    }
    function getLiquidationPrice(uint256 positionId) external view returns (uint256) {
        uint256 id = liquidationIdOfPosition[positionId];
        return (id == 0) ? 0 : riskPriceOf[id];
    }

    // === Lectures listes d'IDs par trader ===
    function getOrderIdsOf(address trader) external view returns (uint256[] memory) {
        return _ordersByTrader[trader];
    }
    function getPositionIdsOf(address trader) external view returns (uint256[] memory) {
        return _positionsByTrader[trader];
    }

    // === Internes: gestion riskIds ===
    function _newRiskId(uint256 positionId, uint8 kind, uint256 price) internal returns (uint256 riskId) {
        riskId = _nextRiskId++;
        riskKindOf[riskId]     = kind;       // 0,1,2
        riskPriceOf[riskId]    = price;
        riskPositionOf[riskId] = positionId;
    }
    function _deleteRiskId(uint256 riskId) internal {
        delete riskKindOf[riskId];
        delete riskPriceOf[riskId];
        delete riskPositionOf[riskId];
    }

    // === Utilitaire: calcul liquidation (20% marge restante) ===
    /// move = 0.8 / L ; liq_long  = P*(1 - move) ; liq_short = P*(1 + move)
    function _calcLiqPrice(bool isLong, uint256 openPrice, uint32 leverageX)
        internal
        pure
        returns (uint256)
    {
        // delta = openPrice * 4 / (5 * L)  (car 0.8 = 4/5)
        uint256 delta = (openPrice * 4) / (uint256(5) * uint256(leverageX));
        return isLong ? openPrice - delta : openPrice + delta;
    }
}
