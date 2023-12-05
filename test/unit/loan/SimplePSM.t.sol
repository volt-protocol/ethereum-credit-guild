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
    SimplePSM psm;

    function setUp() public {
        vm.warp(1679067867);
        vm.roll(16848497);
        core = new Core();

        profitManager = new ProfitManager(address(core));
        token = new MockERC20();
        token.setDecimals(6);
        credit = new CreditToken(address(core), "name", "symbol");
        guild = new GuildToken(address(core), address(profitManager));
        psm = new SimplePSM(
            address(core),
            address(profitManager),
            address(credit),
            address(token)
        );
        profitManager.initializeReferences(address(credit), address(guild), address(psm));

        // roles
        core.grantRole(CoreRoles.GOVERNOR, governor);
        core.grantRole(CoreRoles.GUARDIAN, guardian);
        core.grantRole(CoreRoles.CREDIT_MINTER, address(this));
        core.grantRole(CoreRoles.GUILD_MINTER, address(this));
        core.grantRole(CoreRoles.GAUGE_ADD, address(this));
        core.grantRole(CoreRoles.GAUGE_REMOVE, address(this));
        core.grantRole(CoreRoles.GAUGE_PARAMETERS, address(this));
        core.grantRole(CoreRoles.GAUGE_PNL_NOTIFIER, address(this));
        core.grantRole(CoreRoles.CREDIT_MINTER, address(psm));
        core.grantRole(CoreRoles.CREDIT_REBASE_PARAMETERS, address(psm));
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
        vm.label(address(psm), "psm");
        vm.label(address(this), "test");
    }

    // constructor params & public state getters
    function testInitialState() public {
        assertEq(address(psm.core()), address(core));
        assertEq(psm.profitManager(), address(profitManager));
        assertEq(psm.credit(), address(credit));
        assertEq(psm.pegToken(), address(token));
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

        assertEq(token.balanceOf(address(this)), 0);
        assertEq(credit.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(psm)), 0);
        assertEq(credit.balanceOf(address(psm)), 0);
        assertEq(psm.pegTokenBalance(), 0);

        // mint
        token.mint(address(this), mintIn);
        token.approve(address(psm), mintIn);
        psm.mint(address(this), mintIn);

        uint256 mintOut = psm.getMintAmountOut(mintIn);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(credit.balanceOf(address(this)), mintOut);
        assertEq(token.balanceOf(address(psm)), mintIn);
        assertEq(credit.balanceOf(address(psm)), 0);
        assertEq(psm.pegTokenBalance(), mintIn);

        // redeem
        credit.approve(address(psm), mintOut);
        psm.redeem(address(this), mintOut);

        uint256 redeemOut = psm.getRedeemAmountOut(mintOut);
        assertEq(token.balanceOf(address(this)), redeemOut);
        assertEq(credit.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(psm)), mintIn - redeemOut);
        assertEq(credit.balanceOf(address(psm)), 0);
        assertEq(psm.pegTokenBalance(), mintIn - redeemOut);

        // max error of 1 wei for doing a round trip
        assertLt(mintIn - redeemOut, 2);
    }

    // test psm donations to not interefere with accounting
    function testDonationResistanceRedeemableCredit() public {
        assertEq(psm.pegTokenBalance(), 0);
        assertEq(psm.redeemableCredit(), 0);
        assertEq(token.balanceOf(address(psm)), 0);

        token.mint(address(psm), 100e6);

        assertEq(psm.pegTokenBalance(), 0);
        assertEq(psm.redeemableCredit(), 0);
        assertEq(token.balanceOf(address(psm)), 100e6);
        token.mint(address(this), 50e6);
        token.approve(address(psm), 50e6);
        psm.mint(address(this), 50e6);

        assertEq(psm.pegTokenBalance(), 50e6);
        assertEq(psm.redeemableCredit(), 50e18);
        assertEq(token.balanceOf(address(psm)), 150e6);

        vm.prank(address(psm));
        token.burn(100e6);

        assertEq(psm.pegTokenBalance(), 50e6);
        assertEq(psm.redeemableCredit(), 50e18);
        assertEq(token.balanceOf(address(psm)), 50e6);

        assertEq(profitManager.creditMultiplier(), 1e18);
        profitManager.notifyPnL(address(this), -int256(25e18));
        assertEq(profitManager.creditMultiplier(), 0.5e18);

        assertEq(psm.pegTokenBalance(), 50e6);
        assertEq(psm.redeemableCredit(), 100e18);
        assertEq(token.balanceOf(address(psm)), 50e6);
    }

    // test governor setter for redemptionsPaused
    function testPauseRedemptions() public {
        assertEq(psm.redemptionsPaused(), false);

        vm.expectRevert("UNAUTHORIZED");
        psm.setRedemptionsPaused(true);

        vm.prank(governor);
        psm.setRedemptionsPaused(true);
        assertEq(psm.redemptionsPaused(), true);

        // mint
        token.mint(address(this), 100e18);
        token.approve(address(psm), 100e18);
        psm.mint(address(this), 100e18);

        // cannot redeem (paused)
        vm.expectRevert("SimplePSM: redemptions paused");
        psm.redeem(address(this), 100e18);
    }

    // test mintAndEnterRebase
    function testMintAndEnterRebase() public {
        uint256 mintIn = 20_000e6;

        assertEq(token.balanceOf(address(this)), 0);
        assertEq(credit.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(psm)), 0);
        assertEq(credit.balanceOf(address(psm)), 0);
        assertEq(credit.isRebasing(address(this)), false);

        // mint
        token.mint(address(this), mintIn);
        token.approve(address(psm), mintIn);
        psm.mintAndEnterRebase(mintIn);

        uint256 mintOut = 20_000e18;
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(credit.balanceOf(address(this)), mintOut);
        assertEq(token.balanceOf(address(psm)), mintIn);
        assertEq(credit.balanceOf(address(psm)), 0);
        assertEq(credit.isRebasing(address(this)), true);

        // cannot enter mintAndEnterRebase twice
        token.mint(address(this), mintIn);
        token.approve(address(psm), mintIn);
        vm.expectRevert("SimplePSM: already rebasing");
        psm.mintAndEnterRebase(mintIn);
    }
}
