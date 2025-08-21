// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract BrokexOrders {
    // =========
    // Structs
    // =========
    struct MarketOrder {
        address trader;
        uint256 id;
        uint256 assetIndex;
        bool    isLong;
        uint256 leverage;
        uint256 sizeAsset;
        uint256 sizeUsd;
        uint256 stopLoss;
        uint256 takeProfit;
        uint256 liquidationPrice;
    }

    struct LimitOrder {
        address trader;
        uint256 id;
        uint256 assetIndex;
        bool    isLong;
        uint256 leverage;
        uint256 sizeAsset;
        uint256 sizeUsd;
        uint256 targetPrice;
        uint256 stopLoss;
        uint256 takeProfit;
        uint256 liquidationPrice;
    }

    struct Position {
        address trader;
        uint256 id;
        uint256 assetIndex;
        bool    isLong;
        uint256 leverage;
        uint256 sizeAsset;
        uint256 sizeUsd;
        uint256 openPrice;
        uint256 openTimestamp;
    }

    // =========================
    // Compteurs (globaux)
    // =========================
    uint256 public marketOrderCount;
    uint256 public limitOrderCount;
    uint256 public positionCount;

    // IDs dédiés pour SL / TP / LIQ (uniquement pour Positions)
    uint256 public slIdCounter;
    uint256 public tpIdCounter;
    uint256 public liqIdCounter;

    // =========================
    // Stockage par id
    // =========================
    mapping(uint256 => MarketOrder) public marketOrders;
    mapping(uint256 => LimitOrder)  public limitOrders;
    mapping(uint256 => Position)    public positions;

    // =========================
    // SL / TP / LIQ par Position — valeurs + IDs
    // =========================
    mapping(uint256 => uint256) public positionStopLoss;          // positionId => SL price
    mapping(uint256 => uint256) public positionSLId;              // positionId => SL id

    mapping(uint256 => uint256) public positionTakeProfit;        // positionId => TP price
    mapping(uint256 => uint256) public positionTPId;              // positionId => TP id

    mapping(uint256 => uint256) public positionLiquidationPrice;  // positionId => LIQ price
    mapping(uint256 => uint256) public positionLiquidationId;     // positionId => LIQ id

    // =========================
    // Reverse indexes: SL/TP/LIQ id -> positionId
    // =========================
    mapping(uint256 => uint256) public slIdToPositionId;
    mapping(uint256 => uint256) public tpIdToPositionId;
    mapping(uint256 => uint256) public liqIdToPositionId;

    // =========================
    // Events
    // =========================
    event MarketOrderCreated(
        uint256 indexed id,
        address indexed trader,
        uint256 assetIndex,
        bool isLong,
        uint256 leverage,
        uint256 sizeAsset,
        uint256 sizeUsd,
        uint256 stopLoss,
        uint256 takeProfit,
        uint256 liquidationPrice
    );

    event LimitOrderCreated(
        uint256 indexed id,
        address indexed trader,
        uint256 assetIndex,
        bool isLong,
        uint256 leverage,
        uint256 sizeAsset,
        uint256 sizeUsd,
        uint256 targetPrice,
        uint256 stopLoss,
        uint256 takeProfit,
        uint256 liquidationPrice
    );

    event PositionOpened(
        uint256 indexed id,
        address indexed trader,
        uint256 assetIndex,
        bool isLong,
        uint256 leverage,
        uint256 sizeAsset,
        uint256 sizeUsd,
        uint256 openPrice,
        uint256 openTimestamp
    );

    event PositionStopLossUpdated(uint256 indexed positionId, uint256 oldId, uint256 newId, uint256 value);
    event PositionTakeProfitUpdated(uint256 indexed positionId, uint256 oldId, uint256 newId, uint256 value);
    event PositionLiquidationSet(uint256 indexed positionId, uint256 oldId, uint256 newId, uint256 value);
    event PositionRiskCleared(uint256 indexed positionId, uint256 oldSlId, uint256 oldTpId, uint256 oldLiqId);

    // =========================
    // Create a Market Order
    // =========================
    function createMarketOrder(
        uint256 assetIndex,
        bool    isLong,
        uint256 leverage,
        uint256 sizeAsset,
        uint256 sizeUsd,
        uint256 stopLoss,
        uint256 takeProfit,
        uint256 liquidationPrice
    ) external returns (uint256 id) {
        require(leverage > 0, "leverage=0");
        require(sizeAsset > 0 || sizeUsd > 0, "size=0");

        id = ++marketOrderCount;
        marketOrders[id] = MarketOrder({
            trader: msg.sender,
            id: id,
            assetIndex: assetIndex,
            isLong: isLong,
            leverage: leverage,
            sizeAsset: sizeAsset,
            sizeUsd: sizeUsd,
            stopLoss: stopLoss,
            takeProfit: takeProfit,
            liquidationPrice: liquidationPrice
        });

        emit MarketOrderCreated(
            id, msg.sender, assetIndex, isLong, leverage, sizeAsset, sizeUsd, stopLoss, takeProfit, liquidationPrice
        );
    }

    // =========================
    // Create a Limit Order
    // =========================
    function createLimitOrder(
        uint256 assetIndex,
        bool    isLong,
        uint256 leverage,
        uint256 sizeAsset,
        uint256 sizeUsd,
        uint256 targetPrice,
        uint256 stopLoss,
        uint256 takeProfit,
        uint256 liquidationPrice
    ) external returns (uint256 id) {
        require(leverage > 0, "leverage=0");
        require(sizeAsset > 0 || sizeUsd > 0, "size=0");
        require(targetPrice > 0, "targetPrice=0");

        id = ++limitOrderCount;
        limitOrders[id] = LimitOrder({
            trader: msg.sender,
            id: id,
            assetIndex: assetIndex,
            isLong: isLong,
            leverage: leverage,
            sizeAsset: sizeAsset,
            sizeUsd: sizeUsd,
            targetPrice: targetPrice,
            stopLoss: stopLoss,
            takeProfit: takeProfit,
            liquidationPrice: liquidationPrice
        });

        emit LimitOrderCreated(
            id, msg.sender, assetIndex, isLong, leverage, sizeAsset, sizeUsd, targetPrice, stopLoss, takeProfit, liquidationPrice
        );
    }

    // =========================
    // Open a Position
    // =========================
    function openPosition(
        uint256 assetIndex,
        bool    isLong,
        uint256 leverage,
        uint256 sizeAsset,
        uint256 sizeUsd,
        uint256 openPrice
    ) external returns (uint256 id) {
        require(leverage > 0, "leverage=0");
        require(sizeAsset > 0 || sizeUsd > 0, "size=0");
        require(openPrice > 0, "openPrice=0");

        id = ++positionCount;
        positions[id] = Position({
            trader: msg.sender,
            id: id,
            assetIndex: assetIndex,
            isLong: isLong,
            leverage: leverage,
            sizeAsset: sizeAsset,
            sizeUsd: sizeUsd,
            openPrice: openPrice,
            openTimestamp: block.timestamp
        });

        emit PositionOpened(
            id, msg.sender, assetIndex, isLong, leverage, sizeAsset, sizeUsd, openPrice, block.timestamp
        );
    }

    // =========================
    // Setters SL / TP — assignent un NOUVEL ID et suppriment l'ancien (avec reverse index)
    // =========================
    function setPositionStopLoss(uint256 positionId, uint256 value) external {
        Position memory p = _requireExistingPosition(positionId);
        require(msg.sender == p.trader, "not position trader");
        require(value > 0, "sl=0");

        uint256 oldId = positionSLId[positionId];
        if (oldId != 0) {
            // clear reverse index of the old SL id
            delete slIdToPositionId[oldId];
        }

        uint256 newId = ++slIdCounter;

        positionSLId[positionId]      = newId;
        positionStopLoss[positionId]  = value;
        slIdToPositionId[newId]       = positionId;

        emit PositionStopLossUpdated(positionId, oldId, newId, value);
    }

    function setPositionTakeProfit(uint256 positionId, uint256 value) external {
        Position memory p = _requireExistingPosition(positionId);
        require(msg.sender == p.trader, "not position trader");
        require(value > 0, "tp=0");

        uint256 oldId = positionTPId[positionId];
        if (oldId != 0) {
            // clear reverse index of the old TP id
            delete tpIdToPositionId[oldId];
        }

        uint256 newId = ++tpIdCounter;

        positionTPId[positionId]        = newId;
        positionTakeProfit[positionId]  = value;
        tpIdToPositionId[newId]         = positionId;

        emit PositionTakeProfitUpdated(positionId, oldId, newId, value);
    }

    // =========================
    // Setter LIQ — ne peut PAS être modifié (une seule fois)
    // =========================
    function setPositionLiquidation(uint256 positionId, uint256 value) external {
        Position memory p = _requireExistingPosition(positionId);
        require(msg.sender == p.trader, "not position trader");
        require(value > 0, "liq=0");
        require(positionLiquidationId[positionId] == 0, "liq:already set");

        uint256 oldId = 0; // jamais défini auparavant
        uint256 newId = ++liqIdCounter;

        positionLiquidationId[positionId]    = newId;
        positionLiquidationPrice[positionId] = value;
        liqIdToPositionId[newId]             = positionId;

        emit PositionLiquidationSet(positionId, oldId, newId, value);
    }

    // =========================
    // Clear total — supprime SL / TP / LIQ (prix + IDs) + reverse indexes
    // =========================
    function clearPositionRisk(uint256 positionId) external {
        Position memory p = _requireExistingPosition(positionId);
        require(msg.sender == p.trader, "not position trader");

        uint256 oldSlId  = positionSLId[positionId];
        uint256 oldTpId  = positionTPId[positionId];
        uint256 oldLiqId = positionLiquidationId[positionId];

        if (oldSlId != 0) delete slIdToPositionId[oldSlId];
        if (oldTpId != 0) delete tpIdToPositionId[oldTpId];
        if (oldLiqId != 0) delete liqIdToPositionId[oldLiqId];

        delete positionSLId[positionId];
        delete positionStopLoss[positionId];

        delete positionTPId[positionId];
        delete positionTakeProfit[positionId];

        delete positionLiquidationId[positionId];
        delete positionLiquidationPrice[positionId];

        emit PositionRiskCleared(positionId, oldSlId, oldTpId, oldLiqId);
    }

    // =========================
    // Internal helpers
    // =========================
    function _requireExistingPosition(uint256 positionId) internal view returns (Position memory) {
        require(positionId != 0 && positionId <= positionCount, "position:not found");
        Position memory p = positions[positionId];
        require(p.trader != address(0), "position:empty");
        return p;
    }
}
