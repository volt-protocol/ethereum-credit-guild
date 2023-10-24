// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CoreRef} from "@src/core/CoreRef.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {ProfitManager} from "@src/governance/ProfitManager.sol";
import {RateLimitedMinter} from "@src/rate-limits/RateLimitedMinter.sol";

/// @notice Simple PSM contract of the Ethereum Credit Guild, that allows mint/redeem
/// of CREDIT token outside of lending terms & guarantee a stable peg of the CREDIT token
/// around the value targeted by the protocol.
/// The SimplePSM targets a value equal to ProfitManager.creditMultiplier(), so when bad
/// debt is created and all loans are marked up, they stay the same in terms of peg token,
/// because new CREDIT can be minted with fewer peg tokens from the PSM. Conversely, when
/// new loans are issued, if there are funds available in the SimplePSM, borrowers know
/// the amount of peg tokens they'll be able to redeem their borrowed CREDIT for.
/// @dev inspired by the SimpleFeiDaiPSM used in the TribeDAO shutdown, see:
/// - https://github.com/code-423n4/2022-09-tribe/blob/main/contracts/peg/SimpleFeiDaiPSM.sol
/// - https://code4rena.com/reports/2022-09-tribe
contract SimplePSM is CoreRef {
    using SafeERC20 for ERC20;

    /// @notice reference to the ProfitManager contract
    address public immutable profitManager;

    /// @notice reference to the RateLimitedMinter contract to mint CREDIT
    address public immutable rlcm;

    /// @notice reference to the CreditToken contract
    address public immutable credit;

    /// @notice reference to the peg token contract
    address public immutable pegToken;

    /// @notice multiplier for decimals correction, e.g. 1e12 for a pegToken
    /// with 6 decimals (because CREDIT has 18 decimals)
    uint256 public immutable decimalCorrection;

    /// @notice event emitted upon a redemption
    event Redeem(address indexed to, uint256 amountIn, uint256 amountOut);
    /// @notice event emitted when credit gets minted
    event Mint(address indexed to, uint256 amountIn, uint256 amountOut);

    constructor(
        address _core,
        address _profitManager,
        address _rlcm,
        address _credit,
        address _pegToken
    ) CoreRef(_core) {
        profitManager = _profitManager;
        rlcm = _rlcm;
        credit = _credit;
        pegToken = _pegToken;

        uint256 decimals = uint256(ERC20(_pegToken).decimals());
        decimalCorrection = 10 ** (18 - decimals);
    }

    /// @notice calculate the amount of CREDIT out for a given `amountIn` of underlying
    function getMintAmountOut(uint256 amountIn) public view returns (uint256) {
        uint256 creditMultiplier = ProfitManager(profitManager)
            .creditMultiplier();
        return (amountIn * decimalCorrection * 1e18) / creditMultiplier;
    }

    /// @notice calculate the amount of underlying out for a given `amountIn` of CREDIT
    function getRedeemAmountOut(
        uint256 amountIn
    ) public view returns (uint256) {
        uint256 creditMultiplier = ProfitManager(profitManager)
            .creditMultiplier();
        return (amountIn * creditMultiplier) / 1e18 / decimalCorrection;
    }

    /// @notice mint `amountOut` CREDIT to address `to` for `amountIn` underlying tokens
    /// @dev see getMintAmountOut() to pre-calculate amount out
    function mint(
        address to,
        uint256 amountIn
    ) external whenNotPaused returns (uint256 amountOut) {
        amountOut = getMintAmountOut(amountIn);
        ERC20(pegToken).safeTransferFrom(msg.sender, address(this), amountIn);
        RateLimitedMinter(rlcm).mint(to, amountOut);
        emit Mint(to, amountIn, amountOut);
    }

    /// @notice redeem `amountIn` CREDIT for `amountOut` underlying tokens and send to address `to`
    /// @dev see getRedeemAmountOut() to pre-calculate amount out
    function redeem(
        address to,
        uint256 amountIn
    ) external returns (uint256 amountOut) {
        amountOut = getRedeemAmountOut(amountIn);
        CreditToken(credit).burnFrom(msg.sender, amountIn);
        RateLimitedMinter(rlcm).replenishBuffer(amountIn);
        ERC20(pegToken).safeTransfer(to, amountOut);
        emit Redeem(to, amountIn, amountOut);
    }
}
