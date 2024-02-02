// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./Gateway.sol";

/// @notice simple interface for flashloaning from balancer
interface IBalancerFlashLoan {
    function flashLoan(
        address recipient,
        IERC20[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
}

/// @title ECG Gateway V1
/// @notice Gateway to interract via multicall with the ECG
/// Owner can select which calls are allowed
/// @custom:feature flashloan from balancer vault
contract GatewayV1 is Gateway {
    /// @notice Address of the Balancer Vault, used for initiating flash loans.
    address public immutable balancerVault =
        0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    /// @notice Stores calls to be executed after receiving a flash loan.
    /// @dev The StoredCalls should/must only be set in the 'multicallWithBalancerFlashLoan'
    bytes[] internal _storedCalls;

    /// @notice execute a multicall (see abstract Gateway.sol) after a flashloan on balancer
    /// store the multicall calls in the _storedCalls state variable to be executed on the receiveFlashloan method (executed from the balancer vault)
    /// @param tokens the addresses of tokens to be borrowed
    /// @param amounts the amounts of each tokens to be borrowed
    /// @dev this method instanciate _originalSender like the multicall function does in the abstract contract
    function multicallWithBalancerFlashLoan(
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes[] calldata calls // Calls to be made after receiving the flash loan
    ) public whenNotPaused {
        require(
            _originalSender == address(1),
            "GatewayV1: original sender already set"
        );

        _originalSender = msg.sender;

        // store the calls, they'll be executed in the 'receiveFlashloan' function later
        for (uint i = 0; i < calls.length; i++) {
            _storedCalls.push(calls[i]);
        }

        IERC20[] memory ierc20Tokens = new IERC20[](tokens.length);
        for (uint i = 0; i < tokens.length; i++) {
            ierc20Tokens[i] = IERC20(tokens[i]);
        }

        // Initiate the flash loan
        // the balancer vault will call receiveFlashloan function on this contract before returning
        IBalancerFlashLoan(balancerVault).flashLoan(
            address(this),
            ierc20Tokens,
            amounts,
            ""
        );

        // here, the flashloan have been successfully reimbursed otherwise it would have reverted

        // clear stored calls
        delete _storedCalls;
        // clear _originalSender
        _originalSender = address(1);
    }

    /// @notice Handles the receipt of a flash loan from balancer, executes stored calls, and repays the loan.
    /// @param tokens Array of ERC20 tokens received in the flash loan.
    /// @param amounts Array of amounts for each token received.
    /// @param feeAmounts Array of fee amounts for each token received.
    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory /*userData*/
    ) external whenNotPaused {
        require(
            msg.sender == balancerVault,
            "GatewayV1: sender is not balancer"
        );

        // ensure the originalSender is set (via the multicallWithBalancerFlashLoan function)
        require(
            _originalSender != address(1),
            "GatewayV1: original sender must be set"
        );

        // execute the storedCalls stored in the multicallWithBalancerFlashLoan function
        _executeCalls(_storedCalls);

        // Transfer back the required amounts to the Balancer Vault
        for (uint256 i = 0; i < tokens.length; i++) {
            tokens[i].transfer(balancerVault, amounts[i] + feeAmounts[i]);
        }
    }
}
