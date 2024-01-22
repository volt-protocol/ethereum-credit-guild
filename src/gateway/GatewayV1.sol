// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title ECG Gateway V1
/// @notice Gateway to interract via multicall with the ECG
/// Owner can select which calls are allowed
/// @custom:feature flashloan from balancer vault
contract GatewayV1 is Ownable {
    /// @notice Emitted when an external call fails with an error.
    error CallExternalError(bytes innerError);

    /// @notice emitted when a call is allowed or not by the function allowCall
    event CallAllowed(
        address indexed target,
        bytes4 functionSelector,
        bool isAllowed
    );

    /// @notice Stores calls to be executed after receiving a Balancer flash loan.
    /// @dev The StoredCalls should only be set in the 'multicallWithBalancerFlashLoan' function
    ///      Which is "onlyOwner" so the StoredCalls can only be set by the owner of the contract
    bytes[] private _storedCalls;

    /// @notice mapping of allowed signatures per target address
    /// For example allowing "flashLoan" on the balancer vault
    mapping(address => mapping(bytes4 => bool)) public allowedCalls;

    /// @notice Address of the Balancer Vault, used for initiating flash loans.
    address public immutable balancerVault =
        0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    constructor() Ownable() {}

    /// @notice allow (or disallow) a function call for a target address
    function allowCall(
        address target,
        bytes4 functionSelector,
        bool allowed
    ) public onlyOwner {
        allowedCalls[target][functionSelector] = allowed;
        emit CallAllowed(target, functionSelector, allowed);
    }

    /// @notice Executes an external call to a specified target.
    ///         Only allows external calls to allowed target and function selector
    ///         these whitelisted calls are stored in the factory
    /// @dev    this function is only callable by the owner or if the owner initiated a flashloan (and then the flashloan contract called the contract back to continue the execution)
    /// @param target The address of the contract to call.
    /// @param data The calldata to send.
    function callExternal(address target, bytes calldata data) public {
        // Extract the function selector from the first 4 bytes of `data`
        bytes4 functionSelector = bytes4(data[:4]);
        require(
            allowedCalls[target][functionSelector],
            "AccountImplementation: cannot call target"
        );

        (bool success, bytes memory result) = target.call(data);
        if (!success) {
            _getRevertMsg(result);
        }
    }

    /// @notice Executes multiple calls in a single transaction.
    /// @param calls An array of call data to execute.
    function multicall(bytes[] calldata calls) public {
        _executeCalls(calls);
    }

    /// @notice Initiates a Balancer flash loan and executes specified calls before and after receiving the loan.
    /// @param tokens Array of ERC20 token addresses for the flash loan.
    /// @param amounts Array of amounts for each token in the flash loan.
    /// @param calls Calls to execute after receiving the flash loan.
    function multicallWithBalancerFlashLoan(
        IERC20[] calldata tokens,
        uint256[] calldata amounts,
        bytes[] calldata calls // Calls to be made after receiving the flash loan
    ) external {
        // Clear existing StoredCalls
        delete _storedCalls;

        // Manually copy each element
        for (uint i = 0; i < calls.length; i++) {
            _storedCalls.push(calls[i]);
        }

        // Initiate the flash loan
        IBalancerFlashLoan(balancerVault).flashLoan(
            address(this),
            tokens,
            amounts,
            ""
        );
    }

    /// @notice Handles the receipt of a flash loan, executes stored calls, and repays the loan.
    /// @param tokens Array of ERC20 tokens received in the flash loan.
    /// @param amounts Array of amounts for each token received.
    /// @param feeAmounts Array of fee amounts for each token received.
    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory /*userData*/
    ) external {
        // ensure no fees from balancer??
        // for (uint256 i = 0; i < feeAmounts.length; i++) {
        //     require(feeAmounts[i] == 0);
        // }

        require(
            msg.sender == balancerVault,
            "receiveFlashLoan: sender is not balancer"
        );

        // execute the storedCalls, enforcing that the 'receiveFlashLoan' is called
        // after having called 'multicallWithBalancerFlashLoan';
        _executeCalls(_storedCalls);

        // clear stored calls
        delete _storedCalls;

        // Transfer back the required amounts to the Balancer Vault
        for (uint256 i = 0; i < tokens.length; i++) {
            tokens[i].transfer(
                address(balancerVault),
                amounts[i] + feeAmounts[i]
            );
        }
    }

    /// @dev Executes a series of calls using call on this contract.
    /// @param calls An array of call data to execute.
    function _executeCalls(bytes[] memory calls) private {
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
