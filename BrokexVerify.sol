// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * Mini vérif ECDSA (EIP-712) pour une seule adresse signataire autorisée.
 * Champs signés: orderId, execPriceX8, side (0=LONG, 1=SHORT)
 * - verifyFill(..., sig) -> bool (view)
 * - validateFill(..., sig) -> consomme orderId (anti-replay) et retourne (orderId, execPriceX8, side)
 */
contract MiniFillVerifier is EIP712, Ownable {
    using ECDSA for bytes32;

    /// @notice adresse autorisée à signer
    address public authorizedSigner;

    /// @notice anti-replay basé sur l'unicité de orderId
    mapping(uint256 => bool) public usedOrderId;

    /// @dev typehash exact de la structure signée
    bytes32 private constant MINIFILL_TYPEHASH =
        keccak256("MiniFill(uint256 orderId,uint256 execPriceX8,uint8 side)");

    event SignerChanged(address indexed oldSigner, address indexed newSigner);
    event FillValidated(uint256 orderId, uint256 execPriceX8, uint8 side, address indexed recovered);

    constructor(address initialSigner)
        EIP712("BrokexMiniProof", "1")
        Ownable(msg.sender) // OZ v5: passe l'owner initial au constructeur
    {
        require(initialSigner != address(0), "signer=0");
        authorizedSigner = initialSigner;
        emit SignerChanged(address(0), initialSigner);
    }

    function setAuthorizedSigner(address newSigner) external onlyOwner {
        require(newSigner != address(0), "signer=0");
        emit SignerChanged(authorizedSigner, newSigner);
        authorizedSigner = newSigner;
    }

    // -------- EIP-712 hashing --------

    function _hashMiniFill(
        uint256 orderId,
        uint256 execPriceX8,
        uint8 side
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(MINIFILL_TYPEHASH, orderId, execPriceX8, side));
    }

    function _digestMiniFill(
        uint256 orderId,
        uint256 execPriceX8,
        uint8 side
    ) internal view returns (bytes32) {
        return _hashTypedDataV4(_hashMiniFill(orderId, execPriceX8, side));
    }

    // -------- Lecture: vérification pure --------

    function verifyFill(
        uint256 orderId,
        uint256 execPriceX8,
        uint8 side,
        bytes calldata signature
    ) external view returns (bool) {
        bytes32 digest = _digestMiniFill(orderId, execPriceX8, side);
        address recovered = ECDSA.recover(digest, signature);
        return (recovered != address(0) && recovered == authorizedSigner);
    }

    /// @notice helper debug: qui a signé ?
    function recoveredSigner(
        uint256 orderId,
        uint256 execPriceX8,
        uint8 side,
        bytes calldata signature
    ) external view returns (address) {
        bytes32 digest = _digestMiniFill(orderId, execPriceX8, side);
        return ECDSA.recover(digest, signature);
    }

    // -------- État: validation + anti-replay + retour des paramètres --------

    function validateFill(
        uint256 orderId,
        uint256 execPriceX8,
        uint8 side,
        bytes calldata signature
    )
        external
        returns (uint256 _orderId, uint256 _execPriceX8, uint8 _side)
    {
        require(!usedOrderId[orderId], "orderId used");
        usedOrderId[orderId] = true;

        bytes32 digest = _digestMiniFill(orderId, execPriceX8, side);
        address recovered = ECDSA.recover(digest, signature);
        require(recovered == authorizedSigner, "bad signer");

        emit FillValidated(orderId, execPriceX8, side, recovered);
        return (orderId, execPriceX8, side);
    }
}
