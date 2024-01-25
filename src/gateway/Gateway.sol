// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";

/// @title ECG Gateway
/// @notice Gateway to interract via multicall with the ECG
/// Owner can select which calls are allowed
abstract contract Gateway is Ownable, Pausable {
    /// @notice Emitted when an external call fails with an error.
    error CallExternalError(bytes innerError);

    // never allow transferFrom to be whitelisted
    // this avoid human error
    bytes4 public immutable transferFromSelector =
        bytes4(keccak256("transferFrom(address,address,uint256)"));

    /// @notice emitted when a call is allowed or not by the function allowCall
    event CallAllowed(
        address indexed target,
        bytes4 functionSelector,
        bool isAllowed
    );

    address internal _originalSender = address(1);

    /// @notice mapping of allowed signatures per target address
    /// For example allowing "approve" on a token
    mapping(address => mapping(bytes4 => bool)) public allowedCalls;

    constructor() Ownable() Pausable() {}

    /// @notice set pausable methods to paused
    function pause() public onlyOwner {
        _pause();
    }

    /// @notice set pausable methods to unpaused
    function unpause() public onlyOwner {
        _unpause();
    }

    /// @notice allow (or disallow) a function call for a target address
    function allowCall(
        address target,
        bytes4 functionSelector,
        bool allowed
    ) public onlyOwner {
        require(
            functionSelector != transferFromSelector,
            "Gateway: cannot allow transferFrom"
        );

        allowedCalls[target][functionSelector] = allowed;
        emit CallAllowed(target, functionSelector, allowed);
    }

    /// @notice Executes an external call to a specified target.
    ///         Only allows external calls to allowed target and function selector
    ///         these whitelisted calls are stored in the factory
    /// @dev    this function is only callable by the owner or if the owner initiated a flashloan (and then the flashloan contract called the contract back to continue the execution)
    /// @param target The address of the contract to call.
    /// @param data The calldata to send.
    function callExternal(
        address target,
        bytes calldata data
    ) public whenNotPaused {
        // Extract the function selector from the first 4 bytes of `data`
        bytes4 functionSelector = bytes4(data[:4]);
        require(
            allowedCalls[target][functionSelector],
            "Gateway: cannot call target"
        );

        (bool success, bytes memory result) = target.call(data);
        if (!success) {
            _getRevertMsg(result);
        }
    }

    /// @notice Executes multiple calls in a single transaction.
    /// and if amount > 0, tries to transfer From the sender
    /// @param calls An array of call data to execute.
    function multicall(bytes[] calldata calls) public whenNotPaused {
        require(
            _originalSender == address(1),
            "Gateway: original sender already set"
        );

        _originalSender = msg.sender;

        _executeCalls(calls);

        _originalSender = address(1);
    }

    /// @notice
    /// @dev can only be used from the multicall function that sets "_originalSender"
    function consumePermit(
        address token,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public {
        require(_originalSender != address(1), "Gateway: Original sender not set in consumePermit");
        IERC20Permit(token).permit(
            _originalSender,
            address(this),
            amount,
            deadline,
            v,
            r,
            s
        );
    }

    /// @notice
    /// @dev can only be used from the multicall function that sets "_originalSender"
    function consumeAllowance(address token, uint256 amount) public {
        require(
            _originalSender != address(1),
            "Gateway: Original sender not set in consumeAllowance"
        );
        IERC20(token).transferFrom(_originalSender, address(this), amount);
    }

    /// @notice allows sweeping remaining token on the gateway
    ///         should be used at the end of a multicall
    /// @dev can only be used from the multicall function that sets "_originalSender"
    /// @dev anyone can sweep any token from this contract
    function sweep(address token) public {
        require(
            _originalSender != address(1),
            "Gateway: Original sender not set in sweep"
        );
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).transfer(_originalSender, balance);
        }
    }

    /// @dev Executes a series of calls using call on this contract.
    /// @param calls An array of call data to execute.
    function _executeCalls(bytes[] memory calls) internal {
        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory result) = address(this).call(calls[i]);
            if (!success) {
                _getRevertMsg(result);
            }
        }
    }

    /// @dev Extracts a revert message from failed call return data.
    /// @param _returnData The return data from the failed call.
    function _getRevertMsg(bytes memory _returnData) internal pure {
        // If the _res length is less than 68, then
        // the transaction failed with custom error or silently (without a revert message)
        if (_returnData.length < 68) {
            revert CallExternalError(_returnData);
        }

        assembly {
            // Slice the sighash.
            _returnData := add(_returnData, 0x04)
        }
        revert(abi.decode(_returnData, (string))); // All that remains is the revert string
    }
}
