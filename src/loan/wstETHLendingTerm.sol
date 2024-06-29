// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import {CoreRef} from "@src/core/CoreRef.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {WrapLendingTerm} from "@src/loan/WrapLendingTerm.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {AuctionHouse} from "@src/loan/AuctionHouse.sol";
import {ProfitManager} from "@src/governance/ProfitManager.sol";
import {RateLimitedMinter} from "@src/rate-limits/RateLimitedMinter.sol";

interface stETH {
    function submit(address _referral) external payable returns (uint256);
}

interface WstETH {
	function wrap(uint256 _stETHAmount) external returns (uint256);
    function unwrap(uint256 _wstETHAmount) external returns (uint256);
}

interface WETH {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

interface unstETH {
    function requestWithdrawalsWstETH(uint256[] calldata _amounts, address _owner)
        external
        returns (uint256[] memory requestIds);

    function claimWithdrawal(uint256 _requestId) external;
}

/// @notice wstETH Lending Term that can wrap WETH collateral to wstETH.
contract wstETHLendingTerm is WrapLendingTerm {
    using SafeERC20 for IERC20;

    // mainnet addresses
    address private WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private STETH_ADDRESS = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address private WSTETH_ADDRESS = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address private UNSTETH_ADDRESS = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;

    /// @notice mapping of loanId -> Lido withdrawal request id
    mapping(bytes32=>uint256) lidoWithdrawalRequestIds;

    // allow reception of raw ETH (for WETH unwrapping)
    receive() external payable {}

    // wrapped collateral token is wstETH
    function wrappedCollateralToken() public view override returns (address) {
        return WSTETH_ADDRESS;
    }

    // Atomic WETH -> wstETH wrapping
    function _doRequestWrap(bytes32 loanId, uint256 collateralAmount) internal override {
        // unwrap WETH to ETH
        WETH(WETH_ADDRESS).withdraw(collateralAmount);
        // stake ETH to stETH
        uint256 stethBalanceBefore = IERC20(STETH_ADDRESS).balanceOf(address(this));
        stETH(STETH_ADDRESS).submit{value: collateralAmount}(address(this));
        uint256 stethBalanceAfter = IERC20(STETH_ADDRESS).balanceOf(address(this));
        uint256 stethReceived = stethBalanceAfter - stethBalanceBefore;
        // wrap stETH to wstETH
        IERC20(STETH_ADDRESS).approve(WSTETH_ADDRESS, stethReceived);
        uint256 wstethAmount = WstETH(WSTETH_ADDRESS).wrap(stethReceived);

        // record wrapData & emit event
        WrapData memory _wrapData = loanWrapData[loanId];
        loanWrapData[loanId] = WrapData({
            status: WrapStatus.WRAPPED,
            borrowerWithdrawn: _wrapData.borrowerWithdrawn,
            bidderWithdrawn: _wrapData.bidderWithdrawn,
            bidder: _wrapData.bidder, 
            collateralToBidder: _wrapData.collateralToBidder,
            wrappedAmount: wstethAmount
        });
        emit LoanWrapStatusChange(block.timestamp, loanId, WrapStatus.WRAPPED);
    }

    // Asynchronous wstETH -> ETH withdrawal request 
    function _doRequestUnwrap(bytes32 loanId, uint256 wrappedAmount) internal override {
        // request withdrawal from wstETH
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = wrappedAmount;
        uint256[] memory requestIds = unstETH(UNSTETH_ADDRESS).requestWithdrawalsWstETH(
            amounts,
            address(0) // If `address(0)` is passed, `msg.sender` will be used as an owner.
        );
        lidoWithdrawalRequestIds[loanId] = requestIds[0];

        // record wrapData & emit event
        loanWrapData[loanId].status = WrapStatus.UNWRAPPING;
        emit LoanWrapStatusChange(block.timestamp, loanId, WrapStatus.UNWRAPPING);
    }

    // Asynchronous fulfillment of withdrawal request
    // claimWithdrawal(requestId) reverts if request is not finalized or already claimed
    function _doFulfillUnwrap(bytes32 loanId) internal override {
        // claim Lido withdrawal
        uint256 balanceBefore = address(this).balance;
        unstETH(UNSTETH_ADDRESS).claimWithdrawal(lidoWithdrawalRequestIds[loanId]);
        uint256 balanceAfter = address(this).balance;
        uint256 ethReceived = balanceAfter - balanceBefore;

        // reset storage of requestIds
        lidoWithdrawalRequestIds[loanId] = 0;

        // wrap ETH to WETH
        WETH(WETH_ADDRESS).deposit{value: ethReceived}();

        // update collateralAmount & collateralToBidder if applicable,
        // keep the same proportions to each.
        WrapData memory _wrapData = loanWrapData[loanId];
        uint256 collateralAmount = loans[loanId].collateralAmount;
        uint256 bidderCollateralPercent = _wrapData.collateralToBidder * 1e18 / collateralAmount;
        uint256 collateralToBidder = ethReceived * bidderCollateralPercent / 1e18;
        loans[loanId].collateralAmount = ethReceived - collateralToBidder;

        // record wrapData & emit event
        loanWrapData[loanId] = WrapData({
            status: WrapStatus.UNWRAPPED,
            borrowerWithdrawn: _wrapData.borrowerWithdrawn,
            bidderWithdrawn: _wrapData.bidderWithdrawn,
            bidder: _wrapData.bidder, 
            collateralToBidder: collateralToBidder,
            wrappedAmount: 0
        });
        emit LoanWrapStatusChange(block.timestamp, loanId, WrapStatus.UNWRAPPED);
    }
}
