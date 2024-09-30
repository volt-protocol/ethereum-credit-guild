// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {FlashloanReceiver} from "@src/gateway/v2/FlashloanReceiver.sol";

/// @title GatewayV2
/// @notice util to multicall actions on other contracts and use flashloans
/// /!\ WARNING: Do not use this contract with tokens that have functions
/// other than transferFrom for transferring after setting an allowance. This includes
/// ERC721 tokens with safeTransferFrom or ERC20 tokens with alternative transfer functions.
/// If user A sets an allowance on the Gateway, user B could potentially call the Gateway
/// and withdraw tokens from any user who has set an allowance.
/// This vulnerability exists even with permit signatures and atomic permit/transferFrom operations.
/// After broadcasting, a mempool observer could front-run the transaction and withdraw
/// the tokens using the now-public signature.
/// @author eswak
contract GatewayV2 is Ownable, Pausable, FlashloanReceiver {

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
        bytes4 selector = bytes4(bytes.concat(data[0], data[1], data[2], data[3]));
        require(selector != 0x23b872dd, "GatewayV2: transferFrom forbidden");
        _call(target, data);
    }

    /// @notice Used for intermediary step checks on token balances
    function checkBalanceAtLeast(
        address token,
        uint256 amount
    ) public view afterEntry {
        require(
            IERC20(token).balanceOf(address(this)) >= amount,
            "GatewayV2: balance too low"
        );
    }

    /// @notice Emitted by emitEvent, used for arbitrary event emitting
    event Event(uint256 indexed timestamp, address indexed sender, string text);
    /// @notice Used for arbitrary event emitting
    function emitEvent(
        string memory text
    ) public afterEntry {
        emit Event(block.timestamp, _getOriginalSender(), text);
    }

    /// @notice function to consume an allowance (transferFrom to the gateway)
    function consumeAllowance(address token, uint256 amount) public afterEntry {
        IERC20(token).transferFrom(_getOriginalSender(), address(this), amount);
    }

    /// @notice allows sweeping remaining token on the gateway
    ///         should be used at the end of a multicall
    /// @dev it means anyone can sweep any tokens left on this contract between transactions
    function sweep(address token) public afterEntry {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance != 0) {
            IERC20(token).transfer(_getOriginalSender(), balance);
        }
    }
}
