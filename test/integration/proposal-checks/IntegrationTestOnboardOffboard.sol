// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {Governor, IGovernor} from "@openzeppelin/contracts/governance/Governor.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import "@forge-std/Test.sol";

import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {VoltGovernor} from "@src/governance/VoltGovernor.sol";
import {NameLib as strings} from "@src/utils/NameLib.sol";
import {CoreRoles as roles} from "@src/core/CoreRoles.sol";
import {PostProposalCheck} from "@test/integration/proposal-checks/PostProposalCheck.sol";
import {LendingTermOnboarding} from "@src/governance/LendingTermOnboarding.sol";
import {LendingTermOffboarding} from "@src/governance/LendingTermOffboarding.sol";
import {ProtocolConstants as constants} from "@src/utils/ProtocolConstants.sol";

contract IntegrationTestOnboardOffboard is PostProposalCheck {
    Core core;
    GuildToken guild;
    VoltGovernor governor;
    LendingTermOnboarding onboarder;
    LendingTermOffboarding offboarder;
    LendingTerm term;
    MockERC20 collateral;

    uint256 public constant initialQuorum = 10_000_000e18; // initialQuorum
    uint256 public constant initialVotingPeriod = 7000 * 3; // initialVotingPeriod (~7000 blocks/day)

    /// @notice LendingTerm params
    uint256 private constant _INTEREST_RATE = 0.05e18; // 5% APR
    uint256 private constant _HARDCAP = 1_000_000e18;

    function setUp() public override {
        super.setUp();
        guild = GuildToken(addresses.mainnet(strings.GUILD_TOKEN));
        governor = VoltGovernor(payable(addresses.mainnet(strings.GOVERNOR)));
        onboarder = LendingTermOnboarding(
            payable(addresses.mainnet(strings.LENDING_TERM_ONBOARDING))
        );
        offboarder = LendingTermOffboarding(
            addresses.mainnet(strings.LENDING_TERM_OFFBOARDING)
        );
        core = Core(addresses.mainnet(strings.CORE));

        term = LendingTerm(
            onboarder.createTerm(
                LendingTerm.LendingTermParams({
                    collateralToken: address(collateral),
                    maxDebtPerCollateralToken: constants.MAX_USDC_CREDIT_RATIO,
                    interestRate: _INTEREST_RATE,
                    maxDelayBetweenPartialRepay: 0,
                    minPartialRepayPercent: 0,
                    openingFee: 0,
                    hardCap: _HARDCAP
                })
            )
        );
        vm.prank(addresses.mainnet(strings.TIMELOCK));
        guild.enableTransfer();

        vm.prank(addresses.mainnet(strings.TEAM_MULTISIG));
        guild.transfer(address(this), constants.GUILD_SUPPLY);
        guild.delegate(address(this));
        vm.roll(block.number + 1); /// ensure user votes register
    }

    function testGuildTokenTransferEnabled() public {
        assertTrue(guild.transferable());
    }

    function testCoreCorrectlySetOnLendingTermLogic() public {
        assertEq(
            address(LendingTerm(onboarder.lendingTermImplementation()).core()),
            address(1)
        );
    }

    function testOnboarding() public {
        uint256 proposalId = onboarder.proposeOnboard(address(term));

        assertEq(
            uint8(onboarder.state(proposalId)),
            uint8(IGovernor.ProposalState.Pending)
        );

        vm.roll(block.number + constants.VOTING_PERIOD - 1);
        vm.warp(onboarder.proposalDeadline(proposalId) - 1);

        assertEq(
            uint8(onboarder.state(proposalId)),
            uint8(IGovernor.ProposalState.Active)
        );

        onboarder.castVote(
            proposalId,
            uint8(GovernorCountingSimple.VoteType.For)
        );

        vm.roll(block.number + constants.VOTING_PERIOD + 1);
        vm.warp(block.timestamp + 13);

        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = onboarder.getOnboardProposeArgs(address(term));
        onboarder.queue(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );
        assertEq(
            uint8(onboarder.state(proposalId)),
            uint8(IGovernor.ProposalState.Queued)
        );

        // execute
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + constants.TIMELOCK_DELAY + 13);
        assertEq(
            uint8(onboarder.state(proposalId)),
            uint8(IGovernor.ProposalState.Queued)
        );

        onboarder.execute(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );
        assertEq(
            uint8(onboarder.state(proposalId)),
            uint8(IGovernor.ProposalState.Executed)
        );

        _roleValidation();

        assertTrue(guild.isGauge(address(term)));
    }

    function _roleValidation() private {
        /// role validation
        assertTrue(core.hasRole(roles.GAUGE_PNL_NOTIFIER, address(term)));
        assertTrue(
            core.hasRole(roles.RATE_LIMITED_CREDIT_MINTER, address(term))
        );
    }

    function testOffboarding() public {
        testOnboarding();

        uint256 startingBlockNumber = block.number;
        offboarder.proposeOffboard(address(term));

        _roleValidation();

        vm.roll(block.number + 1);

        offboarder.supportOffboard(startingBlockNumber, address(term));

        _roleValidation();

        assertTrue(offboarder.canOffboard(address(term)));

        assertTrue(guild.isGauge(address(term)));

        offboarder.offboard(address(term));

        assertFalse(guild.isGauge(address(term)));

        _roleValidation();

        offboarder.cleanup(address(term));

        assertFalse(core.hasRole(roles.GAUGE_PNL_NOTIFIER, address(term)));
        assertFalse(
            core.hasRole(roles.RATE_LIMITED_CREDIT_MINTER, address(term))
        );
    }
}
