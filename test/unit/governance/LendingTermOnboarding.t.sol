// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Governor, IGovernor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";

import {Test} from "@forge-std/Test.sol";
import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {SimplePSM} from "@src/loan/SimplePSM.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {AuctionHouse} from "@src/loan/AuctionHouse.sol";
import {ProfitManager} from "@src/governance/ProfitManager.sol";
import {RateLimitedMinter} from "@src/rate-limits/RateLimitedMinter.sol";
import {LendingTermOnboarding} from "@src/governance/LendingTermOnboarding.sol";
import {GuildTimelockController} from "@src/governance/GuildTimelockController.sol";

contract LendingTermOnboardingUnitTest is Test {
    address private governor = address(1);
    address private guardian = address(2);
    Core private core;
    ProfitManager private profitManager;
    GuildToken private guild;
    CreditToken private credit;
    MockERC20 private collateral;
    SimplePSM private psm;
    LendingTerm private termImplementation;
    AuctionHouse auctionHouse;
    RateLimitedMinter rlcm;
    GuildTimelockController private timelock;
    LendingTermOnboarding private onboarder;
    address private constant alice = address(0x616c696365);
    address private constant bob = address(0xB0B);

    // GuildTimelockController params
    uint256 private constant _TIMELOCK_MIN_DELAY = 3600; // 1h

    // LendingTerm params
    uint256 private constant _CREDIT_PER_COLLATERAL_TOKEN = 1e18; // 1:1, same decimals
    uint256 private constant _INTEREST_RATE = 0.05e18; // 5% APR
    uint256 private constant _HARDCAP = 1_000_000e18;

    // LendingTermOnboarding params
    uint256 private constant _VOTING_DELAY = 0;
    uint256 private constant _VOTING_PERIOD = 100_000; // ~14 days
    uint256 private constant _PROPOSAL_THRESHOLD = 2_500_000e18;
    uint256 private constant _QUORUM = 20_000_000e18;

    function setUp() public {
        vm.warp(1679067867);
        vm.roll(16848497);

        // deploy
        core = new Core();
        profitManager = new ProfitManager(address(core));
        credit = new CreditToken(address(core), "name", "symbol");
        guild = new GuildToken(address(core), address(profitManager));
        collateral = new MockERC20();
        rlcm = new RateLimitedMinter(
            address(core), /*_core*/
            address(credit), /*_token*/
            CoreRoles.RATE_LIMITED_CREDIT_MINTER, /*_role*/
            type(uint256).max, /*_maxRateLimitPerSecond*/
            type(uint128).max, /*_rateLimitPerSecond*/
            type(uint128).max /*_bufferCap*/
        );
        psm = new SimplePSM(
            address(core),
            address(profitManager),
            address(credit),
            address(collateral)
        );
        auctionHouse = new AuctionHouse(
            address(core),
            650,
            1800
        );
        termImplementation = new LendingTerm();
        timelock = new GuildTimelockController(
            address(core),
            _TIMELOCK_MIN_DELAY
        );
        onboarder = new LendingTermOnboarding(
            LendingTerm.LendingTermReferences({
                profitManager: address(profitManager),
                guildToken: address(guild),
                auctionHouse: address(auctionHouse),
                creditMinter: address(rlcm),
                creditToken: address(credit)
            }), /// _lendingTermReferences
            1, // _gaugeType
            address(core), // _core
            address(timelock), // _timelock
            _VOTING_DELAY, // initialVotingDelay
            _VOTING_PERIOD, // initialVotingPeriod
            _PROPOSAL_THRESHOLD, // initialProposalThreshold
            _QUORUM // initialQuorum
        );
        onboarder.allowImplementation(
            address(termImplementation),
            true
        );

        profitManager.initializeReferences(address(credit), address(guild), address(psm));

        // permissions
        core.grantRole(CoreRoles.GOVERNOR, governor);
        core.grantRole(CoreRoles.GUARDIAN, guardian);
        core.grantRole(CoreRoles.CREDIT_MINTER, address(this));
        core.grantRole(CoreRoles.GUILD_MINTER, address(this));
        core.grantRole(CoreRoles.GAUGE_ADD, address(this));
        core.grantRole(CoreRoles.GAUGE_REMOVE, address(this));
        core.grantRole(CoreRoles.GAUGE_PARAMETERS, address(this));
        core.grantRole(CoreRoles.GUILD_GOVERNANCE_PARAMETERS, address(this));
        core.grantRole(CoreRoles.CREDIT_MINTER, address(rlcm));
        core.grantRole(CoreRoles.GOVERNOR, address(timelock));
        core.grantRole(CoreRoles.GAUGE_ADD, address(timelock));
        core.grantRole(CoreRoles.TIMELOCK_EXECUTOR, address(0));
        core.grantRole(CoreRoles.TIMELOCK_PROPOSER, address(onboarder));
        core.renounceRole(CoreRoles.GOVERNOR, address(this));

        // allow GUILD gauge votes & delegations
        guild.setMaxGauges(10);
        guild.setMaxDelegates(10);

        // labels
        vm.label(address(this), "test");
        vm.label(address(core), "core");
        vm.label(address(profitManager), "profitManager");
        vm.label(address(guild), "guild");
        vm.label(address(credit), "credit");
        vm.label(address(rlcm), "rlcm");
        vm.label(address(timelock), "timelock");
        vm.label(address(auctionHouse), "auctionHouse");
        vm.label(address(termImplementation), "termImplementation");
        vm.label(address(onboarder), "onboarder");
        vm.label(alice, "alice");
        vm.label(bob, "bob");
    }

    function testInitialState() public {
        assertEq(onboarder.implementations(address(termImplementation)), true);
        
        assertEq(onboarder.timelock(), address(timelock));
        assertEq(onboarder.votingDelay(), _VOTING_DELAY);
        assertEq(onboarder.votingPeriod(), _VOTING_PERIOD);
        assertEq(onboarder.proposalThreshold(), _PROPOSAL_THRESHOLD);
        assertEq(onboarder.quorum(0), _QUORUM);
        assertEq(onboarder.COUNTING_MODE(), "support=bravo&quorum=for,abstain");
        assertEq(address(onboarder.token()), address(guild));
        assertEq(onboarder.name(), "ECG Governor");
        assertEq(onboarder.version(), "1");
    }

    function testSetQuorum() public {
        vm.expectRevert("UNAUTHORIZED");
        onboarder.setQuorum(_QUORUM * 2);

        vm.prank(governor);
        onboarder.setQuorum(_QUORUM * 2);
        assertEq(onboarder.quorum(0), _QUORUM * 2);
    }

    function testAllowImplementation() public {
        assertEq(onboarder.implementations(address(this)), false);

        vm.expectRevert("UNAUTHORIZED");
        onboarder.allowImplementation(address(this), true);

        vm.prank(governor);
        onboarder.allowImplementation(address(this), true);
        assertEq(onboarder.implementations(address(this)), true);

        vm.prank(governor);
        onboarder.allowImplementation(address(this), false);
        assertEq(onboarder.implementations(address(this)), false);
    }

    function testCreateTerm() public {
        LendingTerm term = LendingTerm(onboarder.createTerm(
            address(termImplementation),
            LendingTerm.LendingTermParams({
                collateralToken: address(collateral),
                maxDebtPerCollateralToken: _CREDIT_PER_COLLATERAL_TOKEN,
                interestRate: _INTEREST_RATE,
                maxDelayBetweenPartialRepay: 123,
                minPartialRepayPercent: 456,
                openingFee: 789,
                hardCap: _HARDCAP
            })
        ));
        vm.label(address(term), "term");
        assertEq(address(term.core()), address(onboarder.core()));

        LendingTerm.LendingTermReferences memory refs = term.getReferences();
        assertEq(refs.profitManager, address(profitManager));
        assertEq(refs.guildToken, address(guild));
        assertEq(refs.auctionHouse, address(auctionHouse));
        assertEq(refs.creditMinter, address(rlcm));
        assertEq(refs.creditToken, address(credit));

        LendingTerm.LendingTermParams memory params = term.getParameters();
        assertEq(params.collateralToken, address(collateral));
        assertEq(params.maxDebtPerCollateralToken, _CREDIT_PER_COLLATERAL_TOKEN);
        assertEq(params.interestRate, _INTEREST_RATE);
        assertEq(params.maxDelayBetweenPartialRepay, 123);
        assertEq(params.minPartialRepayPercent, 456);
        assertEq(params.openingFee, 789);
        assertEq(params.hardCap, _HARDCAP);

        assertEq(onboarder.created(address(term)), block.timestamp);
    }

    function testCreateCheckParams() public {
        vm.expectRevert("LendingTermOnboarding: invalid implementation");
        onboarder.createTerm(address(this), LendingTerm.LendingTermParams({
            collateralToken: address(collateral),
            maxDebtPerCollateralToken: _CREDIT_PER_COLLATERAL_TOKEN,
            interestRate: _INTEREST_RATE,
            maxDelayBetweenPartialRepay: 123,
            minPartialRepayPercent: 456,
            openingFee: 789,
            hardCap: _HARDCAP
        }));
        vm.expectRevert("LendingTermOnboarding: invalid collateralToken");
        onboarder.createTerm(address(termImplementation), LendingTerm.LendingTermParams({
            collateralToken: address(0), // not a token
            maxDebtPerCollateralToken: _CREDIT_PER_COLLATERAL_TOKEN,
            interestRate: _INTEREST_RATE,
            maxDelayBetweenPartialRepay: 123,
            minPartialRepayPercent: 456,
            openingFee: 789,
            hardCap: _HARDCAP
        }));
        vm.expectRevert("LendingTermOnboarding: invalid maxDebtPerCollateralToken");
        onboarder.createTerm(address(termImplementation), LendingTerm.LendingTermParams({
            collateralToken: address(collateral),
            maxDebtPerCollateralToken: 0, // no debt available
            interestRate: _INTEREST_RATE,
            maxDelayBetweenPartialRepay: 123,
            minPartialRepayPercent: 456,
            openingFee: 789,
            hardCap: _HARDCAP
        }));
        vm.expectRevert("LendingTermOnboarding: invalid interestRate");
        onboarder.createTerm(address(termImplementation), LendingTerm.LendingTermParams({
            collateralToken: address(collateral),
            maxDebtPerCollateralToken: _CREDIT_PER_COLLATERAL_TOKEN,
            interestRate: 1e18, // 100% APR is too high
            maxDelayBetweenPartialRepay: 123,
            minPartialRepayPercent: 456,
            openingFee: 789,
            hardCap: _HARDCAP
        }));
        vm.expectRevert("LendingTermOnboarding: invalid maxDelayBetweenPartialRepay");
        onboarder.createTerm(address(termImplementation), LendingTerm.LendingTermParams({
            collateralToken: address(collateral),
            maxDebtPerCollateralToken: _CREDIT_PER_COLLATERAL_TOKEN,
            interestRate: _INTEREST_RATE,
            maxDelayBetweenPartialRepay: 2 * 365 * 24 * 3600, // 2 years between payments is too long
            minPartialRepayPercent: 456,
            openingFee: 789,
            hardCap: _HARDCAP
        }));
        vm.expectRevert("LendingTermOnboarding: invalid minPartialRepayPercent");
        onboarder.createTerm(address(termImplementation), LendingTerm.LendingTermParams({
            collateralToken: address(collateral),
            maxDebtPerCollateralToken: _CREDIT_PER_COLLATERAL_TOKEN,
            interestRate: _INTEREST_RATE,
            maxDelayBetweenPartialRepay: 123,
            minPartialRepayPercent: 1e18, // min repay of 100% is too high
            openingFee: 789,
            hardCap: _HARDCAP
        }));
        vm.expectRevert("LendingTermOnboarding: invalid openingFee");
        onboarder.createTerm(address(termImplementation), LendingTerm.LendingTermParams({
            collateralToken: address(collateral),
            maxDebtPerCollateralToken: _CREDIT_PER_COLLATERAL_TOKEN,
            interestRate: _INTEREST_RATE,
            maxDelayBetweenPartialRepay: 123,
            minPartialRepayPercent: 456,
            openingFee: 1e18, // 100% opening fee is too high
            hardCap: _HARDCAP
        }));
        vm.expectRevert("LendingTermOnboarding: invalid hardCap");
        onboarder.createTerm(address(termImplementation), LendingTerm.LendingTermParams({
            collateralToken: address(collateral),
            maxDebtPerCollateralToken: _CREDIT_PER_COLLATERAL_TOKEN,
            interestRate: _INTEREST_RATE,
            maxDelayBetweenPartialRepay: 123,
            minPartialRepayPercent: 456,
            openingFee: 789,
            hardCap: 0 // hardCap of 0 makes no debt available
        }));
    }

    function testProposeArbitraryCallsReverts() public {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        vm.expectRevert("LendingTermOnboarding: cannot propose arbitrary actions");
        onboarder.propose(targets, values, payloads, "test");
    }

    function testProposeOnboardPausable() public {
        // pause term
        vm.prank(guardian);
        onboarder.pause();

        // propose onboard
        vm.prank(alice);
        vm.expectRevert("Pausable: paused");
        onboarder.proposeOnboard(address(this));
    }

    function testProposeOnboard() public {
        LendingTerm term = LendingTerm(onboarder.createTerm(address(termImplementation), LendingTerm.LendingTermParams({
            collateralToken: address(collateral),
            maxDebtPerCollateralToken: _CREDIT_PER_COLLATERAL_TOKEN,
            interestRate: _INTEREST_RATE,
            maxDelayBetweenPartialRepay: 0,
            minPartialRepayPercent: 0,
            openingFee: 0,
            hardCap: _HARDCAP
        })));
        vm.label(address(term), "term");
        
        // cannot propose an arbitrary address (must come from factory)
        vm.expectRevert("LendingTermOnboarding: invalid term");
        onboarder.proposeOnboard(address(this));

        // cannot propose if the user doesn't have enough GUILD
        vm.expectRevert("Governor: proposer votes below proposal threshold");
        onboarder.proposeOnboard(address(term));

        // mint GUILD & self delegate
        guild.mint(alice, _PROPOSAL_THRESHOLD);
        guild.mint(bob, _QUORUM);
        vm.prank(alice);
        guild.delegate(alice);
        vm.prank(bob);
        guild.incrementDelegation(bob, _QUORUM);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 13);

        // propose onboard
        vm.prank(alice);
        uint256 proposalId = onboarder.proposeOnboard(address(term));
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = onboarder.getOnboardProposeArgs(address(term));

        // cannot propose the same term multiple times in a short interval of time
        vm.expectRevert("LendingTermOnboarding: recently proposed");
        onboarder.proposeOnboard(address(term));

        // check proposal creation
        assertEq(uint8(onboarder.state(proposalId)), uint8(IGovernor.ProposalState.Pending));
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 13);
        assertEq(uint8(onboarder.state(proposalId)), uint8(IGovernor.ProposalState.Active));

        // support & check status
        vm.prank(bob);
        onboarder.castVote(proposalId, uint8(GovernorCountingSimple.VoteType.For));
        vm.roll(block.number + _VOTING_PERIOD + 1);
        vm.warp(block.timestamp + 13);
        assertEq(uint8(onboarder.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded));

        // queue
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 13);
        onboarder.queue(targets, values, calldatas, keccak256(bytes(description)));
        assertEq(uint8(onboarder.state(proposalId)), uint8(IGovernor.ProposalState.Queued));

        // execute
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + _TIMELOCK_MIN_DELAY + 13);
        onboarder.execute(targets, values, calldatas, keccak256(bytes(description)));
        assertEq(uint8(onboarder.state(proposalId)), uint8(IGovernor.ProposalState.Executed));

        // check execution
        assertEq(guild.isGauge(address(term)), true);

        // cannot propose the same term twice if it's already active
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 7 days + 13);
        vm.expectRevert("LendingTermOnboarding: active term");
        onboarder.proposeOnboard(address(term));

        // vote for the term
        guild.mint(address(this), 1e18);
        guild.incrementGauge(address(term), 1e18);

        // do a borrow
        collateral.mint(address(this), 1e24);
        collateral.approve(address(term), 1e24);
        term.borrow(1e24, 1e24);
        assertEq(collateral.balanceOf(address(this)), 0);
        assertEq(collateral.balanceOf(address(term)), 1e24);
        assertEq(credit.balanceOf(address(this)), 1e24);
    }

    function testOnboardAgainLater() public {
        LendingTerm term = LendingTerm(onboarder.createTerm(address(termImplementation), LendingTerm.LendingTermParams({
            collateralToken: address(collateral),
            maxDebtPerCollateralToken: _CREDIT_PER_COLLATERAL_TOKEN,
            interestRate: _INTEREST_RATE,
            maxDelayBetweenPartialRepay: 0,
            minPartialRepayPercent: 0,
            openingFee: 0,
            hardCap: _HARDCAP
        })));
        vm.label(address(term), "term");

        // mint GUILD & self delegate
        guild.mint(bob, _QUORUM);
        vm.prank(bob);
        guild.incrementDelegation(bob, _QUORUM);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 13);

        // do onboard
        vm.startPrank(bob);
        uint256 proposalId = onboarder.proposeOnboard(address(term));
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = onboarder.getOnboardProposeArgs(address(term));
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 13);
        onboarder.castVote(proposalId, uint8(GovernorCountingSimple.VoteType.For));
        vm.roll(block.number + _VOTING_PERIOD + 1);
        vm.warp(block.timestamp + 13);
        onboarder.queue(targets, values, calldatas, keccak256(bytes(description)));
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + _TIMELOCK_MIN_DELAY + 13);
        onboarder.execute(targets, values, calldatas, keccak256(bytes(description)));
        vm.stopPrank();

        // check execution
        assertEq(guild.isGauge(address(term)), true);

        // offboard
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 7 days + 13);
        guild.removeGauge(address(term));
        vm.startPrank(governor);
        core.revokeRole(CoreRoles.GAUGE_PNL_NOTIFIER, address(term));
        core.revokeRole(CoreRoles.RATE_LIMITED_CREDIT_MINTER, address(term));
        vm.stopPrank();
        assertEq(guild.isGauge(address(term)), false);

        // do onboard another time
        vm.startPrank(bob);
        proposalId = onboarder.proposeOnboard(address(term));
        (
            targets,
            values,
            calldatas,
            description
        ) = onboarder.getOnboardProposeArgs(address(term));
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 13);
        onboarder.castVote(proposalId, uint8(GovernorCountingSimple.VoteType.For));
        vm.roll(block.number + _VOTING_PERIOD + 1);
        vm.warp(block.timestamp + 13);
        onboarder.queue(targets, values, calldatas, keccak256(bytes(description)));
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + _TIMELOCK_MIN_DELAY + 13);
        onboarder.execute(targets, values, calldatas, keccak256(bytes(description)));
        vm.stopPrank();

        // check execution
        assertEq(guild.isGauge(address(term)), true);
    }
}
