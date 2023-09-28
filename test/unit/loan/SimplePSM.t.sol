// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Test} from "@forge-std/Test.sol";
import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {SimplePSM} from "@src/loan/SimplePSM.sol";
import {ProfitManager} from "@src/governance/ProfitManager.sol";
import {RateLimitedMinter} from "@src/rate-limits/RateLimitedMinter.sol";

contract SimplePSMUnitTest is Test {
    address private governor = address(1);
    address private guardian = address(2);

    Core private core;
    ProfitManager private profitManager;
    CreditToken credit;
    GuildToken guild;
    MockERC20 token;
    RateLimitedMinter rlcm;
    SimplePSM psm;

    function setUp() public {
        vm.warp(1679067867);
        vm.roll(16848497);
        core = new Core();

        profitManager = new ProfitManager(address(core));
        token = new MockERC20();
        token.setDecimals(6);
        credit = new CreditToken(address(core));
        guild = new GuildToken(address(core), address(profitManager), address(credit));
        rlcm = new RateLimitedMinter(
            address(core), /*_core*/
            address(credit), /*_token*/
            CoreRoles.RATE_LIMITED_CREDIT_MINTER, /*_role*/
            type(uint256).max, /*_maxRateLimitPerSecond*/
            type(uint128).max, /*_rateLimitPerSecond*/
            type(uint128).max /*_bufferCap*/
        );
        profitManager.initializeReferences(address(credit), address(guild));
        psm = new SimplePSM(
            address(core),
            address(profitManager),
            address(rlcm),
            address(credit),
            address(token)
        );

        // roles
        core.grantRole(CoreRoles.GOVERNOR, governor);
        core.grantRole(CoreRoles.GUARDIAN, guardian);
        core.grantRole(CoreRoles.CREDIT_MINTER, address(this));
        core.grantRole(CoreRoles.GUILD_MINTER, address(this));
        core.grantRole(CoreRoles.GAUGE_ADD, address(this));
        core.grantRole(CoreRoles.GAUGE_REMOVE, address(this));
        core.grantRole(CoreRoles.GAUGE_PARAMETERS, address(this));
        core.grantRole(CoreRoles.GAUGE_PNL_NOTIFIER, address(this));
        core.grantRole(CoreRoles.CREDIT_MINTER, address(rlcm));
        core.grantRole(CoreRoles.RATE_LIMITED_CREDIT_MINTER, address(psm));
        core.renounceRole(CoreRoles.GOVERNOR, address(this));

        // add gauge and vote for it
        guild.setMaxGauges(10);
        guild.addGauge(42, address(this));
        guild.mint(address(this), 1e18);
        guild.incrementGauge(address(this), 1e18);

        // labels
        vm.label(address(core), "core");
        vm.label(address(profitManager), "profitManager");
        vm.label(address(token), "token");
        vm.label(address(credit), "credit");
        vm.label(address(guild), "guild");
        vm.label(address(rlcm), "rlcm");
        vm.label(address(psm), "psm");
        vm.label(address(this), "test");
    }

    // constructor params & public state getters
    function testInitialState() public {
        assertEq(address(psm.core()), address(core));
        assertEq(psm.profitManager(), address(profitManager));
        assertEq(psm.rlcm(), address(rlcm));
        assertEq(psm.credit(), address(credit));
        assertEq(psm.token(), address(token));
        assertEq(psm.decimalCorrection(), 1e12);
    }

    // enforce that:
    // - decimal normalization occur properly betwheen input & output
    // - creditMultiplier is taken into account
    function testGetMintAmountOut() public {
        assertEq(psm.getMintAmountOut(0), 0);
        assertEq(psm.getMintAmountOut(123e6), 123e18);

        // update creditMultiplier
        credit.mint(address(this), 100e18);
        assertEq(profitManager.creditMultiplier(), 1e18);
        profitManager.notifyPnL(address(this), -50e18);
        assertEq(profitManager.creditMultiplier(), 0.5e18);

        assertEq(psm.getMintAmountOut(0), 0);
        assertEq(psm.getMintAmountOut(100_000_000), 2 * 100_000_000 * 1e12);
        assertEq(psm.getMintAmountOut(111), 222e12);
    }

    // enforce that:
    // - decimal normalization occur properly betwheen input & output
    // - creditMultiplier is taken into account
    // - rounding errors due o creditMultiplier are as expected
    function testGetRedeemAmountOut() public {
        assertEq(psm.getRedeemAmountOut(0), 0);
        assertEq(psm.getRedeemAmountOut(123e18), 123e6);

        // update creditMultiplier
        credit.mint(address(this), 100e18);
        assertEq(profitManager.creditMultiplier(), 1e18);
        profitManager.notifyPnL(address(this), -50e18);
        assertEq(profitManager.creditMultiplier(), 0.5e18);

        assertEq(psm.getRedeemAmountOut(0), 0);
        assertEq(psm.getRedeemAmountOut(2 * 100_000_000 * 1e12), 100_000_000);
        assertEq(psm.getRedeemAmountOut(111_111_111_111_111_111_111), 55_555_555);
        assertEq(psm.getRedeemAmountOut(12345), 0);
    }

    // enforce that:
    // - mint moves a number of tokens equal to getMintAmountOut() i/o
    // - redeem moves a number of token equal to getRedeemAmountOut() i/o
    // - rlcm buffer is depleted & replenished
    // - rounding errors are within 1 wei for a mint/redeem round-trip
    function testMintRedeem(uint256 input) public {
        uint256 mintIn = input % 1e15 + 1; // [1, 1_000_000_000e6]

        // update creditMultiplier
        // this ensures that some fuzz entries will result in uneven divisions
        // and will create a min/redeem round-trip error of 1 wei.
        credit.mint(address(this), 100e18);
        assertEq(profitManager.creditMultiplier(), 1e18);
        profitManager.notifyPnL(address(this), -int256(input % 90e18 + 1)); // [0-90%] loss
        assertLt(profitManager.creditMultiplier(), 1.0e18 + 1);
        assertGt(profitManager.creditMultiplier(), 0.1e18 - 1);
        credit.burn(100e18);

        assertEq(rlcm.buffer(), type(uint128).max);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(credit.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(psm)), 0);
        assertEq(credit.balanceOf(address(psm)), 0);

        // mint
        token.mint(address(this), mintIn);
        token.approve(address(psm), mintIn);
        psm.mint(address(this), mintIn);

        uint256 mintOut = psm.getMintAmountOut(mintIn);
        assertEq(rlcm.buffer(), type(uint128).max - mintOut);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(credit.balanceOf(address(this)), mintOut);
        assertEq(token.balanceOf(address(psm)), mintIn);
        assertEq(credit.balanceOf(address(psm)), 0);

        // redeem
        credit.approve(address(psm), mintOut);
        psm.redeem(address(this), mintOut);

        uint256 redeemOut = psm.getRedeemAmountOut(mintOut);
        assertEq(rlcm.buffer(), type(uint128).max);
        assertEq(token.balanceOf(address(this)), redeemOut);
        assertEq(credit.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(psm)), mintIn - redeemOut);
        assertEq(credit.balanceOf(address(psm)), 0);

        // max error of 1 wei for doing a round trip
        assertLt(mintIn - redeemOut, 2);
    }
}
