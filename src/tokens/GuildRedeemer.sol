// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {RateLimitedMinter} from "@src/rate-limits/RateLimitedMinter.sol";

/// @title contract used to mint GUILD from preGUILD tokens
contract GuildRedeemer {
    /// @notice event to track redemptions
    event Redeem(
        uint256 indexed timestamp,
        address indexed recipient,
        uint256 amount
    );

    /// @notice token to redeem
    address public immutable preGuild;

    /// @notice reference to GUILD token
    address public immutable guild;

    /// @notice reference to GUILD minter
    address public immutable rlgm;

    constructor(address _preGuild, address _guild, address _rlgm) {
        preGuild = _preGuild;
        guild = _guild;
        rlgm = _rlgm;
    }

    /// @notice Redeem preGUILD for GUILD
    function redeem(address to, uint256 amount) external {
        ERC20Burnable(preGuild).burnFrom(msg.sender, amount);
        RateLimitedMinter(rlgm).mint(to, amount);
        emit Redeem(block.timestamp, to, amount);
    }
}
