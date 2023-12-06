//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Proposal} from "@test/proposals/proposalTypes/Proposal.sol";

contract GIP_X is Proposal {
    string public name = "Proposal_Example";

    function deploy() public pure {}

    function afterDeploy(address deployer) public pure {}

    function run(address deployer) public pure {}

    function teardown(address deployer) public pure {}

    function validate(address deployer) public pure {}
}
