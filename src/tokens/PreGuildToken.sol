// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {RateLimitedMinter} from "@src/rate-limits/RateLimitedMinter.sol";

/// @notice preGUILD Token
contract PreGuildToken is ERC20Burnable {
    /// @notice event to track redemptions
    event Redeem(
        uint256 indexed timestamp,
        address indexed recipient,
        uint256 amount
    );

    /// @notice reference to GUILD minter
    address public immutable rlgm;

    constructor(address _rlgm) ERC20("ECG Investor Token", "preGUILD") {
        rlgm = _rlgm;
        _mint(msg.sender, 1_000_000_000e18);
    }

    /// @notice Redeem preGUILD for GUILD
    function redeem(address to, uint256 amount) external {
        _burn(msg.sender, amount);
        RateLimitedMinter(rlgm).mint(to, amount);
        emit Redeem(block.timestamp, to, amount);
    }
}
