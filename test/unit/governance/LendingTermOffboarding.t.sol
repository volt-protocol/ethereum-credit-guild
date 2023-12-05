// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

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
import {LendingTermOffboarding} from "@src/governance/LendingTermOffboarding.sol";

contract LendingTermOffboardingUnitTest is Test {
    address private governor = address(1);
    Core private core;
    ProfitManager private profitManager;
    GuildToken private guild;
    CreditToken private credit;
    MockERC20 private collateral;
    SimplePSM private psm;
    LendingTerm private term;
    AuctionHouse auctionHouse;
    RateLimitedMinter rlcm;
    LendingTermOffboarding private offboarder;
    address private constant alice = address(0x616c696365);
    address private constant bob = address(0xB0B);
    address private constant carol = address(0xca201);
    bytes32 private aliceLoanId;
    uint256 private aliceLoanSize = 500_000e18;

    // LendingTerm params
    uint256 private constant _CREDIT_PER_COLLATERAL_TOKEN = 1e18; // 1:1, same decimals
    uint256 private constant _INTEREST_RATE = 0.05e18; // 5% APR
    uint256 private constant _HARDCAP = 1_000_000e18;

    // LendingTermOffboarding params
    uint32 private constant _QUORUM = 10 minutes;

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
        profitManager.initializeReferences(address(credit), address(guild), address(psm));
        offboarder = new LendingTermOffboarding(
            address(core),
            address(guild),
            address(psm),
            _QUORUM
        );
        auctionHouse = new AuctionHouse(
            address(core),
            650,
            1800
        );
        term = LendingTerm(Clones.clone(address(new LendingTerm())));
        term.initialize(
            address(core),
            LendingTerm.LendingTermReferences({
                profitManager: address(profitManager),
                guildToken: address(guild),
                auctionHouse: address(auctionHouse),
                creditMinter: address(rlcm),
                creditToken: address(credit)
            }),
            LendingTerm.LendingTermParams({
                collateralToken: address(collateral),
                maxDebtPerCollateralToken: _CREDIT_PER_COLLATERAL_TOKEN,
                interestRate: _INTEREST_RATE,
                maxDelayBetweenPartialRepay: 0,
                minPartialRepayPercent: 0,
                openingFee: 0,
                hardCap: _HARDCAP
            })
        );
        
        // permissions
        core.grantRole(CoreRoles.GOVERNOR, governor);
        core.grantRole(CoreRoles.CREDIT_MINTER, address(this));
        core.grantRole(CoreRoles.GUILD_MINTER, address(this));
        core.grantRole(CoreRoles.GAUGE_ADD, address(this));
        core.grantRole(CoreRoles.GAUGE_REMOVE, address(this));
        core.grantRole(CoreRoles.GAUGE_REMOVE, address(offboarder));
        core.grantRole(CoreRoles.GAUGE_PARAMETERS, address(this));
        core.grantRole(CoreRoles.GUILD_GOVERNANCE_PARAMETERS, address(this));
        core.grantRole(CoreRoles.CREDIT_MINTER, address(rlcm));
        core.grantRole(CoreRoles.RATE_LIMITED_CREDIT_MINTER, address(term));
        core.grantRole(CoreRoles.GAUGE_PNL_NOTIFIER, address(term));
        core.grantRole(CoreRoles.GOVERNOR, address(offboarder));
        core.renounceRole(CoreRoles.GOVERNOR, address(this));

        // add gauge and vote for it
        guild.setMaxGauges(10);
        guild.addGauge(1, address(term));
        guild.mint(address(this), _HARDCAP * 2);
        guild.incrementGauge(address(term), _HARDCAP);

        // allow GUILD delegations
        guild.setMaxDelegates(10);

        // alice borrows
        collateral.mint(alice, aliceLoanSize);
        vm.startPrank(alice);
        collateral.approve(address(term), aliceLoanSize);
        aliceLoanId = term.borrow(aliceLoanSize, aliceLoanSize);
        vm.stopPrank();

        // labels
        vm.label(address(this), "test");
        vm.label(address(core), "core");
        vm.label(address(profitManager), "profitManager");
        vm.label(address(guild), "guild");
        vm.label(address(credit), "credit");
        vm.label(address(rlcm), "rlcm");
        vm.label(address(auctionHouse), "auctionHouse");
        vm.label(address(term), "term");
        vm.label(address(offboarder), "offboarder");
        vm.label(alice, "alice");
        vm.label(bob, "bob");
        vm.label(carol, "carol");
    }

    function testInitialState() public {
        assertEq(offboarder.guildToken(), address(guild));
        assertEq(offboarder.quorum(), _QUORUM);
        assertEq(offboarder.polls(block.number, address(term)), 0);
        assertEq(offboarder.lastPollBlock(address(term)), 0);
        assertEq(offboarder.canOffboard(address(term)), false);
        assertEq(psm.redemptionsPaused(), false);
    }

    function testSetQuorum() public {
        vm.expectRevert("UNAUTHORIZED");
        offboarder.setQuorum(_QUORUM * 2);

        vm.prank(governor);
        offboarder.setQuorum(_QUORUM * 2);
        assertEq(offboarder.quorum(), _QUORUM * 2);
    }

    function testProposeOffboard() public {
        offboarder.proposeOffboard(address(term));
        
        assertEq(offboarder.polls(block.number, address(term)), 1);
        assertEq(offboarder.lastPollBlock(address(term)), block.number);

        // cannot ask to offboard an address that is not an active term
        vm.expectRevert("LendingTermOffboarding: not an active term");
        offboarder.proposeOffboard(address(this));

        // cannot ask in the same block because the poll exists
        vm.expectRevert("LendingTermOffboarding: poll exists");
        offboarder.proposeOffboard(address(term));

        // cannot ask during the voting period because poll exists
        vm.roll(block.number + 100);
        vm.warp(block.timestamp + 1300);
        vm.expectRevert("LendingTermOffboarding: poll active");
        offboarder.proposeOffboard(address(term));

        // can ask again at the end of voting period, to re-create the poll
        vm.roll(block.number + 100_000);
        vm.warp(block.timestamp + 1300_000);
        offboarder.proposeOffboard(address(term));
        assertEq(offboarder.polls(block.number, address(term)), 1);
        assertEq(offboarder.lastPollBlock(address(term)), block.number);
    }

    function testSupportOffboard() public {
        // bob self delegates tokens
        guild.mint(bob, _QUORUM / 2);
        vm.prank(bob);
        guild.delegate(bob);

        // alice delegates tokens to carol
        guild.mint(alice, _QUORUM / 2);
        vm.prank(alice);
        guild.delegate(carol);

        // cannot attempt to support old polls
        uint256 POLL_DURATION_BLOCKS = offboarder.POLL_DURATION_BLOCKS();
        vm.expectRevert("LendingTermOffboarding: poll expired");
        offboarder.supportOffboard(block.number - POLL_DURATION_BLOCKS - 1, address(term));

        // cannot vote for a poll that doesn't exist
        vm.expectRevert("LendingTermOffboarding: poll not found");
        offboarder.supportOffboard(block.number, address(term));

        // create poll
        uint256 snapshotBlock = block.number;
        offboarder.proposeOffboard(address(term));
        assertEq(offboarder.lastPollBlock(address(term)), snapshotBlock);

        // cannot vote for a poll created in the same block
        vm.expectRevert("ERC20MultiVotes: not a past block");
        offboarder.supportOffboard(block.number, address(term));
    
        // cannot vote for a poll if we don't have tokens
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 13);
        vm.expectRevert("LendingTermOffboarding: zero weight");
        offboarder.supportOffboard(snapshotBlock, address(term));

        // bob supports offboard
        vm.prank(bob);
        offboarder.supportOffboard(snapshotBlock, address(term));
        assertEq(offboarder.polls(snapshotBlock, address(term)), _QUORUM / 2 + 1);
        assertEq(offboarder.canOffboard(address(term)), false);

        // carol supports offboard
        vm.prank(carol);
        offboarder.supportOffboard(snapshotBlock, address(term));
        assertEq(offboarder.polls(snapshotBlock, address(term)), _QUORUM + 1);
        assertEq(offboarder.canOffboard(address(term)), true);
    }

    function testOffboard() public {
        // prepare (1)
        guild.mint(bob, _QUORUM);
        vm.startPrank(bob);
        guild.delegate(bob);
        uint256 snapshotBlock = block.number;
        offboarder.proposeOffboard(address(term));
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 13);

        // cannot offboard if quorum is not met
        vm.expectRevert("LendingTermOffboarding: quorum not met");
        offboarder.offboard(address(term));

        // prepare (2)
        offboarder.supportOffboard(snapshotBlock, address(term));
        assertEq(offboarder.polls(snapshotBlock, address(term)), _QUORUM + 1);
        assertEq(offboarder.canOffboard(address(term)), true);

        // properly offboard a term
        assertEq(guild.isGauge(address(term)), true);
        assertEq(psm.redemptionsPaused(), false);
        assertEq(offboarder.nOffboardingsInProgress(), 0);
        offboarder.offboard(address(term));
        assertEq(guild.isGauge(address(term)), false);
        assertEq(psm.redemptionsPaused(), true);
        assertEq(offboarder.nOffboardingsInProgress(), 1);
        
        // get enough CREDIT to pack back interests
        vm.stopPrank();
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 13);
        uint256 debt = term.getLoanDebt(aliceLoanId);
        credit.mint(alice, debt - aliceLoanSize);

        vm.startPrank(alice);
        // can close loans
        credit.approve(address(term), debt);
        term.repay(aliceLoanId);

        // cannot open new loans
        collateral.approve(address(term), aliceLoanSize);
        vm.expectRevert("LendingTerm: debt ceiling reached");
        aliceLoanId = term.borrow(aliceLoanSize, aliceLoanSize);
        vm.stopPrank();
    }

    function testCleanup() public {
        // prepare (1)
        guild.mint(bob, _QUORUM);
        vm.startPrank(bob);
        guild.delegate(bob);
        uint256 snapshotBlock = block.number;
        offboarder.proposeOffboard(address(term));
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 13);
        vm.expectRevert("LendingTermOffboarding: quorum not met");
        offboarder.cleanup(address(term));
        offboarder.supportOffboard(snapshotBlock, address(term));
        offboarder.offboard(address(term));

        // cannot cleanup because loans are active
        vm.expectRevert("LendingTermOffboarding: not all loans closed");
        offboarder.cleanup(address(term));

        // get enough CREDIT to pack back interests
        vm.stopPrank();
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 13);
        uint256 debt = term.getLoanDebt(aliceLoanId);
        credit.mint(alice, debt - aliceLoanSize);

        // close loans
        vm.startPrank(alice);
        credit.approve(address(term), debt);
        term.repay(aliceLoanId);
        vm.stopPrank();

        // cleanup
        assertEq(psm.redemptionsPaused(), true);
        assertEq(offboarder.nOffboardingsInProgress(), 1);
        offboarder.cleanup(address(term));
        assertEq(psm.redemptionsPaused(), false);
        assertEq(offboarder.nOffboardingsInProgress(), 0);

        assertEq(offboarder.canOffboard(address(term)), false);
        assertEq(core.hasRole(CoreRoles.GAUGE_PNL_NOTIFIER, address(term)), false);
        assertEq(core.hasRole(CoreRoles.RATE_LIMITED_CREDIT_MINTER, address(term)), false);
    }

    function testCannotVoteTwice() public {
        // prepare (1)
        guild.mint(bob, _QUORUM / 2);
        vm.startPrank(bob);
        guild.delegate(bob);
        uint256 snapshotBlock = block.number;
        offboarder.proposeOffboard(address(term));
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 13);

        // cannot offboard if quorum is not met
        vm.expectRevert("LendingTermOffboarding: quorum not met");
        offboarder.offboard(address(term));

        // vote once
        offboarder.supportOffboard(snapshotBlock, address(term));
        assertEq(offboarder.polls(snapshotBlock, address(term)), _QUORUM / 2 + 1);
        assertEq(offboarder.canOffboard(address(term)), false);
    
        // cannot vote twice
        vm.expectRevert("LendingTermOffboarding: already voted");
        offboarder.supportOffboard(snapshotBlock, address(term));
        assertEq(offboarder.polls(snapshotBlock, address(term)), _QUORUM / 2 + 1);
        assertEq(offboarder.canOffboard(address(term)), false);
    }

    function testCannotCleanupAfterReonboard() public {
        // prepare (1)
        guild.mint(bob, _QUORUM);
        vm.startPrank(bob);
        guild.delegate(bob);
        uint256 snapshotBlock = block.number;
        offboarder.proposeOffboard(address(term));
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 13);
        offboarder.supportOffboard(snapshotBlock, address(term));
        offboarder.offboard(address(term));

        // get enough CREDIT to pack back interests
        vm.stopPrank();
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 13);
        uint256 debt = term.getLoanDebt(aliceLoanId);
        credit.mint(alice, debt - aliceLoanSize);

        // close loans
        vm.startPrank(alice);
        credit.approve(address(term), debt);
        term.repay(aliceLoanId);
        vm.stopPrank();

        // re-onboard
        guild.addGauge(1, address(term));

        // cleanup
        vm.expectRevert("LendingTermOffboarding: re-onboarded");
        offboarder.cleanup(address(term));
    }
}
