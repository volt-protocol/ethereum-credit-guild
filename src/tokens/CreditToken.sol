// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import {CoreRef} from "@src/core/CoreRef.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";

/** 
@title  CREDIT ERC20 Token
@author eswak
@notice This is the debt token of the Ethereum Credit Guild.
*/
contract CreditToken is CoreRef, ERC20Burnable, ERC20Votes {
    constructor(
        address _core
    )
        CoreRef(_core)
        ERC20("Ethereum Credit Guild - CREDIT", "CREDIT")
        ERC20Permit("Ethereum Credit Guild - CREDIT")
    {}

    /// @notice mint new tokens to the target address
    function mint(
        address to,
        uint256 amount
    ) external onlyCoreRole(CoreRoles.CREDIT_MINTER) {
        _mint(to, amount);
    }

    /*///////////////////////////////////////////////////////////////
                        Inheritance reconciliation
    //////////////////////////////////////////////////////////////*/

    function _afterTokenTransfer(address from, address to, uint256 amount)
        internal
        virtual
        override(ERC20, ERC20Votes)
    {
        ERC20Votes._afterTokenTransfer(from, to, amount);
    }

    function _mint(address account, uint256 amount) internal virtual override(ERC20, ERC20Votes) {
        ERC20Votes._mint(account, amount);
    }

    function _burn(address account, uint256 amount) internal virtual override(ERC20, ERC20Votes) {
        ERC20Votes._burn(account, amount);
    }
}
