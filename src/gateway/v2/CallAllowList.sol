// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

abstract contract CallAllowList is Ownable {

    /// @notice emitted when a call is allowed or not by the function allowCall
    event CallAllowed(
        address indexed target,
        bytes4 selector,
        bool isAllowed
    );

    /// @notice mapping of allowed signatures per target address
    /// For example allowing "approve" on a token
    mapping(address => mapping(bytes4 => bool)) public allowedCalls;

    /// @notice allow by function address + selector
    function allowCall(
        address target,
        bytes4 selector,
        bool allowed
    ) public virtual onlyOwner {
        _allowCall(target, selector, allowed);
    }

    function _allowCall(
        address target,
        bytes4 selector,
        bool allowed
    ) internal {
        allowedCalls[target][selector] = allowed;
        emit CallAllowed(target, selector, allowed);
    }

    /// @notice view function to return true if a call is allowed
    function _callAllowed(address target, bytes memory data) internal returns (bool) {
        bytes4 selector = _getSelector(data);
        if (selector == 0x23b872dd) {
            // never allow transferFrom(address,uint256)
            return false;
        }
        if (allowedCalls[target][selector]) {
            return true;
        }
        if (_dynamicAllowCall(target, selector)) {
            _allowCall(target, selector, true);
            return true;
        }
        return false;
    }

    /// @notice optional override for dynamic addition of allowed calls
    function _dynamicAllowCall(
        address/* target*/,
        bytes4/* selector*/
    ) internal virtual returns (bool) {
        return false;
    }

    // util to extract function selector from call data
    function _getSelector(bytes memory data) internal pure returns (bytes4) {
        return bytes4(bytes.concat(data[0], data[1], data[2], data[3]));
    }
}
