// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20, ERC20Burnable {
    constructor() ERC20("MockToken", "MCT") {}

    function mint(address account, uint256 amount) public returns (bool) {
        _mint(account, amount);
        return true;
    }

    function mockBurn(address account, uint256 amount) public returns (bool) {
        _burn(account, amount);
        return true;
    }

    function approveOverride(
        address owner,
        address spender,
        uint256 amount
    ) public {
        _approve(owner, spender, amount);
    }

    // mock governance features of ERC20Votes
    mapping(address => uint256) public _votes;

    function getPastVotes(
        address account,
        uint256 /* blockNumber*/
    ) external view virtual returns (uint256) {
        return _votes[account];
    }

    function mockSetVotes(address account, uint256 votes) external {
        _votes[account] = votes;
    }
}
