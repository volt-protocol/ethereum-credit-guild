//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {SimplePSM} from "@src/loan/SimplePSM.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {AuctionHouse} from "@src/loan/AuctionHouse.sol";
import {GuildGovernor} from "@src/governance/GuildGovernor.sol";
import {ProfitManager} from "@src/governance/ProfitManager.sol";
import {ERC20MultiVotes} from "@src/tokens/ERC20MultiVotes.sol";
import {GovernorProposal} from "@test/proposals/proposalTypes/GovernorProposal.sol";
import {GuildVetoGovernor} from "@src/governance/GuildVetoGovernor.sol";
import {RateLimitedMinter} from "@src/rate-limits/RateLimitedMinter.sol";
import {SurplusGuildMinter} from "@src/loan/SurplusGuildMinter.sol";
import {LendingTermFactory} from "@src/governance/LendingTermFactory.sol";
import {LendingTermOnboarding} from "@src/governance/LendingTermOnboarding.sol";
import {GuildTimelockController} from "@src/governance/GuildTimelockController.sol";
import {LendingTermOffboarding} from "@src/governance/LendingTermOffboarding.sol";
import {TestnetToken} from "@src/tokens/TestnetToken.sol";

contract Arbitrum_6_RaiseQuorums is GovernorProposal {
    function name() public view virtual returns (string memory) {
        return "Raise GUILD quorums [round 1 airdrop distribution]";
    }

    constructor() {
        require(
            block.chainid == 42161,
            "Wrong chain id"
        );
    }


    function deploy() public pure virtual {}

    function afterDeploy(address deployer) public pure virtual {}

    function run(address/* deployer*/) public virtual {
        _addStep(
            getAddr("ONBOARD_GOVERNOR_GUILD"),
            abi.encodeWithSignature(
                "setQuorum(uint256)",
                1_000_000 * 1e18
            ),
            "GUILD onboard quorum 500k -> 1M"
        );
        _addStep(
            getAddr("ONBOARD_VETO_GUILD"),
            abi.encodeWithSignature(
                "setQuorum(uint256)",
                1_000_000 * 1e18
            ),
            "GUILD onboard veto quorum 500k -> 1M"
        );
        _addStep(
            getAddr("OFFBOARD_GOVERNOR_GUILD"),
            abi.encodeWithSignature(
                "setQuorum(uint256)",
                1_000_000 * 1e18
            ),
            "GUILD offboard quorum 500k -> 1M"
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
