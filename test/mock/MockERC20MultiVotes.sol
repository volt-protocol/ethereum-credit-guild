// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {MockERC20} from "@test/mock/MockERC20.sol";
import {ERC20MultiVotes} from "@src/tokens/ERC20MultiVotes.sol";

contract MockERC20MultiVotes is ERC20MultiVotes, MockERC20 {

    constructor() {}

    function decimals() public view override(ERC20, MockERC20) returns (uint8) {
        return MockERC20.decimals();
    }

    function setMaxDelegates(uint256 newMax) external {
        _setMaxDelegates(newMax);
    }

    function setContractExceedMaxDelegates(address account, bool canExceedMax) external {
        _setContractExceedMaxDelegates(account, canExceedMax);
    }

    /// ------------------------------------------------------------------------
    /// Overrides required by Solidity.
    /// ------------------------------------------------------------------------

    function getPastVotes(
        address account,
        uint256 blockNumber
    ) public override(MockERC20, ERC20MultiVotes) view returns (uint256) {
        return ERC20MultiVotes.getPastVotes(account, blockNumber);
    }

    function _burn(
        address from,
        uint256 amount
    ) internal override(ERC20, ERC20MultiVotes) {
        return super._burn(from, amount);
    }

    function transfer(
        address to,
        uint256 amount
    ) public override(ERC20, ERC20MultiVotes) returns (bool) {
        return super.transfer(to, amount);
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override(ERC20, ERC20MultiVotes) returns (bool) {
        return super.transferFrom(from, to, amount);
    }
}
