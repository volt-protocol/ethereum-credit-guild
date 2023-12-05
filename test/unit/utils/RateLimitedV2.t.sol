pragma solidity 0.8.13;

import {SafeCastLib} from "@src/external/solmate/SafeCastLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Vm} from "@forge-std/Vm.sol";
import {Test} from "@forge-std/Test.sol";
import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {MockRateLimitedV2} from "@test/mock/MockRateLimitedV2.sol";

contract UnitTestRateLimitedV2 is Test {
    using SafeCastLib for *;

    address private governor = address(1);

    /// @notice event emitted when buffer cap is updated
    event BufferCapUpdate(uint256 oldBufferCap, uint256 newBufferCap);

    /// @notice event emitted when rate limit per second is updated
    event RateLimitPerSecondUpdate(
        uint256 oldRateLimitPerSecond,
        uint256 newRateLimitPerSecond
    );

    /// @notice event emitted when buffer gets eaten into
    event BufferUsed(uint256 amountUsed, uint256 bufferRemaining);

    /// @notice event emitted when buffer gets replenished
    event BufferReplenished(uint256 amountReplenished, uint256 bufferRemaining);

    /// @notice rate limited v2 contract
    MockRateLimitedV2 rlm;

    /// @notice reference to core
    Core private core;

    /// @notice maximum rate limit per second in RateLimitedV2
    uint256 private constant maxRateLimitPerSecond = 1_000_000e18;

    /// @notice rate limit per second in RateLimitedV2
    uint128 private constant rateLimitPerSecond = 10_000e18;

    /// @notice buffer cap in RateLimitedV2
    uint128 private constant bufferCap = 10_000_000e18;

    function setUp() public {
        core = new Core();
        core.grantRole(CoreRoles.GOVERNOR, governor);
        core.renounceRole(CoreRoles.GOVERNOR, address(this));

        rlm = new MockRateLimitedV2(
            address(core),
            maxRateLimitPerSecond,
            rateLimitPerSecond,
            bufferCap
        );
    }

    function testSetup() public {
        assertEq(rlm.bufferCap(), bufferCap);
        assertEq(rlm.rateLimitPerSecond(), rateLimitPerSecond);
        assertEq(rlm.MAX_RATE_LIMIT_PER_SECOND(), maxRateLimitPerSecond);
        assertEq(rlm.buffer(), bufferCap); /// buffer has not been depleted
    }

    /// ACL Tests

    function testSetBufferCapNonGovFails() public {
        vm.expectRevert("UNAUTHORIZED");
        rlm.setBufferCap(0);
    }

    function testSetBufferCapGovSucceeds() public {
        uint256 newBufferCap = 100_000e18;

        vm.prank(governor);
        vm.expectEmit(true, false, false, true, address(rlm));
        emit BufferCapUpdate(bufferCap, newBufferCap);
        rlm.setBufferCap(newBufferCap.safeCastTo128());

        assertEq(rlm.bufferCap(), newBufferCap);
        assertEq(rlm.buffer(), newBufferCap); /// buffer has not been depleted
    }

    function testSetRateLimitPerSecondNonGovFails() public {
        vm.expectRevert("UNAUTHORIZED");
        rlm.setRateLimitPerSecond(0);
    }

    function testSetRateLimitPerSecondAboveMaxFails() public {
        vm.expectRevert("RateLimited: rateLimitPerSecond too high");
        vm.prank(governor);
        rlm.setRateLimitPerSecond(maxRateLimitPerSecond.safeCastTo128() + 1);
    }

    function testSetRateLimitPerSecondSucceeds() public {
        vm.prank(governor);
        rlm.setRateLimitPerSecond(maxRateLimitPerSecond.safeCastTo128());
        assertEq(rlm.rateLimitPerSecond(), maxRateLimitPerSecond);
    }

    function testDepleteBufferFailsWhenZeroBuffer() public {
        rlm.depleteBuffer(bufferCap);
        vm.expectRevert("RateLimited: no rate limit buffer");
        rlm.depleteBuffer(bufferCap);
    }

    function testSetRateLimitPerSecondGovSucceeds() public {
        uint256 newRateLimitPerSecond = 15_000e18;

        vm.prank(governor);
        vm.expectEmit(true, false, false, true, address(rlm));
        emit RateLimitPerSecondUpdate(
            rateLimitPerSecond,
            newRateLimitPerSecond
        );
        rlm.setRateLimitPerSecond(newRateLimitPerSecond.safeCastTo128());

        assertEq(rlm.rateLimitPerSecond(), newRateLimitPerSecond);
    }

    function testDepleteBuffer(uint128 amountToPull, uint16 warpAmount) public {
        if (amountToPull > bufferCap) {
            vm.expectRevert("RateLimited: rate limit hit");
            rlm.depleteBuffer(amountToPull);
        } else {
            vm.expectEmit(true, false, false, true, address(rlm));
            emit BufferUsed(amountToPull, bufferCap - amountToPull);
            rlm.depleteBuffer(amountToPull);
            uint256 endingBuffer = rlm.buffer();
            assertEq(endingBuffer, bufferCap - amountToPull);
            assertEq(block.timestamp, rlm.lastBufferUsedTime());

            vm.warp(block.timestamp + warpAmount);

            uint256 accruedBuffer = warpAmount * rateLimitPerSecond;
            uint256 expectedBuffer = Math.min(
                endingBuffer + accruedBuffer,
                bufferCap
            );
            assertEq(expectedBuffer, rlm.buffer());
        }
    }

    function testReplenishBuffer(
        uint128 amountToReplenish,
        uint16 warpAmount
    ) public {
        rlm.depleteBuffer(bufferCap); /// fully exhaust buffer
        assertEq(rlm.buffer(), 0);

        uint256 actualAmountToReplenish = Math.min(
            amountToReplenish,
            bufferCap
        );
        vm.expectEmit(true, false, false, true, address(rlm));
        emit BufferReplenished(amountToReplenish, actualAmountToReplenish);

        rlm.replenishBuffer(amountToReplenish);
        assertEq(rlm.buffer(), actualAmountToReplenish);
        assertEq(block.timestamp, rlm.lastBufferUsedTime());

        vm.warp(block.timestamp + warpAmount);

        uint256 accruedBuffer = warpAmount * rateLimitPerSecond;
        uint256 expectedBuffer = Math.min(
            amountToReplenish + accruedBuffer,
            bufferCap
        );
        assertEq(expectedBuffer, rlm.buffer());
    }

    function testDepleteThenReplenishBuffer(
        uint128 amountToDeplete,
        uint128 amountToReplenish,
        uint16 warpAmount
    ) public {
        uint256 actualAmountToDeplete = Math.min(amountToDeplete, bufferCap);
        rlm.depleteBuffer(actualAmountToDeplete); /// deplete buffer
        assertEq(rlm.buffer(), bufferCap - actualAmountToDeplete);

        uint256 actualAmountToReplenish = Math.min(
            amountToReplenish,
            bufferCap
        );

        rlm.replenishBuffer(amountToReplenish);
        uint256 finalState = bufferCap -
            actualAmountToDeplete +
            actualAmountToReplenish;
        uint256 endingBuffer = Math.min(finalState, bufferCap);
        assertEq(rlm.buffer(), endingBuffer);
        assertEq(block.timestamp, rlm.lastBufferUsedTime());

        vm.warp(block.timestamp + warpAmount);

        uint256 accruedBuffer = warpAmount * rateLimitPerSecond;
        uint256 expectedBuffer = Math.min(
            finalState + accruedBuffer,
            bufferCap
        );
        assertEq(expectedBuffer, rlm.buffer());
    }

    function testReplenishWhenAtBufferCapHasNoEffect(
        uint128 amountToReplenish
    ) public {
        rlm.replenishBuffer(amountToReplenish);
        assertEq(rlm.buffer(), bufferCap);
        assertEq(block.timestamp, rlm.lastBufferUsedTime());
    }
}
