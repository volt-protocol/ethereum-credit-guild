// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StorageSlot} from "./StorageSlot.sol";

/// @title Util contract to manage reentrancy
abstract contract EntryGuard {
    using StorageSlot for *;

    // keccak256(abi.encode(uint256(keccak256("ecg.storage.gateway.originalSender")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _SLOT_ORIGINAL_SENDER =
        keccak256(abi.encode(uint256(keccak256("ecg.storage.gateway.originalSender")) - 1)) & ~bytes32(uint256(0xff));

    modifier entryPoint() {
        require(
            _SLOT_ORIGINAL_SENDER.asAddress().tload() == address(0),
            "EntryGuard: original sender already set"
        );
        _SLOT_ORIGINAL_SENDER.asAddress().tstore(msg.sender);
        _;
        _SLOT_ORIGINAL_SENDER.asAddress().tstore(address(0));
    }

    modifier afterEntry() {
        require(
            _SLOT_ORIGINAL_SENDER.asAddress().tload() != address(0),
            "EntryGuard: originalSender not set"
        );
        _;
    }
}
