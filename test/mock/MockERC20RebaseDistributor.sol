// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {ERC20RebaseDistributor} from "@src/tokens/ERC20RebaseDistributor.sol";

contract MockERC20RebaseDistributor is ERC20RebaseDistributor, MockERC20 {

    function decimals() public view override(ERC20, MockERC20) returns (uint8) {
        return MockERC20.decimals();
    }

    /// ------------------------------------------------------------------------
    /// Overrides required by Solidity.
    /// ------------------------------------------------------------------------

    function _mint(
        address account,
        uint256 amount
    ) internal override(ERC20, ERC20RebaseDistributor) {
        super._mint(account, amount);
    }

    function _burn(
        address account,
        uint256 amount
    ) internal override(ERC20, ERC20RebaseDistributor) {
        super._burn(account, amount);
    }

    function balanceOf(
        address account
    ) public view override(ERC20, ERC20RebaseDistributor) returns (uint256) {
        return super.balanceOf(account);
    }

    function totalSupply() public view override(ERC20, ERC20RebaseDistributor) returns (uint256) {
        return super.totalSupply();
    }

    function transfer(
        address to,
        uint256 amount
    ) public override(ERC20, ERC20RebaseDistributor) returns (bool) {
        return super.transfer(to, amount);
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override(ERC20, ERC20RebaseDistributor) returns (bool) {
        return super.transferFrom(from, to, amount);
    }
}
