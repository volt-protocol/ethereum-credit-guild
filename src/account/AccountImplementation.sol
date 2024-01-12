// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {AccountFactory} from "@src/account/AccountFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// mock interface for the balancer vault flashloan function
interface IBalancerFlashLoan {
    function flashLoan(
        address recipient,
        IERC20[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
}

/// @title Smart Account Implementation for ECG
/// @notice This contract provides a flexible and modular framework for managing digital assets
///         and interacting with DeFi protocols while ensuring safety for its owner by limiting the external
///         calls that can be made.
/// @dev The contract is designed to handle various operations such as asset withdrawal,
///      executing arbitrary external calls (whitelisted by the DAO),
///      and leveraging Balancer flash loans for advanced DeFi strategies (leverage).
/// @dev The contract is created by an ECG user and is owned by the user. Ownership cannot change
contract AccountImplementation is Ownable {
    /// @notice Emitted when an external call fails with an error.
    error CallExternalError(bytes innerError);

    /// @notice Address of the Balancer Vault, used for initiating flash loans.
    address public immutable BALANCER_VAULT =
        0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    /// @notice Address of the factory that creates instances of this contract.
    ///         And provide the list of targets and call that can be called by this contract
    address public factory;

    /// @notice Stores calls to be executed after receiving a Balancer flash loan.
    /// @dev The StoredCalls should only be set in the 'multicallWithBalancerFlashLoan' function
    ///      Which is "onlyOwner" so the StoredCalls can only be set by the owner of the contract
    bytes[] private StoredCalls;

    /// @notice Creates a new AccountImplementation contract and sets the owner.
    constructor() Ownable() {}

    /// @notice Initializes the contract by setting the owner and factory.
    /// @param _owner The address of the new owner.
    function initialize(address _owner) external {
        require(
            owner() == address(0) && factory == address(0),
            "AccountImplementation: already initialized"
        );
        factory = msg.sender;
        _transferOwnership(_owner);
    }

    /// @notice Disallows renouncing ownership of the contract.
    function renounceOwnership() public view override onlyOwner {
        revert("AccountImplementation: cannot renounce ownership");
    }

    /// @notice Withdraws a specified ERC20 token amount to the owner's address.
    /// @param token The ERC20 token address to withdraw.
    /// @param amount The amount of the token to withdraw.
    function withdraw(address token, uint256 amount) public onlyOwner {
        IERC20(token).transfer(owner(), amount);
    }

    /// @notice Withdraws all Ether from the contract to the owner's address.
    function withdrawEth() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "AccountImplementation: no ETH to withdraw");

        (bool success, ) = owner().call{value: balance}("");
        require(success, "AccountImplementation: failed to send ETH");
    }

    /// @notice Executes an external call to a specified target.
    ///         Only allows external calls to allowed target and function selector
    ///         these whitelisted calls are stored in the factory
    /// @param target The address of the contract to call.
    /// @param data The calldata to send.
    function callExternal(
        address target,
        bytes calldata data
    ) public onlyOwner {
        // Extract the function selector from the first 4 bytes of `data`
        bytes4 functionSelector = bytes4(data[:4]);
        require(
            AccountFactory(factory).allowedCalls(target, functionSelector),
            "AccountImplementation: cannot call target"
        );

        (bool success, bytes memory result) = target.call(data);
        if (!success) {
            _getRevertMsg(result);
        }
    }

    /// @notice Executes multiple calls in a single transaction.
    /// @param calls An array of call data to execute.
    function multicall(bytes[] calldata calls) public onlyOwner {
        _executeCalls(calls);
    }

    /// @notice Initiates a Balancer flash loan and executes specified calls before and after receiving the loan.
    /// @param tokens Array of ERC20 token addresses for the flash loan.
    /// @param amounts Array of amounts for each token in the flash loan.
    /// @param preCalls Calls to execute before receiving the flash loan.
    /// @param postCalls Calls to execute after receiving the flash loan.
    function multicallWithBalancerFlashLoan(
        IERC20[] calldata tokens,
        uint256[] calldata amounts,
        bytes[] calldata preCalls, // Calls to be made before receiving the flash loan
        bytes[] calldata postCalls // Calls to be made after receiving the flash loan
    ) external onlyOwner {
        // Clear existing StoredCalls
        delete StoredCalls;

        // Manually copy each element
        for (uint i = 0; i < postCalls.length; i++) {
            StoredCalls.push(postCalls[i]);
        }

        // execute the pre calls
        _executeCalls(preCalls);

        // Initiate the flash loan
        IBalancerFlashLoan(BALANCER_VAULT).flashLoan(
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
        // ensure no fees for balancer
        // for (uint256 i = 0; i < feeAmounts.length; i++) {
        //     require(feeAmounts[i] == 0);
        // }

        require(
            msg.sender == BALANCER_VAULT,
            "receiveFlashLoan: sender is not balancer"
        );

        _executeCalls(StoredCalls);

        // clear stored calls
        delete StoredCalls;

        // Transfer back the required amounts to the Balancer Vault
        for (uint256 i = 0; i < tokens.length; i++) {
            tokens[i].transfer(
                address(BALANCER_VAULT),
                amounts[i] + feeAmounts[i]
            );
        }
    }

    /// @dev Executes a series of calls using delegatecall.
    /// @param calls An array of call data to execute.
    function _executeCalls(bytes[] memory calls) private {
        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory result) = address(this).delegatecall(
                calls[i]
            );
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
