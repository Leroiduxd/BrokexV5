// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * BrokexProxy (infos annexes / registry traders)
 * - Assets numérotés (assetIndex => catégorie, listed)
 * - Catégories: 0=Actions, 1=Forex, 2=Métaux, 3=Indices, 4=Cryptos
 * - Ouverture/Fermeture d'un marché par catégorie
 * - Commission par catégorie (USD par million, en 1e18)
 * - Overnight par asset, long/short (en basis points PAR HEURE, peut être négatif)
 * - Helpers de calcul en USD (1e18) pour commission et overnight
 *
 * Réseau ciblé: CHAIN_ID = 688688 (Pharos)
 */

import "@openzeppelin/contracts/access/Ownable.sol";

contract BrokexProxy is Ownable {
    // ---- Constantes ----
    uint256 public constant CHAIN_ID = 688688;
    uint8   public constant CAT_ACTIONS = 0;
    uint8   public constant CAT_FOREX   = 1;
    uint8   public constant CAT_METAUX  = 2;
    uint8   public constant CAT_INDICES = 3;
    uint8   public constant CAT_CRYPTOS = 4;
    uint8   public constant MAX_CATEGORY = 4; // 0..4 inclus
    uint256 private constant ONE = 1e18;

    // ---- Modèle d'asset ----
    struct AssetMeta {
        bool  listed;     // asset listé ?
        uint8 category;   // 0..4
    }

    // assetIndex => meta
    mapping(uint256 => AssetMeta) public assets;

    // ---- Statut marché par catégorie ----
    // true = ouvert, false = fermé
    mapping(uint8 => bool) public categoryOpen;

    // ---- Commission par catégorie ----
    // USD par million de notionnel, encodé en 1e18 (ex: 80$ => 80e18)
    mapping(uint8 => uint256) public categoryCommissionUsdPerMillion1e18;

    // ---- Overnight par asset ----
    // Basis points PAR HEURE (bps = 1/10000) ; peut être négatif => int256
    mapping(uint256 => int256) public overnightLongBpsPerHour;  // assetIndex => bps/h
    mapping(uint256 => int256) public overnightShortBpsPerHour; // assetIndex => bps/h

    // ---- Événements ----
    event AssetListed(uint256 indexed assetIndex, uint8 category);
    event AssetDelisted(uint256 indexed assetIndex);
    event CategoryMarketSet(uint8 indexed category, bool open);
    event CategoryCommissionSet(uint8 indexed category, uint256 usdPerMillion1e18);
    event OvernightFeesSet(uint256 indexed assetIndex, int256 longBpsPerHour, int256 shortBpsPerHour);

    // ---- Erreurs ----
    error WrongChain();
    error InvalidCategory(uint8 category);
    error AlreadyListed(uint256 assetIndex);
    error NotListed(uint256 assetIndex);

    // ---- Constructeur ----
    constructor() {
        if (block.chainid != CHAIN_ID) revert WrongChain();

        // Par défaut on ouvre tout (tu peux fermer ensuite par catégorie)
        for (uint8 c = 0; c <= MAX_CATEGORY; c++) {
            categoryOpen[c] = true;
        }
    }

    // =========================================================
    // ===============  LISTING / DELISTING ASSETS  ============
    // =========================================================

    function listAsset(uint256 assetIndex, uint8 category) external onlyOwner {
        _checkCategory(category);
        AssetMeta storage a = assets[assetIndex];
        if (a.listed) revert AlreadyListed(assetIndex);
        a.listed = true;
        a.category = category;
        emit AssetListed(assetIndex, category);
    }

    function delistAsset(uint256 assetIndex) external onlyOwner {
        AssetMeta storage a = assets[assetIndex];
        if (!a.listed) revert NotListed(assetIndex);
        a.listed = false;
        emit AssetDelisted(assetIndex);
    }

    // Lecture rapide
    function getAsset(uint256 assetIndex) external view returns (bool listed, uint8 category) {
        AssetMeta storage a = assets[assetIndex];
        return (a.listed, a.category);
    }

    // =========================================================
    // ===============  MARCHÉ PAR CATÉGORIE  ==================
    // =========================================================

    // Tu fournis juste le numéro de la catégorie (0..4) et l'état désiré
    function setCategoryMarket(uint8 category, bool open) external onlyOwner {
        _checkCategory(category);
        categoryOpen[category] = open;
        emit CategoryMarketSet(category, open);
    }

    // Helper: est-ce que l'asset est tradable ? (listé ET catégorie ouverte)
    function isTradingAllowed(uint256 assetIndex) external view returns (bool) {
        AssetMeta storage a = assets[assetIndex];
        return a.listed && categoryOpen[a.category];
    }

    // =========================================================
    // ===============  COMMISSION PAR CATÉGORIE  ==============
    // =========================================================

    /**
     * @notice Définit la commission par catégorie en USD par million (1e18).
     * Exemples:
     *  - Forex à 80$ / million  => usdPerMillion1e18 = 80e18
     *  - Crypto à 400$ / million => usdPerMillion1e18 = 400e18
     * Payée à l’achat ET à la vente (2 côtés) — à calculer côté caller si besoin.
     */
    function setCategoryCommissionPerMillionUsd(uint8 category, uint256 usdPerMillion1e18) external onlyOwner {
        _checkCategory(category);
        categoryCommissionUsdPerMillion1e18[category] = usdPerMillion1e18;
        emit CategoryCommissionSet(category, usdPerMillion1e18);
    }

    /**
     * @notice Estimation de commission (USD 1e18) pour un seul côté (buy OU sell)
     * @param notionalUsd1e18 Notionnel USD en 1e18 (ex: quantité * prix(1e18))
     * @param category        Catégorie 0..4
     * @param bothSides       Si true, multiplie par 2 (achat + vente)
     */
    function estimateCommissionUsd(
        uint256 notionalUsd1e18,
        uint8 category,
        bool bothSides
    ) external view returns (uint256 commissionUsd1e18) {
        _checkCategory(category);
        uint256 perMillion = categoryCommissionUsdPerMillion1e18[category]; // USD 1e18 / 1,000,000 USD
        // commission = (notionalUSD / 1e6) * perMillion
        // Attention aux échelles: (notional1e18 * perMillion) / 1e6 / 1e18
        uint256 oneSide = (notionalUsd1e18 * perMillion) / 1_000_000 / ONE;
        commissionUsd1e18 = bothSides ? oneSide * 2 : oneSide;
    }

    // =========================================================
    // ===============  OVERNIGHT PAR ASSET  ===================
    // =========================================================

    /**
     * @notice Définit les taux overnight (par asset) en bps/heure (peut être négatif).
     * Exemple: +5 bps/heure => 5 ; -3 bps/heure => -3
     */
    function setOvernightFees(
        uint256 assetIndex,
        int256 longBpsPerHour,
        int256 shortBpsPerHour
    ) external onlyOwner {
        if (!assets[assetIndex].listed) revert NotListed(assetIndex);
        overnightLongBpsPerHour[assetIndex]  = longBpsPerHour;
        overnightShortBpsPerHour[assetIndex] = shortBpsPerHour;
        emit OvernightFeesSet(assetIndex, longBpsPerHour, shortBpsPerHour);
    }

    function getOvernightFees(uint256 assetIndex) external view returns (int256 longBpsPerHour, int256 shortBpsPerHour) {
        longBpsPerHour  = overnightLongBpsPerHour[assetIndex];
        shortBpsPerHour = overnightShortBpsPerHour[assetIndex];
    }

    /**
     * @notice Helper: calcule le coût overnight sur la période (USD 1e18), selon long/short.
     * @param openTs           Timestamp d'ouverture (seconds)
     * @param closeTs          Timestamp de fermeture (seconds)
     * @param notionalUsd1e18  Notionnel moyen en USD (1e18) sur la période
     * @param isLong           true si position long, false si short
     * @param assetIndex       Index de l'asset
     * @return feeUsd1e18      Coût (ou rebate si négatif) en USD 1e18
     * @return hoursCount      Nombre d'heures entières facturées
     *
     * Formule: fee = notional * (bpsPerHour / 10_000) * hours
     */
    function estimateOvernightUsd(
        uint256 openTs,
        uint256 closeTs,
        uint256 notionalUsd1e18,
        bool isLong,
        uint256 assetIndex
    ) external view returns (int256 feeUsd1e18, uint256 hoursCount) {
        require(closeTs >= openTs, "close < open");
        require(assets[assetIndex].listed, "asset not listed");
        hoursCount = (closeTs - openTs) / 3600;

        int256 bpsPerHour = isLong ? overnightLongBpsPerHour[assetIndex] : overnightShortBpsPerHour[assetIndex];
        // fee = notional * (bpsPerHour * hours) / 10_000
        int256 totalBps = bpsPerHour * int256(hoursCount);
        // Conserve l'échelle 1e18 de notional
        feeUsd1e18 = (int256(notionalUsd1e18) * totalBps) / 10_000;
    }

    // =========================================================
    // ====================  INTERNES  =========================
    // =========================================================

    function _checkCategory(uint8 category) internal pure {
        if (category > MAX_CATEGORY) revert InvalidCategory(category);
    }
}

