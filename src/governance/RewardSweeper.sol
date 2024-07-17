// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CoreRef} from "@src/core/CoreRef.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";

/** 
@title RewardSweeper
@author eswak
@notice Allows sweeping of rewards (airdroppped tokens) from LendingTerms to an address
        that can handle distribution.
        Governance must grant GOVERNOR role to this contract.
*/
contract RewardSweeper is CoreRef {
    /// @notice reference to GUILD token.
    address public guild;

    /// @notice address receiving swept rewards.
    address public receiver;

    constructor(address _core, address _guild, address _receiver) CoreRef(_core) {
        guild = _guild;
        receiver = _receiver;
    }

    /// @notice emitted when a reward token is swept.
    event Sweep(uint256 indexed when, address indexed gauge, address indexed token, uint256 amount);

    /// @notice set receiver address
    function setReceiver(address _receiver) external onlyCoreRole(CoreRoles.GOVERNOR) {
        receiver = _receiver;
    }

    /// @notice sweep tokens
    function sweep(
        address gauge,
        address token
    ) external {
        require(msg.sender == receiver, "RewardSweeper: invalid sender");
        require(GuildToken(guild).isGauge(gauge) || GuildToken(guild).isDeprecatedGauge(gauge), "RewardSweeper: invalid gauge");
        address collateralToken = LendingTerm(gauge).collateralToken();
        require(collateralToken != token, "RewardSweeper: invalid token");

        uint256 amount = IERC20(token).balanceOf(gauge);
        if (amount != 0) {
            CoreRef.Call[] memory calls = new CoreRef.Call[](1);
            calls[0] = CoreRef.Call({
                target: token,
                value: 0,
                callData: abi.encodeWithSignature(
                    "transfer(address,uint256)",
                    receiver,
                    amount
                )
            });
            CoreRef(gauge).emergencyAction(calls);

            emit Sweep(block.timestamp, gauge, token, amount);
        }
    }
}
