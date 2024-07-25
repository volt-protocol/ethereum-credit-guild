// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {CallAllowList} from "@src/gateway/v2/CallAllowList.sol";
import {FlashloanReceiver} from "@src/gateway/v2/FlashloanReceiver.sol";

contract GatewayV2 is Ownable, Pausable, FlashloanReceiver, CallAllowList {

    /// @notice set pausable methods to paused
    function pause() public onlyOwner {
        _pause();
    }

    /// @notice set pausable methods to unpaused
    function unpause() public onlyOwner {
        _unpause();
    }

    /// @notice Execute an action with the Gateway without flashloan
    function action(bytes memory call) public entryPoint whenNotPaused {
          _call(address(this), call);
    }

    /// @notice Executes multiple calls in a single transaction.
    /// @param calls An array of call data to execute.
    function multicall(bytes[] memory calls) public afterEntry {
        for (uint256 i = 0; i < calls.length; i++) {
            _call(address(this), calls[i]);
        }
    }

    /// @notice Executes an external call to a specified target.
    /// @param target The address of the contract to call.
    /// @param data The calldata to send.
    function callExternal(
        address target,
        bytes memory data
    ) public afterEntry {
        require(
            _callAllowed(target, data),
            "GatewayV2: forbidden external call"
        );

        _call(target, data);
    }

    /// @notice function to consume a permit allowanced
    function consumePermit(
        address token,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public afterEntry {
        IERC20Permit(token).permit(
            _getOriginalSender(),
            address(this),
            amount,
            deadline,
            v,
            r,
            s
        );
    }

    /// @notice function to consume an allowance (transferFrom) from msg.sender to the gateway
    function consumeAllowance(address token, uint256 amount) public afterEntry {
        IERC20(token).transferFrom(_getOriginalSender(), address(this), amount);
    }

    /// @notice allows sweeping remaining token on the gateway
    ///         should be used at the end of a multicall
    /// @dev it means anyone can sweep any tokens left on this contract between transactions
    function sweep(address token) public afterEntry {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).transfer(_getOriginalSender(), balance);
        }
    }

    /// @notice implement call restrictions for flashloan providers,
    /// they will have to be allowed like external calls.
    function _isFlashloanProviderWhitelisted(
        address provider,
        bytes memory data
    ) internal override returns (bool) {
        return _callAllowed(provider, data);
    }
}
