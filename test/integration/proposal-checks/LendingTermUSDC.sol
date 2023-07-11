// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {PostProposalCheck} from "@test/integration/proposal-checks/PostProposalCheck.sol";

import {LendingTermUSDC, IUSDC} from "@src/loan/LendingTermUSDC.sol";

contract LendingTermUSDCIntegrationTest is PostProposalCheck {

    function testCanForgiveLoansIfBlacklisted() public {
        address usdc = addresses.mainnet("ERC20_USDC");
        LendingTermUSDC term = LendingTermUSDC(addresses.mainnet("TERM_USDC_1"));

        assertEq(term.canAutomaticallyForgive(), false);

        vm.startPrank(IUSDC(usdc).blacklister());
        IUSDC(usdc).blacklist(address(term));

        assertEq(term.canAutomaticallyForgive(), true);

        IUSDC(usdc).unBlacklist(address(term));

        assertEq(term.canAutomaticallyForgive(), false);

        IUSDC(usdc).blacklist(addresses.mainnet("AUCTION_HOUSE_1"));

        assertEq(term.canAutomaticallyForgive(), true);

        assertEq(term.forgiveness(), false);
        term.forgiveAllLoans();
        assertEq(term.forgiveness(), true);
    }
}
