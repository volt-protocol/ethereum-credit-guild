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
import {AddressLib} from "@test/proposals/AddressLib.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {GuildGovernor} from "@src/governance/GuildGovernor.sol";
import {CoreRoles as roles} from "@src/core/CoreRoles.sol";
import {LendingTermOnboarding} from "@src/governance/LendingTermOnboarding.sol";
import {LendingTermOffboarding} from "@src/governance/LendingTermOffboarding.sol";
import {PostProposalCheckFixture} from "@test/integration/PostProposalCheckFixture.sol";

contract IntegrationTestVetoDAOFlows is PostProposalCheckFixture {
    function setUp() public override {
        super.setUp();

        uint256 mintAmount = governor.quorum(0);

        vm.prank(teamMultisig);
        rateLimitedGuildMinter.mint(address(this), mintAmount); /// mint quorum to contract

        guild.delegate(address(this));

        vm.roll(block.number + 1); /// ensure user votes register

        /// new term so that onboard succeeds
        term = LendingTerm(
            onboarder.createTerm(
                AddressLib.get("LENDING_TERM_V1"),
                LendingTerm.LendingTermParams({
                    collateralToken: AddressLib.get("ERC20_SDAI"),
                    maxDebtPerCollateralToken: 1e18,
                    interestRate: 0.04e18,
                    maxDelayBetweenPartialRepay: 0,
                    minPartialRepayPercent: 0,
                    openingFee: 0,
                    hardCap: rateLimitedCreditMinter.buffer()
                })
            )
        );
    }

    function testProposeFails() public {
        vm.expectRevert("GuildVetoGovernor: cannot propose arbitrary actions");
        vetoGuildGovernor.propose(
            new address[](0),
            new uint256[](0),
            new bytes[](0),
            ""
        );
    }

    function testProposalThresholdZero() public {
        assertEq(vetoGuildGovernor.proposalThreshold(), 0); /// anyone can propose
    }

    /// ----------------- Governor DAO Actions -------------------
    function testUpdateTimelockVetoDao() public {
        address[] memory targets = new address[](1);
        targets[0] = address(vetoGuildGovernor);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            vetoGuildGovernor.updateTimelock.selector,
            address(this)
        );

        string memory description = "Update timelock to this address";

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

        assertEq(vetoGuildGovernor.timelock(), address(this));
    }
}
