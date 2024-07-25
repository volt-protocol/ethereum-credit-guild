// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TStorageLib} from "@src/gateway/v2/TStorageLib.sol";

/// @title Util contract to manage reentrancy
abstract contract EntryGuard {

    // keccak256(abi.encode(uint256(keccak256("ecg.storage.gateway.originalSender")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _SLOT_ORIGINAL_SENDER = 0x6693a246d58d32f385e51820a8b8b6ff5c374d7a4f80507dca16a8f0445e2800;

    function _getOriginalSender() internal view returns (address) {
        return TStorageLib._address(_SLOT_ORIGINAL_SENDER);
    }

    function _setOriginalSender(address v) internal {
        TStorageLib._address(_SLOT_ORIGINAL_SENDER, v);
    }

    modifier entryPoint() {
        require(
            _getOriginalSender() == address(0),
            "EntryGuard: original sender already set"
        );
        _setOriginalSender(msg.sender);
        _;
        _setOriginalSender(address(0));
    }

    modifier afterEntry() {
        require(
            _getOriginalSender() != address(0),
            "EntryGuard: originalSender not set"
        );
        _;
    }
}
