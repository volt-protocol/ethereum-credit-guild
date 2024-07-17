//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {RewardSweeper} from "@src/governance/RewardSweeper.sol";
import {GovernorProposal} from "@test/proposals/proposalTypes/GovernorProposal.sol";
import {LendingTermAdjustable} from "@src/loan/LendingTermAdjustable.sol";
import {LendingTermOnboarding} from "@src/governance/LendingTermOnboarding.sol";
import {LendingTermParamManager} from "@src/governance/LendingTermParamManager.sol";

contract Arbitrum_12_AdjustableLendingTerm is GovernorProposal {
    function name() public view virtual returns (string memory) {
        return "Enable adjustable lending term & reward sweeper";
    }

    constructor() {
        require(
            block.chainid == 42161,
            "Arbitrum_12_AdjustableLendingTerm: wrong chain id"
        );
    }

    function deploy() public virtual {
        // LendingTermAdjustable
        LendingTermAdjustable termV2 = new LendingTermAdjustable();
        setAddr("LENDING_TERM_V2", address(termV2));

        // LendingTermParamManager
        LendingTermOnboarding onboarder = LendingTermOnboarding(payable(getAddr("ONBOARD_GOVERNOR_GUILD")));
        LendingTermParamManager paramMgr = new LendingTermParamManager(
            getAddr("CORE"), // _core
            getAddr("ONBOARD_TIMELOCK"), // _timelock
            getAddr("ERC20_GUILD"), // _guildToken
            onboarder.votingDelay(), // initialVotingDelay
            onboarder.votingPeriod(), // initialVotingPeriod
            onboarder.proposalThreshold(), // initialProposalThreshold
            onboarder.quorum(0) // initialQuorum
        );
        setAddr("TERM_PARAM_GOVERNOR_GUILD", address(paramMgr));

        // RewardSweeper
        RewardSweeper sweeper = new RewardSweeper(
            getAddr("CORE"),
            getAddr("ERC20_GUILD"),
            getAddr("TEAM_MULTISIG")
        );
        setAddr("REWARD_SWEEPER", address(sweeper));
    }

    function afterDeploy(address/* deployer*/) public pure virtual {}

    function run(address /* deployer*/) public virtual {
        _addStep(
            getAddr("LENDING_TERM_FACTORY"),
            abi.encodeWithSignature(
                "allowImplementation(address,boolean)",
                getAddr("LENDING_TERM_V2"),
                true
            ),
            "Enable new LENDING_TERM_V2 implementation in factory (adjustable interest rate, borrow ratio, and hardCap)"
        );
        _addStep(
            getAddr("CORE"),
            abi.encodeWithSignature(
                "grandRole(bytes32,address)",
                CoreRoles.GOVERNOR,
                getAddr("TERM_PARAM_GOVERNOR_GUILD")
            ),
            "Grant GOVERNOR role to TERM_PARAM_GOVERNOR_GUILD"
        );
        _addStep(
            getAddr("CORE"),
            abi.encodeWithSignature(
                "grandRole(bytes32,address)",
                CoreRoles.GOVERNOR,
                getAddr("TERM_PARAM_GOVERNOR_GUILD")
            ),
            "Grant GOVERNOR role to REWARD_SWEEPER"
        );

        // Propose to the DAO
        address governor = getAddr("DAO_GOVERNOR_GUILD");
        address proposer = getAddr("TEAM_MULTISIG");
        address voter = getAddr("TEAM_MULTISIG");
        DEBUG = true;
        _simulateGovernorSteps(name(), governor, proposer, voter);
    }

    function teardown(address deployer) public pure virtual {}

    function validate(address deployer) public pure virtual {}
}
