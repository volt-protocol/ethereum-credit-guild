// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Test} from "@forge-std/Test.sol";
import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {ProfitManager} from "@src/governance/ProfitManager.sol";
import {MockLendingTerm} from "@test/mock/MockLendingTerm.sol";
import {RateLimitedMinter} from "@src/rate-limits/RateLimitedMinter.sol";
import {SurplusGuildMinter} from "@src/loan/SurplusGuildMinter.sol";

contract SurplusGuildMinterUnitTest is Test {
    address private governor = address(1);
    address private guardian = address(2);
    address private term;
    Core private core;
    ProfitManager private profitManager;
    CreditToken credit;
    GuildToken guild;
    RateLimitedMinter rlgm;
    SurplusGuildMinter sgm;

    // GuildMinter params
    uint256 constant MINT_RATIO = 2e18;
    uint256 constant REWARD_RATIO = 5e18;

    function setUp() public {
        vm.warp(1679067867);
        vm.roll(16848497);
        core = new Core();

        profitManager = new ProfitManager(address(core));
        credit = new CreditToken(address(core), "name", "symbol");
        guild = new GuildToken(address(core), address(profitManager));
        rlgm = new RateLimitedMinter(
            address(core), /*_core*/
            address(guild), /*_token*/
            CoreRoles.RATE_LIMITED_GUILD_MINTER, /*_role*/
            type(uint256).max, /*_maxRateLimitPerSecond*/
            type(uint128).max, /*_rateLimitPerSecond*/
            type(uint128).max /*_bufferCap*/
        );
        sgm = new SurplusGuildMinter(
            address(core),
            address(profitManager),
            address(credit),
            address(guild),
            address(rlgm),
            MINT_RATIO,
            REWARD_RATIO
        );
        profitManager.initializeReferences(address(credit), address(guild), address(0));
        term = address(new MockLendingTerm(address(core)));

        // roles
        core.grantRole(CoreRoles.GOVERNOR, governor);
        core.grantRole(CoreRoles.GUARDIAN, guardian);
        core.grantRole(CoreRoles.CREDIT_MINTER, address(this));
        core.grantRole(CoreRoles.GUILD_MINTER, address(this));
        core.grantRole(CoreRoles.GAUGE_ADD, address(this));
        core.grantRole(CoreRoles.GAUGE_REMOVE, address(this));
        core.grantRole(CoreRoles.GAUGE_PARAMETERS, address(this));
        core.grantRole(CoreRoles.GUILD_MINTER, address(rlgm));
        core.grantRole(CoreRoles.RATE_LIMITED_GUILD_MINTER, address(sgm));
        core.grantRole(CoreRoles.GUILD_SURPLUS_BUFFER_WITHDRAW, address(sgm));
        core.grantRole(CoreRoles.GAUGE_PNL_NOTIFIER, address(this));
        core.renounceRole(CoreRoles.GOVERNOR, address(this));

        // add gauge and vote for it
        guild.setMaxGauges(10);
        guild.addGauge(1, term);
        guild.mint(address(this), 50e18);
        guild.incrementGauge(term, uint112(50e18));

        // labels
        vm.label(address(core), "core");
        vm.label(address(profitManager), "profitManager");
        vm.label(address(credit), "credit");
        vm.label(address(guild), "guild");
        vm.label(address(rlgm), "rlcgm");
        vm.label(address(sgm), "sgm");
        vm.label(term, "term");
    }

    // test contract view functions after deployment
    function testInitialState() public {
        assertEq(address(sgm.core()), address(core));
        assertEq(address(sgm.credit()), address(credit));
        assertEq(address(sgm.guild()), address(guild));
        assertEq(address(sgm.rlgm()), address(rlgm));
        assertEq(sgm.mintRatio(), MINT_RATIO);
        assertEq(sgm.rewardRatio(), REWARD_RATIO);
    }

    // test stake function
    function testStake() public {
        // initial state
        assertEq(profitManager.termSurplusBuffer(term), 0);
        assertEq(guild.balanceOf(address(sgm)), 0);
        assertEq(guild.getGaugeWeight(term), 50e18);

        // cannot stake dust amounts
        uint256 minStake = sgm.MIN_STAKE();
        vm.expectRevert("SurplusGuildMinter: min stake");
        sgm.stake(term, minStake - 1);

        // stake 100 CREDIT
        credit.mint(address(this), 100e18);
        credit.approve(address(sgm), 100e18);
        sgm.stake(term, 100e18);
        
        // check after-stake state
        assertEq(credit.balanceOf(address(this)), 0);
        assertEq(profitManager.termSurplusBuffer(term), 100e18);
        assertEq(guild.balanceOf(address(sgm)), 200e18);
        assertEq(guild.getGaugeWeight(term), 250e18);
        SurplusGuildMinter.UserStake memory stake = sgm.getUserStake(address(this), term);
        assertEq(uint256(stake.stakeTime), block.timestamp);
        assertEq(stake.lastGaugeLoss, 0);
        assertEq(stake.profitIndex, 0);
        assertEq(stake.credit, 100e18);
        assertEq(stake.guild, 200e18);

        // stake 150 CREDIT
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 13);
        credit.mint(address(this), 150e18);
        credit.approve(address(sgm), 150e18);
        sgm.stake(term, 150e18);
        
        // check after-stake state
        assertEq(credit.balanceOf(address(this)), 0);
        assertEq(profitManager.termSurplusBuffer(term), 250e18);
        assertEq(guild.balanceOf(address(sgm)), 500e18);
        assertEq(guild.getGaugeWeight(term), 550e18);
        stake = sgm.getUserStake(address(this), term);
        assertEq(uint256(stake.stakeTime), block.timestamp);
        assertEq(stake.lastGaugeLoss, 0);
        assertEq(stake.profitIndex, 0);
        assertEq(stake.credit, 250e18);
        assertEq(stake.guild, 500e18);
    }

    // test unstake function without loss & with interests
    function testUnstakeWithoutLoss() public {
        // setup
        credit.mint(address(this), 150e18);
        credit.approve(address(sgm), 150e18);
        sgm.stake(term, 150e18);
        assertEq(credit.balanceOf(address(this)), 0);
        assertEq(profitManager.termSurplusBuffer(term), 150e18);
        assertEq(guild.balanceOf(address(sgm)), 300e18);
        assertEq(guild.getGaugeWeight(term), 350e18);
        assertEq(sgm.getUserStake(address(this), term).credit, 150e18);

        // the guild token earn interests
        vm.prank(governor);
        profitManager.setProfitSharingConfig(
            0.5e18, // surplusBufferSplit
            0, // creditSplit
            0.5e18, // guildSplit
            0, // otherSplit
            address(0) // otherRecipient
        );
        credit.mint(address(profitManager), 35e18);
        profitManager.notifyPnL(term, 35e18);
        assertEq(profitManager.surplusBuffer(), 17.5e18);
        assertEq(profitManager.termSurplusBuffer(term), 150e18);
        (,, uint256 rewardsThis) = profitManager.getPendingRewards(address(this));
        (,, uint256 rewardsSgm) = profitManager.getPendingRewards(address(sgm));
        assertEq(rewardsThis, 2.5e18);
        assertEq(rewardsSgm, 15e18);

        // next block
        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);

        // unstake half (sgm)
        sgm.unstake(term, 75e18);
        assertEq(credit.balanceOf(address(this)), 75e18 + rewardsSgm);
        assertEq(guild.balanceOf(address(this)), rewardsSgm * REWARD_RATIO / 1e18 + 50e18);
        assertEq(credit.balanceOf(address(sgm)), 0);
        assertEq(guild.balanceOf(address(sgm)), 150e18);
        assertEq(profitManager.surplusBuffer(), 17.5e18);
        assertEq(profitManager.termSurplusBuffer(term), 75e18);
        assertEq(guild.getGaugeWeight(term), 50e18 + 150e18);
        assertEq(sgm.getUserStake(address(this), term).credit, 75e18);

        // cannot unstake below staked amount
        vm.expectRevert("SurplusGuildMinter: invalid amount");
        sgm.unstake(term, 80e18);

        // cannot unstake with a remaining credit amount below MIN_STAKE
        vm.expectRevert("SurplusGuildMinter: remaining stake below min");
        sgm.unstake(term, 74.5e18);

        // unstake 2nd half (sgm)
        sgm.unstake(term, 75e18);
        assertEq(credit.balanceOf(address(this)), 150e18 + rewardsSgm);
        assertEq(guild.balanceOf(address(this)), rewardsSgm * REWARD_RATIO / 1e18 + 50e18);
        assertEq(credit.balanceOf(address(sgm)), 0);
        assertEq(guild.balanceOf(address(sgm)), 0);
        assertEq(profitManager.surplusBuffer(), 17.5e18);
        assertEq(profitManager.termSurplusBuffer(term), 0);
        assertEq(guild.getGaugeWeight(term), 50e18);
        assertEq(sgm.getUserStake(address(this), term).stakeTime, 0); // no stake anymore

        // cannot unstake if nothing staked
        vm.expectRevert("SurplusGuildMinter: invalid amount");
        sgm.unstake(term, 1);
    }

    // test unstake function with loss & interests
    function testUnstakeWithLoss() public {
        // setup
        credit.mint(address(this), 150e18);
        credit.approve(address(sgm), 150e18);
        sgm.stake(term, 150e18);
        assertEq(credit.balanceOf(address(this)), 0);
        assertEq(profitManager.surplusBuffer(), 0);
        assertEq(profitManager.termSurplusBuffer(term), 150e18);
        assertEq(guild.balanceOf(address(sgm)), 300e18);
        assertEq(guild.getGaugeWeight(term), 350e18);
        assertEq(sgm.getUserStake(address(this), term).credit, 150e18);

        // the guild token earn interests
        vm.prank(governor);
        profitManager.setProfitSharingConfig(
            0.5e18, // surplusBufferSplit
            0, // creditSplit
            0.5e18, // guildSplit
            0, // otherSplit
            address(0) // otherRecipient
        );
        credit.mint(address(profitManager), 35e18);
        profitManager.notifyPnL(term, 35e18);
        assertEq(profitManager.surplusBuffer(), 17.5e18);
        assertEq(profitManager.termSurplusBuffer(term), 150e18);
        (,, uint256 rewardsThis) = profitManager.getPendingRewards(address(this));
        (,, uint256 rewardsSgm) = profitManager.getPendingRewards(address(sgm));
        assertEq(rewardsThis, 2.5e18);
        assertEq(rewardsSgm, 15e18);

        // next block
        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);

        // loss in gauge
        profitManager.notifyPnL(term, -27.5e18);
        assertEq(profitManager.surplusBuffer(), 17.5e18 + 150e18 - 27.5e18); // 140e18
        assertEq(profitManager.termSurplusBuffer(term), 0);

        // cannot stake if there was just a loss
        vm.expectRevert("SurplusGuildMinter: loss in block");
        sgm.stake(term, 123);

        // unstake (sgm)
        sgm.unstake(term, 123);
        assertEq(credit.balanceOf(address(this)), rewardsSgm); // lost 150 credit principal but earn the 15 credit of dividends
        assertEq(guild.balanceOf(address(this)), 50e18 + 0); // no guild reward because position is slashed
        assertEq(credit.balanceOf(address(sgm)), 0); // did not withdraw from surplus buffer
        assertEq(guild.balanceOf(address(sgm)), 300e18); // still not slashed
        assertEq(guild.getGaugeWeight(term), 350e18); // did not decrementWeight
        assertEq(sgm.getUserStake(address(this), term).credit, 0); // position slashed

        // slash sgm
        guild.applyGaugeLoss(term, address(sgm));
        assertEq(guild.balanceOf(address(sgm)), 0); // slashed
        assertEq(guild.getGaugeWeight(term), 50e18); // weight decremented
    }

    // test pausability
    function testPausability() public {
        vm.prank(guardian);
        sgm.pause();

        vm.expectRevert("Pausable: paused");
        sgm.stake(term, 100e18);
    }

    // test governor setter for mint ratio
    function testSetMintRatio() public {
        assertEq(sgm.mintRatio(), MINT_RATIO);

        vm.expectRevert("UNAUTHORIZED");
        sgm.setMintRatio(3e18);

        vm.prank(governor);
        sgm.setMintRatio(3e18);
        assertEq(sgm.mintRatio(), 3e18);
    }

    // test governor setter for mint ratio
    function testSetRewardRatio() public {
        assertEq(sgm.rewardRatio(), REWARD_RATIO);

        vm.expectRevert("UNAUTHORIZED");
        sgm.setRewardRatio(3e18);

        vm.prank(governor);
        sgm.setRewardRatio(3e18);
        assertEq(sgm.rewardRatio(), 3e18);
    }

    // test with multiple users, some gauges with losses and some not
    function testMultipleUsers() public {
        // add a 2 terms with equal weight
        address term1 = address(new MockLendingTerm(address(core)));
        address term2 = address(new MockLendingTerm(address(core)));
        guild.addGauge(1, term1);
        guild.addGauge(1, term2);
        guild.mint(address(this), 100e18);
        guild.incrementGauge(term1, 50e18);
        guild.incrementGauge(term2, 50e18);

        address user1 = address(19028109281092);
        address user2 = address(88120812019200);

        // setup 2 users with CREDIT and each voting through the sgm for
        // half each gauge
        credit.mint(user1, 100e18);
        credit.mint(user2, 200e18);
        vm.startPrank(user1);
        credit.approve(address(sgm), 100e18);
        sgm.stake(term1, 50e18);
        sgm.stake(term2, 50e18);
        vm.stopPrank();
        vm.startPrank(user2);
        credit.approve(address(sgm), 200e18);
        sgm.stake(term1, 100e18);
        sgm.stake(term2, 100e18);
        vm.stopPrank();

        assertEq(profitManager.surplusBuffer(), 0);
        assertEq(profitManager.termSurplusBuffer(term1), 150e18);
        assertEq(profitManager.termSurplusBuffer(term2), 150e18);

        // both gauges earn interests
        vm.prank(governor);
        profitManager.setProfitSharingConfig(
            0.5e18, // surplusBufferSplit
            0, // creditSplit
            0.5e18, // guildSplit
            0, // otherSplit
            address(0) // otherRecipient
        );
        credit.mint(address(profitManager), 420e18);
        profitManager.notifyPnL(term1, 140e18);
        profitManager.notifyPnL(term2, 280e18);

        assertEq(profitManager.surplusBuffer(), 210e18);
        assertEq(profitManager.termSurplusBuffer(term1), 150e18);
        assertEq(profitManager.termSurplusBuffer(term2), 150e18);

        // next block
        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);

        // loss in term1 + slash sgm
        profitManager.notifyPnL(term1, -20e18);
        assertEq(guild.balanceOf(address(sgm)), 600e18);
        guild.applyGaugeLoss(term1, address(sgm));
        assertEq(guild.balanceOf(address(sgm)), 300e18);
        assertEq(profitManager.surplusBuffer(), 210e18 + 150e18 - 20e18);
        assertEq(profitManager.termSurplusBuffer(term1), 0);
        assertEq(profitManager.termSurplusBuffer(term2), 150e18);

        // gauge1 has 50 (this) + 50*2 (sgm user1) + 100*2 (sgm user2) = 350 weight
        // gauge2 has 50 (this) + 50*2 (sgm user1) + 100*2 (sgm user2) = 350 weight
        // gauge1 earned 140 (70 to surplus buffer, 70 to guild)
        // gauge1 dividends are 50/350*70 = 10 for this
        // gauge1 dividends are 100/350*70 = 20 for user1
        // gauge1 dividends are 200/350*70 = 40 for user2
        // gauge2 earned 280 (140 to surplus buffer, 140 to guild)
        // gauge2 dividends are 50/350*140 = 20 for this
        // gauge2 dividends are 100/350*140 = 40 for user1
        // gauge2 dividends are 200/350*140 = 80 for user2

        // user1 unstake
        // on term1, getRewards applied the unstake because position has been slashed
        sgm.getRewards(user1, term1);
        assertEq(credit.balanceOf(user1), 20e18);
        assertEq(guild.balanceOf(user1), 0);
        assertEq(sgm.getUserStake(user1, term1).stakeTime, 0);
        // on term2, regular unstake
        vm.startPrank(user1);
        sgm.unstake(term2, 50e18);
        assertEq(credit.balanceOf(user1), 20e18 + 40e18 + 50e18);
        assertEq(guild.balanceOf(user1), 0 + 200e18); // 40 * reward ratio
        assertEq(sgm.getUserStake(user1, term2).stakeTime, 0); // stake position completely cleaned
        vm.stopPrank();

        assertEq(profitManager.surplusBuffer(), 210e18 + 150e18 - 20e18);
        assertEq(profitManager.termSurplusBuffer(term1), 0);
        assertEq(profitManager.termSurplusBuffer(term2), 100e18);

        // policy change, reward ratio goes from 5 to 10
        vm.prank(governor);
        sgm.setRewardRatio(10e18);

        // user2 unstake
        vm.startPrank(user2);
        sgm.unstake(term1, 100e18);
        assertEq(credit.balanceOf(user2), 40e18); // lost principal, only got 40 from dividends
        assertEq(guild.balanceOf(user2), 0);
        sgm.unstake(term2, 100e18);
        assertEq(credit.balanceOf(user2), 40e18 + 80e18 + 100e18); // 80 dividends + 100 staked
        assertEq(guild.balanceOf(user2), 0 + 800e18); // 10 reward ratio * 80 credit dividends
        vm.stopPrank();

        assertEq(profitManager.surplusBuffer(), 210e18 + 150e18 - 20e18);
        assertEq(profitManager.termSurplusBuffer(term1), 0);
        assertEq(profitManager.termSurplusBuffer(term2), 0);
    }

    // test updateMintRatio (up & down)
    function testUpdateMintRatio() public {
        // setup
        credit.mint(address(this), 150e18);
        credit.approve(address(sgm), 150e18);
        sgm.stake(term, 150e18);
        assertEq(profitManager.termSurplusBuffer(term), 150e18);
        assertEq(guild.balanceOf(address(sgm)), 300e18);
        assertEq(guild.getGaugeWeight(term), 50e18 + 300e18);

        // adjust down
        vm.prank(governor);
        sgm.setMintRatio(MINT_RATIO / 2); // 1:1

        sgm.updateMintRatio(address(this), term);

        assertEq(profitManager.termSurplusBuffer(term), 150e18);
        assertEq(guild.balanceOf(address(sgm)), 150e18);
        assertEq(guild.getGaugeWeight(term), 50e18 + 150e18);

        // adjust up
        vm.prank(governor);
        sgm.setMintRatio(MINT_RATIO * 2); // 1:4

        sgm.updateMintRatio(address(this), term);

        assertEq(profitManager.termSurplusBuffer(term), 150e18);
        assertEq(guild.balanceOf(address(sgm)), 600e18);
        assertEq(guild.getGaugeWeight(term), 50e18 + 600e18);
    }
}
