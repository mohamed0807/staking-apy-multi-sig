// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract MultiSigWallet is IERC1271 {
    using MessageHashUtils for bytes32;
    using ECDSA for bytes32;

    // Events
    event OwnerAdded(address indexed owner);
    event OwnerRemoved(address indexed owner);
    event ThresholdUpdated(uint256 newThreshold);
    event Executed(address target, uint256 value, bytes data);

    // EIP-4337 EntryPoint contract
    IEntryPoint public immutable entryPoint;

    // Owners & threshold
    mapping(address => bool) public isOwner;
    address[] public owners;
    uint256 public threshold;

    // Nonce management
    uint256 public nonce;

    modifier onlyEntryPoint() {
        require(msg.sender == address(entryPoint), "Not from EntryPoint");
        _;
    }

    constructor(
        address[] memory _owners,
        uint256 _threshold,
        address _entryPoint
    ) {
        require(_owners.length >= _threshold, "Threshold too high");
        require(_threshold > 0, "Threshold must be > 0");
        require(_entryPoint != address(0), "Invalid entry point");

        entryPoint = IEntryPoint(_entryPoint);

        for (uint i = 0; i < _owners.length; i++) {
            address owner = _owners[i];
            require(owner != address(0), "Zero address");
            require(!isOwner[owner], "Duplicate owner");
            isOwner[owner] = true;
            owners.push(owner);
            emit OwnerAdded(owner);
        }

        threshold = _threshold;
        emit ThresholdUpdated(_threshold);
    }

    // Called by EntryPoint during handleOps()
    function validateUserOperation(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256
    ) external view onlyEntryPoint returns (uint256 validationData) {
        bytes32 hash = userOpHash.toEthSignedMessageHash();
        require(
            _verifySignatures(hash, userOp.signature),
            "Invalid signatures"
        );
        return 0;
    }

    function executeTransaction(
        address target,
        uint256 value,
        bytes calldata data
    ) external onlyEntryPoint {
        (bool success, ) = target.call{value: value}(data);
        require(success, "Execution failed");
        emit Executed(target, value, data);
    }

    function getNonce() external view returns (uint256) {
        return nonce;
    }

    // -- Multisig configuration management --

    function addOwner(address newOwner) external {
        require(isOwner[msg.sender], "Not owner");
        require(!isOwner[newOwner], "Already owner");
        isOwner[newOwner] = true;
        owners.push(newOwner);
        emit OwnerAdded(newOwner);
    }

    function removeOwner(address oldOwner) external {
        require(isOwner[msg.sender], "Not owner");
        require(isOwner[oldOwner], "Not an owner");
        isOwner[oldOwner] = false;
        for (uint i = 0; i < owners.length; i++) {
            if (owners[i] == oldOwner) {
                owners[i] = owners[owners.length - 1];
                owners.pop();
                break;
            }
        }
        require(owners.length >= threshold, "Owners < threshold");
        emit OwnerRemoved(oldOwner);
    }

    function updateThreshold(uint256 newThreshold) external {
        require(isOwner[msg.sender], "Not owner");
        require(
            newThreshold > 0 && newThreshold <= owners.length,
            "Invalid threshold"
        );
        threshold = newThreshold;
        emit ThresholdUpdated(newThreshold);
    }

    // -- Signature logic --

    function _verifySignatures(
        bytes32 hash,
        bytes calldata signatures
    ) internal view returns (bool) {
        uint256 validSigCount = 0;
        uint256 sigCount = signatures.length / 65;
        address[] memory seen = new address[](owners.length);
        uint256 seenCount = 0;

        for (uint i = 0; i < sigCount; i++) {
            bytes memory sig = signatures[i * 65:(i + 1) * 65];
            address recovered = hash.recover(sig);
            if (!isOwner[recovered]) continue;
            bool duplicate = false;
            for (uint j = 0; j < seenCount; j++) {
                if (seen[j] == recovered) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) {
                seen[seenCount] = recovered;
                seenCount++;
                validSigCount++;
            }
        }

        return validSigCount >= threshold;
    }

    function isValidSignature(
        bytes32 hash,
        bytes calldata signature
    ) external view override returns (bytes4) {
        if (_verifySignatures(hash, signature)) {
            return 0x1626ba7e; // ERC1271 magic value
        } else {
            return 0xffffffff;
        }
    }

    receive() external payable {}
}
