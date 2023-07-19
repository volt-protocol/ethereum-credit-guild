// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Test} from "@forge-std/Test.sol";
import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {LendingTermGuild} from "@src/loan/LendingTermGuild.sol";
import {AuctionHouse} from "@src/loan/AuctionHouse.sol";
import {RateLimitedCreditMinter} from "@src/rate-limits/RateLimitedCreditMinter.sol";

contract LendingTermGuildUnitTest is Test {
    address private governor = address(1);
    Core private core;
    GuildToken guild;
    MockERC20 collateral;
    LendingTermGuild term;

    // GUILD params
    uint32 constant _CYCLE_LENGTH = 1 hours;
    uint32 constant _FREEZE_PERIOD = 10 minutes;

    // LendingTerm params
    uint256 constant _GUILD_PER_COLLATERAL_TOKEN = 2000e18; // 2000, same decimals

    function setUp() public {
        vm.warp(1679067867);
        vm.roll(16848497);
        core = new Core();

        collateral = new MockERC20();
        guild = new GuildToken(address(core), address(0), _CYCLE_LENGTH, _FREEZE_PERIOD);
        term = new LendingTermGuild(
            address(core), /*_core*/
            address(guild), /*_guildToken*/
            address(collateral), /*_collateralToken*/
            _GUILD_PER_COLLATERAL_TOKEN
        );

        // roles
        core.grantRole(CoreRoles.GOVERNOR, governor);
        core.grantRole(CoreRoles.GUILD_MINTER, address(term));
        core.renounceRole(CoreRoles.GOVERNOR, address(this));

        // labels
        vm.label(address(core), "core");
        vm.label(address(collateral), "collateral");
        vm.label(address(guild), "guild");
        vm.label(address(term), "term");
    }

    function testInitialState() public {
        assertEq(address(term.core()), address(core));
        assertEq(address(term.guildToken()), address(guild));
        assertEq(address(term.auctionHouse()), address(0));
        assertEq(address(term.creditMinter()), address(0));
        assertEq(address(term.creditToken()), address(0));
        assertEq(address(term.collateralToken()), address(collateral));
        assertEq(term.maxDebtPerCollateralToken(), _GUILD_PER_COLLATERAL_TOKEN);
        assertEq(term.interestRate(), 0);
        assertEq(term.callFee(), 0);
        assertEq(term.callPeriod(), 0);
        assertEq(term.hardCap(), type(uint256).max);
        assertEq(term.ltvBuffer(), 0);
        assertEq(term.issuance(), 0);

        assertEq(collateral.totalSupply(), 0);
        assertEq(guild.totalSupply(), 0);
    }

    function testBorrowRepay() public {
        // prepare
        collateral.mint(address(this), 1e18);
        collateral.approve(address(term), 1e18);

        // borrow
        bytes32 loanId = term.borrow(_GUILD_PER_COLLATERAL_TOKEN, 1e18);

        // check token locations
        assertEq(collateral.balanceOf(address(this)), 0);
        assertEq(collateral.balanceOf(address(term)), 1e18);
        assertEq(collateral.totalSupply(), 1e18);
        assertEq(guild.balanceOf(address(this)), _GUILD_PER_COLLATERAL_TOKEN);
        assertEq(guild.balanceOf(address(term)), 0);
        assertEq(guild.totalSupply(), _GUILD_PER_COLLATERAL_TOKEN);

        // check loan creation
        assertEq(term.getLoan(loanId).borrower, address(this));
        assertEq(term.getLoan(loanId).borrowAmount, _GUILD_PER_COLLATERAL_TOKEN);
        assertEq(term.getLoan(loanId).collateralAmount, 1e18);
        assertEq(term.getLoan(loanId).caller, address(0));
        assertEq(term.getLoan(loanId).callTime, 0);
        assertEq(term.getLoan(loanId).originationTime, block.timestamp);
        assertEq(term.getLoan(loanId).closeTime, 0);
        assertEq(term.issuance(), _GUILD_PER_COLLATERAL_TOKEN);
        assertEq(term.getLoanDebt(loanId), _GUILD_PER_COLLATERAL_TOKEN);

        // check interest does not accrue over time
        vm.warp(block.timestamp + term.YEAR());
        vm.roll(block.number + 1);
        assertEq(term.getLoanDebt(loanId), _GUILD_PER_COLLATERAL_TOKEN);

        // repay
        guild.approve(address(term), _GUILD_PER_COLLATERAL_TOKEN);
        term.repay(loanId);

        // check token locations
        assertEq(collateral.balanceOf(address(this)), 1e18);
        assertEq(collateral.balanceOf(address(term)), 0);
        assertEq(collateral.totalSupply(), 1e18);
        assertEq(guild.balanceOf(address(this)), 0);
        assertEq(guild.balanceOf(address(term)), 0);
        assertEq(guild.totalSupply(), 0);
    }
}
