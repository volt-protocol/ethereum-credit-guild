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
import {ProfitManager} from "@src/governance/ProfitManager.sol";
import {RateLimitedMinter} from "@src/rate-limits/RateLimitedMinter.sol";
import {LendingTermAdjustable} from "@src/loan/LendingTermAdjustable.sol";

contract LendingTermAdjustableUnitTest is ECGTest {
    address private governor = address(1);
    address private guardian = address(2);
    Core private core;
    ProfitManager public profitManager;
    CreditToken credit;
    GuildToken guild;
    MockERC20 collateral;
    SimplePSM private psm;
    RateLimitedMinter rlcm;
    AuctionHouse auctionHouse;
    LendingTermAdjustable term;

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
        term = LendingTermAdjustable(Clones.clone(address(new LendingTermAdjustable())));
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
        vm.label(address(this), "test");
    }

    // test setter for interestRate
    function testSetInterestRate() public {
        assertEq(term.getParameters().interestRate, _INTEREST_RATE);

        vm.prank(governor);
        term.setInterestRate(_INTEREST_RATE * 2);

        assertEq(term.getParameters().interestRate, _INTEREST_RATE * 2);

        vm.expectRevert("UNAUTHORIZED");
        term.setInterestRate(_INTEREST_RATE);
    }

    // test setter for maxDebtPerCollateralToken
    function testSetMaxDebtPerCollateralToken() public {
        assertEq(term.getParameters().maxDebtPerCollateralToken, _CREDIT_PER_COLLATERAL_TOKEN);

        vm.prank(governor);
        term.setMaxDebtPerCollateralToken(_CREDIT_PER_COLLATERAL_TOKEN * 2);

        assertEq(term.getParameters().maxDebtPerCollateralToken, _CREDIT_PER_COLLATERAL_TOKEN * 2);

        vm.expectRevert("UNAUTHORIZED");
        term.setMaxDebtPerCollateralToken(_CREDIT_PER_COLLATERAL_TOKEN);
    }

    // get loan debt when interest rate changes over time
    function testGetLoanDebt() public {
        // prepare
        uint256 period = term.YEAR();
        collateral.mint(address(this), 1 ether * 2);
        collateral.approve(address(term), 1 ether * 2);

        // borrow
        bytes32 loan1 = term.borrow(1_000 ether, 1 ether);
        assertEq(term.getLoanDebt(loan1), 1_000 ether);

        // 10% apr * full period -> x1.10
        vm.warp(block.timestamp + period);
        assertEq(term.getLoanDebt(loan1), 1_100 ether);

        // set interest rate to 100% APR
        vm.prank(governor);
        term.setInterestRate(1e18);

        // 100% APR * full period -> x2.00
        vm.warp(block.timestamp + period);
        assertEq(term.getLoanDebt(loan1), 2_200 ether);

        // set interest rate to 50% APR
        vm.prank(governor);
        term.setInterestRate(0.5e18);

        // 50% APR * half a period -> x1.25
        vm.warp(block.timestamp + period / 2);
        assertEq(term.getLoanDebt(loan1), 2_750 ether);

        // borrow 2
        bytes32 loan2 = term.borrow(1_000 ether, 1 ether);
        assertEq(term.getLoanDebt(loan2), 1_000 ether);

        // 50% APR * half a period -> x1.25
        vm.warp(block.timestamp + period / 2);
        assertEq(term.getLoanDebt(loan1), 3_437.5 ether);
        assertEq(term.getLoanDebt(loan2), 1_250 ether);
    }

    // setting maxDebtPerCollateralToken can make loans callable
    function testLoansBecomeCallable() public {
        // prepare
        uint256 period = term.YEAR();
        collateral.mint(address(this), 1 ether * 2);
        collateral.approve(address(term), 1 ether * 2);

        // borrow
        bytes32 loan1 = term.borrow(1_000 ether, 1 ether);
        vm.expectRevert("LendingTerm: cannot call");
        term.call(loan1);

        // after some time, set maxDebtPerCollateralToken to 1000
        vm.warp(block.timestamp + 123456);
        vm.prank(governor);
        term.setMaxDebtPerCollateralToken(1000 ether);

        // now loan can be called
        term.call(loan1);
        assertEq(term.getLoan(loan1).callTime, block.timestamp);
    }
}
