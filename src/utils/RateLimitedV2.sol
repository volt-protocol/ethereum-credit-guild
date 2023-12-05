// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCastLib} from "@src/external/solmate/SafeCastLib.sol";

import {CoreRef} from "@src/core/CoreRef.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {IRateLimitedV2} from "@src/utils/IRateLimitedV2.sol";

/// @title abstract contract for putting a rate limit on how fast a contract
/// can perform an action e.g. Minting
/// @author Elliot Friedman
abstract contract RateLimitedV2 is IRateLimitedV2, CoreRef {
    using SafeCastLib for *;

    /// @notice maximum rate limit per second governance can set for this contract
    uint256 public immutable MAX_RATE_LIMIT_PER_SECOND;

    /// ------------- First Storage Slot -------------

    /// @notice the rate per second for this contract
    uint128 public rateLimitPerSecond;

    /// @notice the cap of the buffer that can be used at once
    uint128 public bufferCap;

    /// ------------- Second Storage Slot -------------

    /// @notice the last time the buffer was used by the contract
    uint32 public lastBufferUsedTime;

    /// @notice the buffer at the timestamp of lastBufferUsedTime
    uint224 public bufferStored;

    /// @notice RateLimitedV2 constructor
    /// @param _maxRateLimitPerSecond maximum rate limit per second that governance can set
    /// @param _rateLimitPerSecond starting rate limit per second
    /// @param _bufferCap cap on buffer size for this rate limited instance
    constructor(
        uint256 _maxRateLimitPerSecond,
        uint128 _rateLimitPerSecond,
        uint128 _bufferCap
    ) {
        lastBufferUsedTime = block.timestamp.safeCastTo32();

        _setBufferCap(_bufferCap);
        bufferStored = _bufferCap;

        require(
            _rateLimitPerSecond <= _maxRateLimitPerSecond,
            "RateLimited: rateLimitPerSecond too high"
        );
        _setRateLimitPerSecond(_rateLimitPerSecond);

        MAX_RATE_LIMIT_PER_SECOND = _maxRateLimitPerSecond;
    }

    /// @notice set the rate limit per second
    /// @param newRateLimitPerSecond the new rate limit per second of the contract
    function setRateLimitPerSecond(
        uint128 newRateLimitPerSecond
    ) external virtual onlyCoreRole(CoreRoles.GOVERNOR) {
        require(
            newRateLimitPerSecond <= MAX_RATE_LIMIT_PER_SECOND,
            "RateLimited: rateLimitPerSecond too high"
        );
        _updateBufferStored(bufferCap);

        _setRateLimitPerSecond(newRateLimitPerSecond);
    }

    /// @notice set the buffer cap
    /// @param newBufferCap new buffer cap to set
    function setBufferCap(
        uint128 newBufferCap
    ) external virtual onlyCoreRole(CoreRoles.GOVERNOR) {
        _setBufferCap(newBufferCap);
    }

    /// @notice the amount of action used before hitting limit
    /// @dev replenishes at rateLimitPerSecond per second up to bufferCap
    function buffer() public view returns (uint256) {
        uint256 elapsed = block.timestamp.safeCastTo32() - lastBufferUsedTime;
        return
            Math.min(bufferStored + (rateLimitPerSecond * elapsed), bufferCap);
    }

    /// @notice the method that enforces the rate limit.
    /// Decreases buffer by "amount".
    /// If buffer is <= amount, revert
    /// @param amount to decrease buffer by
    function _depleteBuffer(uint256 amount) internal {
        uint256 newBuffer = buffer();

        require(newBuffer != 0, "RateLimited: no rate limit buffer");
        require(amount <= newBuffer, "RateLimited: rate limit hit");

        uint32 blockTimestamp = block.timestamp.safeCastTo32();
        uint224 newBufferStored = (newBuffer - amount).safeCastTo224();

        /// gas optimization to only use a single SSTORE
        lastBufferUsedTime = blockTimestamp;
        bufferStored = newBufferStored;

        emit BufferUsed(amount, bufferStored);
    }

    /// @notice function to replenish buffer
    /// @param amount to increase buffer by if under buffer cap
    function _replenishBuffer(uint256 amount) internal {
        uint256 newBuffer = buffer();

        uint256 _bufferCap = bufferCap; /// gas opti, save an SLOAD

        /// cannot replenish any further if already at buffer cap
        if (newBuffer == _bufferCap) {
            /// save an SSTORE + some stack operations if buffer cannot be increased.
            /// last buffer used time doesn't need to be updated as buffer cannot
            /// increase past the buffer cap
            return;
        }

        uint32 blockTimestamp = block.timestamp.safeCastTo32();
        /// ensure that bufferStored cannot be gt buffer cap
        uint224 newBufferStored = Math
            .min(newBuffer + amount, _bufferCap)
            .safeCastTo224();

        /// gas optimization to only use a single SSTORE
        lastBufferUsedTime = blockTimestamp;
        bufferStored = newBufferStored;

        emit BufferReplenished(amount, bufferStored);
    }

    /// @param newRateLimitPerSecond the new rate limit per second of the contract
    function _setRateLimitPerSecond(uint128 newRateLimitPerSecond) internal {
        uint256 oldRateLimitPerSecond = rateLimitPerSecond;
        rateLimitPerSecond = newRateLimitPerSecond;

        emit RateLimitPerSecondUpdate(
            oldRateLimitPerSecond,
            newRateLimitPerSecond
        );
    }

    /// @param newBufferCap new buffer cap to set
    function _setBufferCap(uint128 newBufferCap) internal {
        _updateBufferStored(newBufferCap);

        uint256 oldBufferCap = bufferCap;
        bufferCap = newBufferCap;

        emit BufferCapUpdate(oldBufferCap, newBufferCap);
    }

    function _updateBufferStored(uint128 newBufferCap) internal {
        uint224 newBufferStored = buffer().safeCastTo224();
        uint32 newBlockTimestamp = block.timestamp.safeCastTo32();

        if (newBufferStored > newBufferCap) {
            bufferStored = uint224(newBufferCap); /// safe upcast as no precision can be lost when going from 128 -> 224
            lastBufferUsedTime = newBlockTimestamp;
        } else {
            bufferStored = newBufferStored;
            lastBufferUsedTime = newBlockTimestamp;
        }
    }
}
