// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

library TStorageLib {

    function _address(bytes32 slot) internal view returns (address value) {
        /// @solidity memory-safe-assembly
        assembly {
            value := tload(slot)
        }
    }

    function _address(bytes32 slot, address value) internal {
        /// @solidity memory-safe-assembly
        assembly {
            tstore(slot, value)
        }
    }
    
    function _uint256(bytes32 slot) internal view returns (uint256 value) {
        /// @solidity memory-safe-assembly
        assembly {
            value := tload(slot)
        }
    }

    function _uint256(bytes32 slot, uint256 value) internal {
        /// @solidity memory-safe-assembly
        assembly {
            tstore(slot, value)
        }
    }

    function _bytes(bytes32 slot) internal view returns (bytes memory value) {
        uint256 length;
        /// @solidity memory-safe-assembly
        assembly {
            length := tload(slot)
        }
        value = new bytes(length);
        uint256 nSlots = length / 32 + 1;
        for (uint256 slotIndex = 0; slotIndex < nSlots; slotIndex++) {
            uint256 slotValue;
            uint256 slotKey = uint256(keccak256(abi.encode(slot))) + slotIndex;
            /// @solidity memory-safe-assembly
            assembly {
                slotValue := tload(slotKey)
            }
            for (uint256 i = 0; i < 32; i++) {
                uint256 arrayIndex = slotIndex * 32 + i;
                if (arrayIndex >= length) continue;
                value[arrayIndex] = bytes1(uint8(slotValue >> (256 - (i + 1) * 8)));
            }
        }
    }

    function _bytes(bytes32 slot, bytes memory value) internal {
        uint256 length = value.length;
        uint256 nSlots = length / 32 + 1;
        /// @solidity memory-safe-assembly
        assembly {
            tstore(slot, length)
        }
        for (uint256 slotIndex = 0; slotIndex < nSlots; slotIndex++) {
            uint256 slotValue;
            uint256 slotKey = uint256(keccak256(abi.encode(slot))) + slotIndex;
            for (uint256 i = 0; i < 32; i++) {
                uint256 arrayIndex = slotIndex * 32 + i;
                if (arrayIndex >= length) continue;
                slotValue = slotValue | (uint256(uint8(value[arrayIndex])) << (256 - (i + 1) * 8));
            }
            /// @solidity memory-safe-assembly
            assembly {
                tstore(slotKey, slotValue)
            }
        }
    }
}