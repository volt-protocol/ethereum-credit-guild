// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {Governor, IGovernor} from "@openzeppelin/contracts/governance/Governor.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import "@forge-std/Test.sol";

import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {GuildGovernor} from "@src/governance/GuildGovernor.sol";
import {CoreRoles as roles} from "@src/core/CoreRoles.sol";
import {LendingTermOnboarding} from "@src/governance/LendingTermOnboarding.sol";
import {LendingTermOffboarding} from "@src/governance/LendingTermOffboarding.sol";
import {PostProposalCheckFixture} from "@test/integration/PostProposalCheckFixture.sol";

contract IntegrationTestOffboardingFlows is PostProposalCheckFixture {
    function setUp() public override {
        super.setUp();

        uint256 mintAmount = governor.quorum(0);

        vm.prank(address(rateLimitedGuildMinter));
        guild.mint(address(this), mintAmount); /// mint quorum to contract

        guild.delegate(address(this));

        vm.roll(block.number + 1); /// ensure user votes register

        /// new term so that onboard succeeds
        LendingTerm.LendingTermParams memory params = term.getParameters();
        params.hardCap = params.hardCap * 123456;
        term = LendingTerm(
            factory.createTerm(
                factory.gaugeTypes(address(term)),
                factory.termImplementations(address(term)),
                term.getReferences().auctionHouse,
                abi.encode(params)
            )
        );
    }

    /// Offboarding setting quorum

    function testSetOffboardingQuorum() public {
        uint256 newQuorum = 100_000_000 * 1e18;

        address[] memory targets = new address[](1);
        targets[0] = address(vetoGuildGovernor);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            vetoGuildGovernor.setQuorum.selector,
            newQuorum
        );

        string
            memory description = "Update veto governor quourum to 100m guild";

        uint256 proposalId = governor.propose(
            targets,
            values,
            calldatas,
            description
        );

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Active)
        );

        governor.castVote(
            proposalId,
            uint8(GovernorCountingSimple.VoteType.For)
        );

        vm.roll(block.number + governor.votingPeriod() + 1);
        vm.warp(block.timestamp + 13);

        governor.queue(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );

        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Queued),
            "proposal not queued"
        );

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + timelock.getMinDelay() + 1);

        governor.execute(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );
        assertEq(
            uint8(governor.state(proposalId)),
            uint8(IGovernor.ProposalState.Executed),
            "proposal not executed"
        );

        assertEq(vetoGuildGovernor.quorum(0), newQuorum, "new quorum not set");
    }

    function testSetOffboardingQuourumAsTimelock() public {
        uint256 newQuorum = 100_000_000 * 1e18;

        vm.prank(getAddr("DAO_TIMELOCK"));
        offboarder.setQuorum(newQuorum);

        assertEq(offboarder.quorum(), newQuorum, "new quorum not set");
    }
}
