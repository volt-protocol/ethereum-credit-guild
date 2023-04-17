// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.13;

/// @title abstract contract for putting a rate limit on how fast a contract
/// can perform an action e.g. Minting
/// @author Elliot Friedman
interface IRateLimitedV2 {
    /// ------------- View Only API's -------------

    /// @notice maximum rate limit per second governance can set for this contract
    function MAX_RATE_LIMIT_PER_SECOND() external view returns (uint256);

    /// @notice the rate per second for this contract
    function rateLimitPerSecond() external view returns (uint128);

    /// @notice the cap of the buffer that can be used at once
    function bufferCap() external view returns (uint128);

    /// @notice the last time the buffer was used by the contract
    function lastBufferUsedTime() external view returns (uint32);

    /// @notice the buffer at the timestamp of lastBufferUsedTime
    function bufferStored() external view returns (uint224);

    /// @notice the amount of action used before hitting limit
    /// @dev replenishes at rateLimitPerSecond per second up to bufferCap
    function buffer() external view returns (uint256);

    /// ------------- Governor Only API's -------------

    /// @notice set the rate limit per second
    function setRateLimitPerSecond(uint128 newRateLimitPerSecond) external;

    /// @notice set the buffer cap
    function setBufferCap(uint128 newBufferCap) external;

    /// ------------- Events -------------

    /// @notice event emitted when buffer gets eaten into
    event BufferUsed(uint256 amountUsed, uint256 bufferRemaining);

    /// @notice event emitted when buffer gets replenished
    event BufferReplenished(uint256 amountReplenished, uint256 bufferRemaining);

    /// @notice event emitted when buffer cap is updated
    event BufferCapUpdate(uint256 oldBufferCap, uint256 newBufferCap);

    /// @notice event emitted when rate limit per second is updated
    event RateLimitPerSecondUpdate(
        uint256 oldRateLimitPerSecond,
        uint256 newRateLimitPerSecond
    );
}
