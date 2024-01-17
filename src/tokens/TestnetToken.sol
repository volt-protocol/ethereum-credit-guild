// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import {CoreRef} from "@src/core/CoreRef.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";

/// @notice ECG Testnet Token
contract TestnetToken is CoreRef, ERC20Permit, ERC20Burnable {
    constructor(
        address _core,
        string memory _name,
        string memory _symbol,
        uint8 __decimals
    ) CoreRef(_core) ERC20(_name, _symbol) ERC20Permit(_name) {
        _decimals = __decimals;
    }

    uint8 internal _decimals;

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function mint(
        address to,
        uint256 amount
    ) external onlyCoreRole(CoreRoles.GOVERNOR) {
        _mint(to, amount);
    }
}
