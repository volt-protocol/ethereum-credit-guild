// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {AccountFactory} from "@src/account/AccountFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IBalancerFlashLoan {
    function flashLoan(
        address recipient,
        IERC20[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
}

/// Smart account implementation for the ECG
contract AccountImplementation is Ownable {
    error CallExternalError(bytes innerError);

    address public immutable BALANCER_VAULT =
        0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    address public factory;

    bytes[] private StoredCalls;

    constructor() Ownable() {}

    function initialize(address _owner) external {
        require(
            owner() == address(0) && factory == address(0),
            "AccountImplementation: already initialized"
        );
        factory = msg.sender;
        _transferOwnership(_owner);
    }

    function renounceOwnership() public view override onlyOwner {
        revert("AccountImplementation: cannot renounce ownership");
    }

    /// @notice allows to withdraw any token from the account contract
    function withdraw(address token, uint256 amount) public onlyOwner {
        IERC20(token).transfer(owner(), amount);
    }

    /**
     * @notice Allows the owner to withdraw all ETH from the contract to a specified receiver.
     */
    function withdrawEth() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "AccountImplementation: no ETH to withdraw");

        (bool success, ) = owner().call{value: balance}("");
        require(success, "AccountImplementation: failed to send ETH");
    }

    /// @notice function to perform external calls (can be batched)
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

    function multicall(bytes[] calldata calls) public onlyOwner {
        executeCalls(calls);
    }

    function executeCalls(bytes[] memory calls) private {
        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory result) = address(this).delegatecall(
                calls[i]
            );
            if (!success) {
                _getRevertMsg(result);
            }
        }
    }

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
        executeCalls(preCalls);

        // Initiate the flash loan
        IBalancerFlashLoan(BALANCER_VAULT).flashLoan(
            address(this),
            tokens,
            amounts,
            ""
        );
    }

    /// @notice this is used to receive a flashloan from balancer
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

        executeCalls(StoredCalls);

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

    /// @dev Helper function to extract a useful revert message from a failed call.
    /// If the returned data is malformed or not correctly abi encoded then this call can fail itself.
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
