// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Governor, IGovernor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";

import {ECGTest} from "@test/ECGTest.sol";
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
import {LendingTermFactory} from "@src/governance/LendingTermFactory.sol";
import {LendingTermAdjustable} from "@src/loan/LendingTermAdjustable.sol";
import {LendingTermParamManager} from "@src/governance/LendingTermParamManager.sol";
import {GuildTimelockController} from "@src/governance/GuildTimelockController.sol";

contract LendingTermParamManagerUnitTest is ECGTest {
    address private governor = address(1);
    address private guardian = address(2);
    Core private core;
    ProfitManager private profitManager;
    GuildToken private guild;
    CreditToken private credit;
    MockERC20 private collateral;
    SimplePSM private psm;
    LendingTermAdjustable private termImplementation;
    LendingTermAdjustable private term;
    AuctionHouse public auctionHouse;
    RateLimitedMinter rlcm;
    GuildTimelockController private timelock;
    LendingTermFactory private factory;
    LendingTermParamManager private paramMgr;
    address private constant alice = address(0x616c696365);
    address private constant bob = address(0xB0B);

    // GuildTimelockController params
    uint256 private constant _TIMELOCK_MIN_DELAY = 3600; // 1h

    // LendingTerm params
    uint256 private constant _CREDIT_PER_COLLATERAL_TOKEN = 1e18; // 1:1, same decimals
    uint256 private constant _INTEREST_RATE = 0.05e18; // 5% APR
    uint256 private constant _HARDCAP = 1_000_000e18;

    // LendingTermParamManager params
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
        guild = new GuildToken(address(core));
        collateral = new MockERC20();
        rlcm = new RateLimitedMinter(
            address(core) /*_core*/,
            address(credit) /*_token*/,
            CoreRoles.RATE_LIMITED_CREDIT_MINTER /*_role*/,
            type(uint256).max /*_maxRateLimitPerSecond*/,
            type(uint128).max /*_rateLimitPerSecond*/,
            type(uint128).max /*_bufferCap*/
        );
        psm = new SimplePSM(
            address(core),
            address(profitManager),
            address(credit),
            address(collateral)
        );
        auctionHouse = new AuctionHouse(address(core), 650, 1800, 0);
        termImplementation = new LendingTermAdjustable();
        timelock = new GuildTimelockController(
            address(core),
            _TIMELOCK_MIN_DELAY
        );
        factory = new LendingTermFactory(address(core), address(guild));
        paramMgr = new LendingTermParamManager(
            address(core), // _core
            address(timelock), // _timelock
            address(guild), // _guildToken
            _VOTING_DELAY, // initialVotingDelay
            _VOTING_PERIOD, // initialVotingPeriod
            _PROPOSAL_THRESHOLD, // initialProposalThreshold
            _QUORUM // initialQuorum
        );
        factory.allowImplementation(address(termImplementation), true);
        factory.allowAuctionHouse(address(auctionHouse), true);
        factory.setMarketReferences(
            1,
            LendingTermFactory.MarketReferences({
                profitManager: address(profitManager),
                creditMinter: address(rlcm),
                creditToken: address(credit),
                psm: address(psm)
            })
        );

        profitManager.initializeReferences(address(credit), address(guild));

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
        core.grantRole(CoreRoles.TIMELOCK_PROPOSER, address(paramMgr));
        core.renounceRole(CoreRoles.GOVERNOR, address(this));

        // allow GUILD gauge votes & delegations
        guild.setMaxGauges(10);
        guild.setMaxDelegates(10);

        // create one term
        term = LendingTermAdjustable(
            factory.createTerm(
                1,
                address(termImplementation),
                address(auctionHouse),
                abi.encode(
                    LendingTerm.LendingTermParams({
                        collateralToken: address(collateral),
                        maxDebtPerCollateralToken: _CREDIT_PER_COLLATERAL_TOKEN,
                        interestRate: _INTEREST_RATE,
                        maxDelayBetweenPartialRepay: 123,
                        minPartialRepayPercent: 456,
                        openingFee: 789,
                        hardCap: _HARDCAP
                    })
                )
            )
        );
        guild.addGauge(1, address(term));

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
        vm.label(address(paramMgr), "paramMgr");
        vm.label(address(term), "term");
        vm.label(alice, "alice");
        vm.label(bob, "bob");
    }

    function testInitialState() public {
        assertEq(factory.implementations(address(termImplementation)), true);

        assertEq(paramMgr.timelock(), address(timelock));
        assertEq(paramMgr.votingDelay(), _VOTING_DELAY);
        assertEq(paramMgr.votingPeriod(), _VOTING_PERIOD);
        assertEq(paramMgr.proposalThreshold(), _PROPOSAL_THRESHOLD);
        assertEq(paramMgr.quorum(0), _QUORUM);
        assertEq(paramMgr.COUNTING_MODE(), "support=bravo&quorum=for,abstain");
        assertEq(address(paramMgr.token()), address(guild));
        assertEq(paramMgr.name(), "ECG Governor");
        assertEq(paramMgr.version(), "1");

        assertEq(term.getParameters().maxDebtPerCollateralToken, _CREDIT_PER_COLLATERAL_TOKEN);
        assertEq(term.getParameters().interestRate, _INTEREST_RATE);
        assertEq(term.getParameters().hardCap, _HARDCAP);
    }

    function testProposeArbitraryCallsReverts() public {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        vm.expectRevert(
            "LendingTermParamManager: cannot propose arbitrary actions"
        );
        paramMgr.propose(targets, values, payloads, "test");
    }

    function testProposePausable() public {
        // pause
        vm.prank(guardian);
        paramMgr.pause();

        // propose
        vm.startPrank(alice);
        vm.expectRevert("Pausable: paused");
        paramMgr.proposeSetHardCap(address(term), 123);
        vm.expectRevert("Pausable: paused");
        paramMgr.proposeSetInterestRate(address(term), 123);
        vm.expectRevert("Pausable: paused");
        paramMgr.proposeSetMaxDebtPerCollateralToken(address(term), 123);
    }

    function testProposeSetHardCap() public {
        uint256 hardCap = 123456789;

        // cannot propose if the user doesn't have enough GUILD
        vm.expectRevert("Governor: proposer votes below proposal threshold");
        paramMgr.proposeSetHardCap(address(term), hardCap);

        // mint GUILD & self delegate
        guild.mint(alice, _PROPOSAL_THRESHOLD);
        guild.mint(bob, _QUORUM);
        vm.prank(alice);
        guild.delegate(alice);
        vm.prank(bob);
        guild.incrementDelegation(bob, _QUORUM);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 13);

        // propose
        vm.prank(alice);
        uint256 proposalId = paramMgr.proposeSetHardCap(address(term), hardCap);

        address[] memory targets = new address[](1);
        targets[0] = address(term);
        uint256[] memory values = new uint256[](1); // [0]
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature(
            "setHardCap(uint256)",
            hardCap
        );
        string memory description = string.concat(
            "Update hard cap\n\n[",
            Strings.toString(block.number),
            "]",
            " set hardCap of term ",
            Strings.toHexString(address(term)),
            " to ",
            Strings.toString(hardCap)
        );

        // check proposal creation
        assertEq(
            uint8(paramMgr.state(proposalId)),
            uint8(IGovernor.ProposalState.Pending)
        );
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 13);
        assertEq(
            uint8(paramMgr.state(proposalId)),
            uint8(IGovernor.ProposalState.Active)
        );

        // cannot cancel
        vm.expectRevert("LendingTermParamManager: cannot cancel proposals");
        paramMgr.cancel(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );

        // support & check status
        vm.prank(bob);
        paramMgr.castVote(
            proposalId,
            uint8(GovernorCountingSimple.VoteType.For)
        );
        vm.roll(block.number + _VOTING_PERIOD + 1);
        vm.warp(block.timestamp + 13);
        assertEq(
            uint8(paramMgr.state(proposalId)),
            uint8(IGovernor.ProposalState.Succeeded)
        );

        // queue
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 13);
        paramMgr.queue(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );
        assertEq(
            uint8(paramMgr.state(proposalId)),
            uint8(IGovernor.ProposalState.Queued)
        );

        // execute
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + _TIMELOCK_MIN_DELAY + 13);
        paramMgr.execute(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );
        assertEq(
            uint8(paramMgr.state(proposalId)),
            uint8(IGovernor.ProposalState.Executed)
        );

        // check execution
        assertEq(term.getParameters().hardCap, hardCap);
    }

    function testProposeSetInterestRate() public {
        uint256 interestRate = 123456789;

        // cannot propose if the user doesn't have enough GUILD
        vm.expectRevert("Governor: proposer votes below proposal threshold");
        paramMgr.proposeSetInterestRate(address(term), interestRate);

        // mint GUILD & self delegate
        guild.mint(alice, _PROPOSAL_THRESHOLD);
        guild.mint(bob, _QUORUM);
        vm.prank(alice);
        guild.delegate(alice);
        vm.prank(bob);
        guild.incrementDelegation(bob, _QUORUM);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 13);

        // propose
        vm.prank(alice);
        uint256 proposalId = paramMgr.proposeSetInterestRate(address(term), interestRate);

        address[] memory targets = new address[](1);
        targets[0] = address(term);
        uint256[] memory values = new uint256[](1); // [0]
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature(
            "setInterestRate(uint256)",
            interestRate
        );
        string memory description = string.concat(
            "Update interest rate\n\n[",
            Strings.toString(block.number),
            "]",
            " set interestRate of term ",
            Strings.toHexString(address(term)),
            " to ",
            Strings.toString(interestRate)
        );

        // check proposal creation
        assertEq(
            uint8(paramMgr.state(proposalId)),
            uint8(IGovernor.ProposalState.Pending)
        );
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 13);
        assertEq(
            uint8(paramMgr.state(proposalId)),
            uint8(IGovernor.ProposalState.Active)
        );

        // cannot cancel
        vm.expectRevert("LendingTermParamManager: cannot cancel proposals");
        paramMgr.cancel(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );

        // support & check status
        vm.prank(bob);
        paramMgr.castVote(
            proposalId,
            uint8(GovernorCountingSimple.VoteType.For)
        );
        vm.roll(block.number + _VOTING_PERIOD + 1);
        vm.warp(block.timestamp + 13);
        assertEq(
            uint8(paramMgr.state(proposalId)),
            uint8(IGovernor.ProposalState.Succeeded)
        );

        // queue
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 13);
        paramMgr.queue(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );
        assertEq(
            uint8(paramMgr.state(proposalId)),
            uint8(IGovernor.ProposalState.Queued)
        );

        // execute
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + _TIMELOCK_MIN_DELAY + 13);
        paramMgr.execute(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );
        assertEq(
            uint8(paramMgr.state(proposalId)),
            uint8(IGovernor.ProposalState.Executed)
        );

        // check execution
        assertEq(term.getParameters().interestRate, interestRate);
    }

    function testProposeSetMaxDebtPerCollateralToken() public {
        uint256 maxDebtPerCollateralToken = 123456789;

        // cannot propose if the user doesn't have enough GUILD
        vm.expectRevert("Governor: proposer votes below proposal threshold");
        paramMgr.proposeSetMaxDebtPerCollateralToken(address(term), maxDebtPerCollateralToken);

        // mint GUILD & self delegate
        guild.mint(alice, _PROPOSAL_THRESHOLD);
        guild.mint(bob, _QUORUM);
        vm.prank(alice);
        guild.delegate(alice);
        vm.prank(bob);
        guild.incrementDelegation(bob, _QUORUM);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 13);

        // propose
        vm.prank(alice);
        uint256 proposalId = paramMgr.proposeSetMaxDebtPerCollateralToken(address(term), maxDebtPerCollateralToken);

        address[] memory targets = new address[](1);
        targets[0] = address(term);
        uint256[] memory values = new uint256[](1); // [0]
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature(
            "setMaxDebtPerCollateralToken(uint256)",
            maxDebtPerCollateralToken
        );
        string memory description = string.concat(
            "Update borrow ratio\n\n[",
            Strings.toString(block.number),
            "]",
            " set maxDebtPerCollateralToken of term ",
            Strings.toHexString(address(term)),
            " to ",
            Strings.toString(maxDebtPerCollateralToken)
        );

        // check proposal creation
        assertEq(
            uint8(paramMgr.state(proposalId)),
            uint8(IGovernor.ProposalState.Pending)
        );
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 13);
        assertEq(
            uint8(paramMgr.state(proposalId)),
            uint8(IGovernor.ProposalState.Active)
        );

        // cannot cancel
        vm.expectRevert("LendingTermParamManager: cannot cancel proposals");
        paramMgr.cancel(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );

        // support & check status
        vm.prank(bob);
        paramMgr.castVote(
            proposalId,
            uint8(GovernorCountingSimple.VoteType.For)
        );
        vm.roll(block.number + _VOTING_PERIOD + 1);
        vm.warp(block.timestamp + 13);
        assertEq(
            uint8(paramMgr.state(proposalId)),
            uint8(IGovernor.ProposalState.Succeeded)
        );

        // queue
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 13);
        paramMgr.queue(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );
        assertEq(
            uint8(paramMgr.state(proposalId)),
            uint8(IGovernor.ProposalState.Queued)
        );

        // execute
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + _TIMELOCK_MIN_DELAY + 13);
        paramMgr.execute(
            targets,
            values,
            calldatas,
            keccak256(bytes(description))
        );
        assertEq(
            uint8(paramMgr.state(proposalId)),
            uint8(IGovernor.ProposalState.Executed)
        );

        // check execution
        assertEq(term.getParameters().maxDebtPerCollateralToken, maxDebtPerCollateralToken);
    }
}
