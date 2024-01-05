// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {BoringBatchable} from "@src/account/BoringBatchable.sol";

import {AccountFactory} from "@src/account/AccountFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Smart account implementation for the ECG
contract AccountImplementation is BoringBatchable, Ownable {
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
    function withdraw(address token, address receiver, uint256 amount) public onlyOwner {
        IERC20(token).transfer(receiver, amount);
    }
    
    /**
     * @notice Allows the owner to withdraw all ETH from the contract to a specified receiver.
     * @param receiver The address to which the ETH will be sent.
     */
    function withdrawEth(address payable receiver) external onlyOwner {
        require(receiver != address(0), "AccountImplementation: invalid receiver address");
        uint256 balance = address(this).balance;
        require(balance > 0, "AccountImplementation: no ETH to withdraw");

        (bool success, ) = receiver.call{value: balance}("");
        require(success, "AccountImplementation: failed to send ETH");
    }

    /// @notice function to perform external calls (can be batched)
    function callExternal(
        address target,
        bytes calldata data
    ) public onlyOwner {
        // Extract the function selector from the first 4 bytes of `data`
        bytes4 functionSelector = bytes4(data[:4]);
        require(AccountFactory(factory).canCall(target, functionSelector), "AccountImplementation: cannot call target");

        (bool success, bytes memory result) = target.call(data);
        if (!success) {
            _getRevertMsg(result);
        }
    }
}
