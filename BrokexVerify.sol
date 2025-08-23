// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract MiniFillVerifier is EIP712, Ownable {
    using ECDSA for bytes32;

    address public authorizedSigner;
    mapping(uint256 => bool) public usedOrderId;

    bytes32 private constant MINIFILL_TYPEHASH =
        keccak256("MiniFill(uint256 orderId,uint256 execPriceX8,uint8 side)");

    event SignerChanged(address indexed oldSigner, address indexed newSigner);
    event FillValidated(uint256 orderId, uint256 execPriceX8, uint8 side, address indexed recovered);

    constructor()
        EIP712("BrokexMiniProof", "1")
        Ownable(msg.sender)
    {
        authorizedSigner = msg.sender; // Par défaut: toi
        emit SignerChanged(address(0), msg.sender);
    }

    function setAuthorizedSigner(address newSigner) external onlyOwner {
        require(newSigner != address(0), "signer=0");
        emit SignerChanged(authorizedSigner, newSigner);
        authorizedSigner = newSigner;
    }

    function _hashMiniFill(uint256 orderId, uint256 execPriceX8, uint8 side) internal pure returns (bytes32) {
        return keccak256(abi.encode(MINIFILL_TYPEHASH, orderId, execPriceX8, side));
    }
    function _digestMiniFill(uint256 orderId, uint256 execPriceX8, uint8 side) internal view returns (bytes32) {
        return _hashTypedDataV4(_hashMiniFill(orderId, execPriceX8, side));
    }

    function verifyFill(uint256 orderId, uint256 execPriceX8, uint8 side, bytes calldata signature)
        external view returns (bool)
    {
        bytes32 digest = _digestMiniFill(orderId, execPriceX8, side);
        address recovered = ECDSA.recover(digest, signature);
        return recovered != address(0) && recovered == authorizedSigner;
    }

    function recoveredSigner(uint256 orderId, uint256 execPriceX8, uint8 side, bytes calldata signature)
        external view returns (address)
    {
        return ECDSA.recover(_digestMiniFill(orderId, execPriceX8, side), signature);
    }

    function validateFill(uint256 orderId, uint256 execPriceX8, uint8 side, bytes calldata signature)
        external returns (uint256 _orderId, uint256 _execPriceX8, uint8 _side)
    {
        require(!usedOrderId[orderId], "orderId used");
        usedOrderId[orderId] = true;

        address recovered = ECDSA.recover(_digestMiniFill(orderId, execPriceX8, side), signature);
        require(recovered == authorizedSigner, "bad signer");

        emit FillValidated(orderId, execPriceX8, side, recovered);
        return (orderId, execPriceX8, side);
    }
}

