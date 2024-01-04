// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {BoringBatchable} from "@src/account/BoringBatchable.sol";

import {AccountFactory} from "@src/account/AccountFactory.sol";

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

    // function to perform external calls (can be batched)
    function callExternal(
        address target,
        bytes calldata data
    ) public onlyOwner {
        /*bytes4 sig = uint32(bytes32(data));
        require(AccountFactory(factory).canCall(target, data), "AccountImplementation: cannot call target");*/

        (bool success, bytes memory result) = target.call(data);
        if (!success) {
            _getRevertMsg(result);
        }

        /*
        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory result) = address(this).delegatecall(calls[i]);
            if (!success && revertOnFail) {
                _getRevertMsg(result);
            }
        }
         */
    }

    /*monAccount.batch([
        abi.encodeWithSelector(
            AccountImplementation.callExternal.sig,
            curvePool
            abi.encodeWithSignature("swap(uint256,uint256)", amountIn, minAmountOut)
        )
    ])*/
}
