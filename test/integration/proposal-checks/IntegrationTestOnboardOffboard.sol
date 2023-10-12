// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {Governor, IGovernor} from "@openzeppelin/contracts/governance/Governor.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {VoltGovernor} from "@src/governance/VoltGovernor.sol";
import {LendingTermOnboarding} from "@src/governance/LendingTermOnboarding.sol";
import {PostProposalCheck} from "@test/integration/proposal-checks/PostProposalCheck.sol";

contract IntegrationTestOnboardOffboard is PostProposalCheck {
    GuildToken guild;
    VoltGovernor governor;
    LendingTermOnboarding onboarder;
    LendingTerm term;
    MockERC20 collateral;

    uint256 public constant initialQuorum = 10_000_000e18; // initialQuorum
    uint256 public constant initialVotingPeriod = 7000 * 3; // initialVotingPeriod (~7000 blocks/day)

    /// @notice LendingTerm params
    uint256 private constant _CREDIT_PER_COLLATERAL_TOKEN = 1e18; // 1:1, same decimals
    uint256 private constant _INTEREST_RATE = 0.05e18; // 5% APR
    uint256 private constant _HARDCAP = 1_000_000e18;

    // VoltTimelockController params
    uint256 private constant _TIMELOCK_MIN_DELAY = 3600; // 1h

    function setUp() public override {
        super.setUp();
        guild = GuildToken(addresses.mainnet("ERC20_GUILD"));
        governor = VoltGovernor(payable(addresses.mainnet("GOVERNOR")));
        onboarder = LendingTermOnboarding(
            payable(addresses.mainnet("LENDING_TERM_ONBOARDING"))
        );

        term = LendingTerm(
            onboarder.createTerm(
                LendingTerm.LendingTermParams({
                    collateralToken: address(collateral),
                    maxDebtPerCollateralToken: _CREDIT_PER_COLLATERAL_TOKEN,
                    interestRate: _INTEREST_RATE,
                    maxDelayBetweenPartialRepay: 0,
                    minPartialRepayPercent: 0,
                    openingFee: 0,
                    hardCap: _HARDCAP
                })
            )
        );

        vm.prank(addresses.mainnet("TEAM_MULTISIG"));
        guild.transfer(address(this), 1_000_000_000e18);
        guild.delegate(address(this));
        vm.roll(block.number + 1); /// ensure user votes register
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

        vm.roll(block.number + _VOTING_PERIOD + 1);
        vm.warp(block.timestamp + 13);

        onboarder.castVote(
            proposalId,
            uint8(GovernorCountingSimple.VoteType.For)
        );

        vm.roll(block.number + _VOTING_PERIOD + 1);
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
        vm.warp(block.timestamp + _TIMELOCK_MIN_DELAY + 13);
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
    }

    function testOffboarding() public {}
}
