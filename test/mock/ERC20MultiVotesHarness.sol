// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ERC20MultiVotes} from "@src/tokens/ERC20MultiVotes.sol";

contract ERC20MultiVotesHarness is ERC20MultiVotes {
    constructor() ERC20("Proving Token", "PT") ERC20Permit("Proving Token") {}
}
