// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @notice preGUILD Token
contract PreGuildToken is ERC20Burnable {
    constructor() ERC20("ECG Investor Token", "preGUILD") {
        _mint(msg.sender, 1_000_000_000e18);
    }
}
