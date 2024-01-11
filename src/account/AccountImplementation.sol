// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {AccountFactory} from "@src/account/AccountFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Smart account implementation for the ECG
contract AccountImplementation is Ownable {
    error CallExternalError(bytes innerError);

    address public BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    address public factory;

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

    function multicall(bytes[] calldata calls) public payable {
        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory result) = address(this).delegatecall(
                calls[i]
            );
            if (!success) {
                _getRevertMsg(result);
            }
        }
    }

    /// @notice this is the receiveFlashLoan implementation for balancer
    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external {
        // ensure no fees for balancer?
        for (uint256 i = 0; i < feeAmounts.length; i++) {
            require(feeAmounts[i] == 0);
        }

        // userData sent by the balancer vault should be the next actions
        // to be performed, usually should be a multicall
        (bool success, bytes memory result) = address(this).call(userData);
        if (!success) {
            _getRevertMsg(result);
        }

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
