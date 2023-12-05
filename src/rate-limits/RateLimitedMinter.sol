// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {CoreRef} from "@src/core/CoreRef.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {RateLimitedV2} from "@src/utils/RateLimitedV2.sol";

import {CreditToken} from "@src/tokens/CreditToken.sol";

interface IERC20Mintable {
    function mint(address to, uint256 amount) external;
}

/// @notice contract to mint tokens on a rate limit.
/// All minting should flow through this smart contract, as it should be the only one with
/// minting capabilities.
contract RateLimitedMinter is RateLimitedV2 {
    /// @notice the reference to token
    address public immutable token;

    /// @notice role used to access control on mint/replenishBuffer
    bytes32 public immutable role;

    /// @param _core reference to the core smart contract
    /// @param _token reference to the token to mint
    /// @param _role role used to check access control
    /// @param _maxRateLimitPerSecond maximum rate limit per second that governance can set
    /// @param _rateLimitPerSecond starting rate limit per second for minting
    /// @param _bufferCap cap on buffer size for this rate limited instance
    constructor(
        address _core,
        address _token,
        bytes32 _role,
        uint256 _maxRateLimitPerSecond,
        uint128 _rateLimitPerSecond,
        uint128 _bufferCap
    )
        CoreRef(_core)
        RateLimitedV2(_maxRateLimitPerSecond, _rateLimitPerSecond, _bufferCap)
    {
        token = _token;
        role = _role;
    }

    /// @notice Mint new tokens.
    /// Pausable and depletes the buffer, reverts if buffer is used.
    /// @param to the recipient address of the minted tokens.
    /// @param amount the amount of tokens to mint.
    function mint(
        address to,
        uint256 amount
    ) external onlyCoreRole(role) whenNotPaused {
        _depleteBuffer(amount); /// check and effects
        IERC20Mintable(token).mint(to, amount); /// interactions
    }

    /// @notice replenish the buffer.
    /// This can be used when tokens are burnt, for instance.
    /// @param amount of tokens to replenish buffer by
    function replenishBuffer(uint256 amount) external onlyCoreRole(role) {
        _replenishBuffer(amount); /// effects
    }
}
