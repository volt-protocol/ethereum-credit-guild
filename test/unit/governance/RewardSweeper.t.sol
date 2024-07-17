// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {ECGTest} from "@test/ECGTest.sol";
import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {SimplePSM} from "@src/loan/SimplePSM.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {AuctionHouse} from "@src/loan/AuctionHouse.sol";
import {RewardSweeper} from "@src/governance/RewardSweeper.sol";
import {ProfitManager} from "@src/governance/ProfitManager.sol";
import {RateLimitedMinter} from "@src/rate-limits/RateLimitedMinter.sol";

contract RewardSweeperUnitTest is ECGTest {
    address private governor = address(1);
    address private guardian = address(2);
    address private msig = address(789546);
    Core private core;
    ProfitManager public profitManager;
    CreditToken credit;
    GuildToken guild;
    MockERC20 collateral;
    MockERC20 reward;
    SimplePSM private psm;
    RateLimitedMinter rlcm;
    AuctionHouse auctionHouse;
    LendingTerm term;
    RewardSweeper sweeper;

    // LendingTerm params
    uint256 constant _CREDIT_PER_COLLATERAL_TOKEN = 2000e18; // 2000, same decimals
    uint256 constant _INTEREST_RATE = 0.10e18; // 10% APR
    uint256 constant _MAX_DELAY_BETWEEN_PARTIAL_REPAY = 31557600; // 1 years
    uint256 constant _MIN_PARTIAL_REPAY_PERCENT = 0.2e18; // 20%
    uint256 constant _HARDCAP = 20_000_000e18;

    uint256 public issuance = 0;

    function setUp() public {
        vm.warp(1679067867);
        vm.roll(16848497);
        core = new Core();

        profitManager = new ProfitManager(address(core));
        collateral = new MockERC20();
        reward = new MockERC20();
        credit = new CreditToken(address(core), "name", "symbol");
        guild = new GuildToken(address(core));
        rlcm = new RateLimitedMinter(
            address(core) /*_core*/,
            address(credit) /*_token*/,
            CoreRoles.RATE_LIMITED_CREDIT_MINTER /*_role*/,
            type(uint256).max /*_maxRateLimitPerSecond*/,
            type(uint128).max /*_rateLimitPerSecond*/,
            type(uint128).max /*_bufferCap*/
        );
        auctionHouse = new AuctionHouse(address(core), 650, 1800, 0);
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
            abi.encode(
                LendingTerm.LendingTermParams({
                    collateralToken: address(collateral),
                    maxDebtPerCollateralToken: _CREDIT_PER_COLLATERAL_TOKEN,
                    interestRate: _INTEREST_RATE,
                    maxDelayBetweenPartialRepay: _MAX_DELAY_BETWEEN_PARTIAL_REPAY,
                    minPartialRepayPercent: _MIN_PARTIAL_REPAY_PERCENT,
                    openingFee: 0,
                    hardCap: _HARDCAP
                })
            )
        );
        psm = new SimplePSM(
            address(core),
            address(profitManager),
            address(credit),
            address(collateral)
        );
        profitManager.initializeReferences(address(credit), address(guild));

        sweeper = new RewardSweeper(address(core), address(guild), msig);

        // roles
        core.grantRole(CoreRoles.GOVERNOR, governor);
        core.grantRole(CoreRoles.GUARDIAN, guardian);
        core.grantRole(CoreRoles.CREDIT_MINTER, address(this));
        core.grantRole(CoreRoles.GUILD_MINTER, address(this));
        core.grantRole(CoreRoles.GAUGE_ADD, address(this));
        core.grantRole(CoreRoles.GAUGE_REMOVE, address(this));
        core.grantRole(CoreRoles.GAUGE_PARAMETERS, address(this));
        core.grantRole(CoreRoles.CREDIT_MINTER, address(rlcm));
        core.grantRole(CoreRoles.RATE_LIMITED_CREDIT_MINTER, address(term));
        core.grantRole(CoreRoles.GAUGE_PNL_NOTIFIER, address(term));
        core.grantRole(CoreRoles.CREDIT_BURNER, address(term));
        core.grantRole(CoreRoles.CREDIT_BURNER, address(profitManager));
        core.grantRole(CoreRoles.CREDIT_BURNER, address(psm));
        core.grantRole(CoreRoles.CREDIT_BURNER, address(this));
        core.grantRole(CoreRoles.GOVERNOR, address(sweeper));
        core.renounceRole(CoreRoles.GOVERNOR, address(this));

        // add gauge and vote for it
        guild.setMaxGauges(10);
        guild.addGauge(1, address(term));
        guild.mint(address(this), _HARDCAP * 2);
        guild.incrementGauge(address(term), _HARDCAP);

        // labels
        vm.label(address(core), "core");
        vm.label(address(profitManager), "profitManager");
        vm.label(address(collateral), "collateral");
        vm.label(address(credit), "credit");
        vm.label(address(guild), "guild");
        vm.label(address(rlcm), "rlcm");
        vm.label(address(auctionHouse), "auctionHouse");
        vm.label(address(term), "term");
        vm.label(address(sweeper), "sweeper");
        vm.label(address(this), "test");
    }

    function testInitialState() public {
        assertEq(address(sweeper.core()), address(core));
        assertEq(sweeper.receiver(), msig);
    }

    function testSetReceiver() public {
        assertEq(sweeper.receiver(), msig);

        vm.prank(governor);
        sweeper.setReceiver(address(123456));

        assertEq(sweeper.receiver(), address(123456));

        vm.expectRevert("UNAUTHORIZED");
        sweeper.setReceiver(msig);
    }

    function testOnlyReceiverCanSweep() public {
        vm.prank(sweeper.receiver());
        sweeper.sweep(address(term), address(reward)); // ok

        vm.expectRevert("RewardSweeper: invalid sender");
        sweeper.sweep(address(term), address(reward)); // nok, no prank
    }

    function testCanOnlySweepGauges() public {
        vm.startPrank(sweeper.receiver());
        sweeper.sweep(address(term), address(reward)); // ok

        vm.expectRevert("RewardSweeper: invalid gauge");
        sweeper.sweep(address(456789), address(reward)); // nok, not a live term
    }

    function testCannotSweepCollateralToken() public {
        vm.startPrank(sweeper.receiver());
        sweeper.sweep(address(term), address(reward)); // ok

        vm.expectRevert("RewardSweeper: invalid token");
        sweeper.sweep(address(term), address(collateral)); // nok, invalid token
    }

    function testSweep() public {
        uint256 rewardAmount = 123456;
        reward.mint(address(term), rewardAmount);

        assertEq(reward.balanceOf(msig), 0);
        assertEq(reward.balanceOf(address(term)), rewardAmount);

        vm.prank(msig);
        sweeper.sweep(address(term), address(reward));

        assertEq(reward.balanceOf(msig), rewardAmount);
        assertEq(reward.balanceOf(address(term)), 0);
    }

    function testDeactivate() public {
        vm.expectRevert("RewardSweeper: invalid sender");
        sweeper.deactivate(); // nok, no prank

        vm.prank(sweeper.receiver());
        sweeper.deactivate();

        assertEq(core.hasRole(CoreRoles.GOVERNOR, address(sweeper)), false);
    }
}
