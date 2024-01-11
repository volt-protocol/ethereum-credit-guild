// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";

import {AccountFactory} from "@src/account/AccountFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Smart account implementation for the ECG
contract AccountImplementation is Multicall, Ownable {
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

    error CallExternalError(bytes innerError);

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
