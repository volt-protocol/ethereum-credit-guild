// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./Gateway.sol";

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

    function multicallWithBalancerFlashLoan(
        IERC20[] calldata tokens,
        uint256[] calldata amounts,
        bytes[] calldata calls // Calls to be made after receiving the flash loan
    ) public whenNotPaused {
        require(
            _originalSender == address(1),
            "Gateway: original sender already set"
        );

        _originalSender = msg.sender;
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

        _originalSender = address(1);

        // clear stored calls
        delete _storedCalls;
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
    ) external whenNotPaused {
        // ensure no fees from balancer??
        // for (uint256 i = 0; i < feeAmounts.length; i++) {
        //     require(feeAmounts[i] == 0);
        // }

        require(
            msg.sender == balancerVault,
            "receiveFlashLoan: sender is not balancer"
        );

        require(
            _originalSender != address(1),
            "receiveFlashLoan: original sender must be set"
        );

        // execute the storedCalls, enforcing that the 'receiveFlashLoan' is called
        // after having called 'multicallWithBalancerFlashLoan';
        _executeCalls(_storedCalls);

        // Transfer back the required amounts to the Balancer Vault
        for (uint256 i = 0; i < tokens.length; i++) {
            tokens[i].transfer(
                address(balancerVault),
                amounts[i] + feeAmounts[i]
            );
        }
    }
}
