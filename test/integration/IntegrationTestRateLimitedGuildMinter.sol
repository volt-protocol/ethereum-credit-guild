// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "@forge-std/Test.sol";

import {AddressLib} from "@test/proposals/AddressLib.sol";
import {PostProposalCheckFixture} from "@test/integration/PostProposalCheckFixture.sol";

contract IntegrationTestRateLimitedGuildMinter is PostProposalCheckFixture {
    /// scenarios:
    ///      1. governance changes buffer cap
    ///      2. governance changes rate limit per second
    ///      3. try to replenish when buffer is full
    ///      4. try to deplete over buffer
    ///      5. try to deplete when buffer is 0

    function testGovernanceUpdatesBufferCap() public {
        uint128 newBufferCap = 100_000_000 * 1e18;

        vm.prank(AddressLib.get("DAO_TIMELOCK"));
        rateLimitedGuildMinter.setBufferCap(newBufferCap);

        assertEq(rateLimitedGuildMinter.bufferCap(), newBufferCap);
        assertEq(rateLimitedGuildMinter.buffer(), newBufferCap);
    }

    function testGovernanceUpdatesRateLimitPerSecond() public {
        uint128 newRateLimitPerSecond = 1;

        vm.prank(AddressLib.get("DAO_TIMELOCK"));
        vm.expectRevert("RateLimited: rateLimitPerSecond too high");
        rateLimitedGuildMinter.setRateLimitPerSecond(newRateLimitPerSecond);
    }

    function testMultisigMintsGuildOverBufferFails() public {
        uint256 mintAmount = rateLimitedGuildMinter.buffer() + 1;

        vm.prank(teamMultisig);
        vm.expectRevert("RateLimited: rate limit hit");
        rateLimitedGuildMinter.mint(address(this), mintAmount);
    }

    function testMultisigMintsGuildWhenBufferExhaustedFails() public {
        uint256 mintAmount = rateLimitedGuildMinter.buffer();

        vm.prank(teamMultisig);
        rateLimitedGuildMinter.mint(address(this), mintAmount); /// fully exhaust buffer

        vm.prank(teamMultisig);
        vm.expectRevert("RateLimited: no rate limit buffer");
        rateLimitedGuildMinter.mint(address(this), mintAmount);
    }

    function testMultisigReplenishesWhenBufferFull() public {
        uint256 mintAmount = rateLimitedGuildMinter.bufferCap() -
            rateLimitedGuildMinter.buffer();

        vm.prank(teamMultisig);
        rateLimitedGuildMinter.replenishBuffer(mintAmount); /// replenish does nothing if mintAmount is 0

        assertEq(
            rateLimitedGuildMinter.buffer(),
            rateLimitedGuildMinter.bufferCap(),
            "buffer replenished incorrectly"
        );
    }
}
