// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import {CoreRef} from "@src/core/CoreRef.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {ERC20MultiVotes} from "@src/tokens/ERC20MultiVotes.sol";
import {ERC20RebaseDistributor} from "@src/tokens/ERC20RebaseDistributor.sol";

/** 
@title  CREDIT ERC20 Token
@author eswak
@notice This is the debt token of the Ethereum Credit Guild.
*/
contract CreditToken is
    CoreRef,
    ERC20Burnable,
    ERC20MultiVotes,
    ERC20RebaseDistributor
{
    constructor(
        address _core,
        string memory _name,
        string memory _symbol
    )
        CoreRef(_core)
        ERC20(_name, _symbol)
        ERC20Permit(_name)
    {}

    /// @notice Mint new tokens to the target address
    function mint(
        address to,
        uint256 amount
    ) external onlyCoreRole(CoreRoles.CREDIT_MINTER) {
        _mint(to, amount);
    }

    /// @notice Set `maxDelegates`, the maximum number of addresses any account can delegate voting power to.
    function setMaxDelegates(
        uint256 newMax
    ) external onlyCoreRole(CoreRoles.CREDIT_GOVERNANCE_PARAMETERS) {
        _setMaxDelegates(newMax);
    }

    /// @notice Allow or disallow an address to delegate voting power to more addresses than `maxDelegates`.
    function setContractExceedMaxDelegates(
        address account,
        bool canExceedMax
    ) external onlyCoreRole(CoreRoles.CREDIT_GOVERNANCE_PARAMETERS) {
        _setContractExceedMaxDelegates(account, canExceedMax);
    }

    /// @notice Force an address to enter rebase.
    function forceEnterRebase(
        address account
    ) external onlyCoreRole(CoreRoles.CREDIT_REBASE_PARAMETERS) {
        require(
            rebasingState[account].isRebasing == 0,
            "CreditToken: already rebasing"
        );
        _enterRebase(account);
    }

    /// @notice Force an address to exit rebase.
    function forceExitRebase(
        address account
    ) external onlyCoreRole(CoreRoles.CREDIT_REBASE_PARAMETERS) {
        require(
            rebasingState[account].isRebasing == 1,
            "CreditToken: not rebasing"
        );
        _exitRebase(account);
    }

    /*///////////////////////////////////////////////////////////////
                        Inheritance reconciliation
    //////////////////////////////////////////////////////////////*/

    function _mint(
        address account,
        uint256 amount
    ) internal override(ERC20, ERC20RebaseDistributor) {
        ERC20RebaseDistributor._mint(account, amount);
    }

    function _burn(
        address account,
        uint256 amount
    ) internal override(ERC20, ERC20MultiVotes, ERC20RebaseDistributor) {
        _decrementVotesUntilFree(account, amount); // from ERC20MultiVotes
        ERC20RebaseDistributor._burn(account, amount);
    }

    function balanceOf(
        address account
    ) public view override(ERC20, ERC20RebaseDistributor) returns (uint256) {
        return ERC20RebaseDistributor.balanceOf(account);
    }

    function totalSupply()
        public
        view
        override(ERC20, ERC20RebaseDistributor)
        returns (uint256)
    {
        return ERC20RebaseDistributor.totalSupply();
    }

    function transfer(
        address to,
        uint256 amount
    )
        public
        override(ERC20, ERC20MultiVotes, ERC20RebaseDistributor)
        returns (bool)
    {
        _decrementVotesUntilFree(msg.sender, amount); // from ERC20MultiVotes
        return ERC20RebaseDistributor.transfer(to, amount);
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    )
        public
        override(ERC20, ERC20MultiVotes, ERC20RebaseDistributor)
        returns (bool)
    {
        _decrementVotesUntilFree(from, amount); // from ERC20MultiVotes
        return ERC20RebaseDistributor.transferFrom(from, to, amount);
    }
}
