// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.13;

import {CoreRoles} from "@src/core/CoreRoles.sol";
import {CoreRef} from "@src/core/CoreRef.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {RateLimitedV2} from "@src/utils/RateLimitedV2.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title contract used to redeem a list of tokens, by permanently
/// taking another token out of circulation.
/// @author Fei Protocol, eswak
/// This contract has been used by the Tribe DAO to allow redemptions of TRIBE for their
/// pro-rata share of the PCV. This version is modified to allow the redemption of GUILD
/// tokens, and the GUILD.totalSupply() is used instead of a hardcoded base. Moreover,
/// there is a rate limit to the redemptions, and the GUILD tokens are burnt on redeem.
/// The rate limit is expressed as a number of GUILD tokens available for redemption.
/// This contract also has a reference to Core that allow governance to recover funds
/// on this contract, and pause/unpause the redemptions.
contract Redeemer is ReentrancyGuard, RateLimitedV2 {
    using SafeERC20 for IERC20;

    /// @notice event to track redemptions
    event Redeemed(
        address indexed owner,
        address indexed receiver,
        uint256 amount,
        uint256 base
    );

    /// @notice token to redeem
    address public immutable redeemedToken;

    /// @notice tokens to receive when redeeming
    address[] private tokensReceived;

    constructor(
        address _core,
        address _redeemedToken,
        address[] memory _tokensReceived,
        uint256 _maxRateLimitPerSecond,
        uint128 _rateLimitPerSecond,
        uint128 _bufferCap
    )
        CoreRef(_core)
        RateLimitedV2(_maxRateLimitPerSecond, _rateLimitPerSecond, _bufferCap)
    {
        redeemedToken = _redeemedToken;
        tokensReceived = _tokensReceived;
    }

    /// @notice Public function to get `tokensReceived`
    function tokensReceivedOnRedeem() public view returns (address[] memory) {
        return tokensReceived;
    }

    /// @notice Return the balances of `tokensReceived` that would be
    /// transferred if redeeming `amountIn` of `redeemedToken`.
    function previewRedeem(
        uint256 amountIn
    )
        public
        view
        returns (
            uint256 base,
            address[] memory tokens,
            uint256[] memory amountsOut
        )
    {
        tokens = tokensReceivedOnRedeem();
        amountsOut = new uint256[](tokens.length);
        GuildToken _guild = GuildToken(redeemedToken);

        base = _guild.totalSupply();
        for (uint256 i = 0; i < tokensReceived.length; i++) {
            uint256 balance = IERC20(tokensReceived[i]).balanceOf(
                address(this)
            );
            require(balance != 0, "ZERO_BALANCE");
            // @dev, this assumes all of `tokensReceived` and `redeemedToken`
            // have the same number of decimals
            uint256 redeemedAmount = (amountIn * balance) / base;
            amountsOut[i] = redeemedAmount;
        }
    }

    /// @notice Redeem `redeemedToken` for a pro-rata basket of `tokensReceived`
    function redeem(
        address to,
        uint256 amountIn
    ) external whenNotPaused nonReentrant {
        _depleteBuffer(amountIn);

        GuildToken _guild = GuildToken(redeemedToken);
        _guild.transferFrom(msg.sender, address(this), amountIn);

        (
            uint256 base,
            address[] memory tokens,
            uint256[] memory amountsOut
        ) = previewRedeem(amountIn);

        _guild.burn(amountIn);

        for (uint256 i = 0; i < tokens.length; i++) {
            IERC20(tokens[i]).safeTransfer(to, amountsOut[i]);
        }

        emit Redeemed(msg.sender, to, amountIn, base);
    }

    /// @notice governor-only function to migrate funds to a new contract
    function withdrawAll(
        address token,
        address to
    ) external onlyCoreRole(CoreRoles.GOVERNOR) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).transfer(to, balance);
    }
}
