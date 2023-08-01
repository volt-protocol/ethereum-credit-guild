// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Test} from "@forge-std/Test.sol";
import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {AuctionHouse} from "@src/loan/AuctionHouse.sol";
import {LendingTermOffboarding} from "@src/governance/LendingTermOffboarding.sol";
import {RateLimitedCreditMinter} from "@src/rate-limits/RateLimitedCreditMinter.sol";

contract LendingTermOffboardingUnitTest is Test {
    address private governor = address(1);
    Core private core;
    GuildToken private guild;
    CreditToken private credit;
    MockERC20 private collateral;
    LendingTerm private term;
    AuctionHouse auctionHouse;
    RateLimitedCreditMinter rlcm;
    LendingTermOffboarding private offboarder;
    address private constant alice = address(0x616c696365);
    address private constant bob = address(0xB0B);
    address private constant carol = address(0xca201);
    bytes32 private aliceLoanId;
    uint256 private aliceLoanSize = 500_000e18;

    // GUILD params
    uint32 private constant _CYCLE_LENGTH = 1 hours;
    uint32 private constant _FREEZE_PERIOD = 10 minutes;

    // LendingTerm params
    uint256 private constant _CREDIT_PER_COLLATERAL_TOKEN = 1e18; // 1:1, same decimals
    uint256 private constant _INTEREST_RATE = 0; // 0% APR
    uint256 private constant _CALL_FEE = 0.05e18; // 5%
    uint256 private constant _CALL_PERIOD = 1 hours;
    uint256 private constant _HARDCAP = 1_000_000e18;
    uint256 private constant _LTV_BUFFER = 0; // 0%

    // LendingTermOffboarding params
    uint32 private constant _QUORUM = 10 minutes;

    function setUp() public {
        vm.warp(1679067867);
        vm.roll(16848497);

        // deploy
        core = new Core();
        credit = new CreditToken(address(core));
        guild = new GuildToken(address(core), address(credit), _CYCLE_LENGTH, _FREEZE_PERIOD);
        collateral = new MockERC20();
        rlcm = new RateLimitedCreditMinter(
            address(core), /*_core*/
            address(credit), /*_token*/
            type(uint256).max, /*_maxRateLimitPerSecond*/
            type(uint128).max, /*_rateLimitPerSecond*/
            type(uint128).max /*_bufferCap*/
        );
        offboarder = new LendingTermOffboarding(address(core), address(guild), _QUORUM);
        auctionHouse = new AuctionHouse(
            address(core),
            address(guild),
            address(rlcm),
            address(credit)
        );
        term = new LendingTerm(
            address(core), /*_core*/
            address(guild), /*_guildToken*/
            address(auctionHouse), /*_auctionHouse*/
            address(rlcm), /*_creditMinter*/
            address(credit), /*_creditToken*/
            LendingTerm.LendingTermParams({
                collateralToken: address(collateral),
                maxDebtPerCollateralToken: _CREDIT_PER_COLLATERAL_TOKEN,
                interestRate: _INTEREST_RATE,
                callFee: _CALL_FEE,
                callPeriod: _CALL_PERIOD,
                hardCap: _HARDCAP,
                ltvBuffer: _LTV_BUFFER
            })
        );
        
        // permissions
        core.grantRole(CoreRoles.GOVERNOR, governor);
        core.grantRole(CoreRoles.CREDIT_MINTER, address(this));
        core.grantRole(CoreRoles.GUILD_MINTER, address(this));
        core.grantRole(CoreRoles.GAUGE_ADD, address(this));
        core.grantRole(CoreRoles.GAUGE_REMOVE, address(this));
        core.grantRole(CoreRoles.GAUGE_PARAMETERS, address(this));
        core.grantRole(CoreRoles.GUILD_GOVERNANCE_PARAMETERS, address(this));
        core.grantRole(CoreRoles.CREDIT_MINTER, address(rlcm));
        core.grantRole(CoreRoles.RATE_LIMITED_CREDIT_MINTER, address(term));
        core.grantRole(CoreRoles.GAUGE_PNL_NOTIFIER, address(term));
        core.grantRole(CoreRoles.GOVERNOR, address(offboarder));
        core.renounceRole(CoreRoles.GOVERNOR, address(this));

        // add gauge and vote for it
        guild.setMaxGauges(10);
        guild.addGauge(address(term));
        guild.mint(address(this), _HARDCAP * 2);
        guild.incrementGauge(address(term), uint112(_HARDCAP));
        vm.warp(block.timestamp + _CYCLE_LENGTH);

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
        bytes32[] memory loanIds = new bytes32[](0);
        vm.expectRevert("LendingTermOffboarding: quorum not met");
        offboarder.offboard(address(term), loanIds);

        // prepare (2)
        offboarder.supportOffboard(snapshotBlock, address(term));
        assertEq(offboarder.polls(snapshotBlock, address(term)), _QUORUM + 1);
        assertEq(offboarder.canOffboard(address(term)), true);

        // cannot offboard if all loans are not closed
        vm.expectRevert("LendingTermOffboarding: not all loans closed");
        offboarder.offboard(address(term), loanIds);

        // properly offboard a term
        loanIds = new bytes32[](1);
        loanIds[0] = aliceLoanId;
        offboarder.offboard(address(term), loanIds);
        assertEq(offboarder.canOffboard(address(term)), false);
    }
}
