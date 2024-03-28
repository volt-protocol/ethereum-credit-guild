// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./Gateway.sol";

import {SimplePSM} from "@src/loan/SimplePSM.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {AuctionHouse} from "@src/loan/AuctionHouse.sol";
import {ProfitManager} from "@src/governance/ProfitManager.sol";

/// @notice simple interface for flashloaning from balancer
interface IBalancerFlashLoan {
    function flashLoan(
        address recipient,
        IERC20[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
}

/// @notice simple interface for uniswap router
interface IUniswapRouter {
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsIn(
        uint256 amountOut,
        address[] calldata path
    ) external view returns (uint256[] memory amounts);

    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external view returns (uint256[] memory amounts);
}

/// @title ECG Gateway V1
/// @notice Gateway to interract via multicall with the ECG
/// Owner can select which calls are allowed
/// @custom:feature flashloan from balancer vault
contract GatewayV1 is Gateway {
    /// @notice Address of the Balancer Vault, used for initiating flash loans.
    address public immutable balancerVault =
        0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    /// @notice execute a multicall (see abstract Gateway.sol) after a flashloan on balancer
    /// @param tokens the addresses of tokens to be borrowed
    /// @param amounts the amounts of each tokens to be borrowed
    /// @dev this method instanciate _originalSender like the multicall function does in the abstract contract
    function multicallWithBalancerFlashLoan(
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes[] calldata calls // Calls to be made after receiving the flash loan
    ) public entryPoint whenNotPaused {
        IERC20[] memory ierc20Tokens = new IERC20[](tokens.length);
        for (uint i = 0; i < tokens.length; i++) {
            ierc20Tokens[i] = IERC20(tokens[i]);
        }

        // Initiate the flash loan
        // the balancer vault will call receiveFlashloan function on this contract before returning
        IBalancerFlashLoan(balancerVault).flashLoan(
            address(this),
            ierc20Tokens,
            amounts,
            abi.encodeWithSignature("executeFlashloanCalls(bytes[])", calls)
        );

        // here, the flashloan have been successfully reimbursed otherwise it would have reverted
    }

    /// @notice Executes calls during the receiveFlashloan
    /// @param calls An array of call data to execute.
    function executeFlashloanCalls(bytes[] calldata calls) public afterEntry {
        _executeCalls(calls);
    }

    /// @notice Handles the receipt of a flash loan from balancer, executes encoded calls, and repays the loan.
    /// @param tokens Array of ERC20 tokens received in the flash loan.
    /// @param amounts Array of amounts for each token received.
    /// @param feeAmounts Array of fee amounts for each token received.
    /// @param encodedCalls encoded calls to be made after receiving the flashloaned token(s)
    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory encodedCalls
    ) external afterEntry {
        require(
            msg.sender == balancerVault,
            "GatewayV1: sender is not balancer"
        );

        // // execute the storedCalls stored in the multicallWithBalancerFlashLoan function
        (bool success, ) = address(this).call(encodedCalls);
        require(success, "GatewayV1: encoded calls failed");

        // Transfer back the required amounts to the Balancer Vault
        for (uint256 i = 0; i < tokens.length; i++) {
            tokens[i].transfer(balancerVault, amounts[i] + feeAmounts[i]);
        }
    }

    /// @notice execute a borrow with a balancer flashloan
    /// Example flow :
    /// - flashloan sDAI from Balancer
    /// - pull user sDAI to the Gateway
    /// - borrow gUSDC from the term, with sDAI collateral
    /// - pull the gUSDC borrowed to the Gateway
    /// - Redeem gUSDC for USDC in the PSM
    /// - Swap USDC for sDAI on Uniswap
    /// - repay sDAI flashloan
    /// Slippage protection of maxLoanDebt when borrowing gUSDC from the term
    /// @dev 1 wei of USDC will be left in the gateway after execution (<0.000001$).
    function borrowWithBalancerFlashLoan(
        address term,
        address psm,
        address uniswapRouter,
        address collateralToken,
        address pegToken,
        uint256 collateralAmount,
        uint256 flashloanCollateralAmount,
        uint256 maxLoanDebt,
        bytes[] memory pullCollateralCalls,
        bytes memory allowBorrowedCreditCall
    ) public entryPoint whenNotPaused {
        // this function performs 8 more calls than the number of calls in 'pullCollateralCalls'
        bytes[] memory calls = new bytes[](pullCollateralCalls.length + 8);
        uint256 callCursor = 0;

        // after flashloan tokens are received, first calls are to pull collateral
        // tokens from the user to the gateway, e.g. consumePermit + consumeAllowance
        // or just consumeAllowance if the user has already approved the gateway
        for (uint256 i = 0; i < pullCollateralCalls.length; i++) {
            calls[callCursor++] = pullCollateralCalls[i];
        }

        // approve the term before borrow
        calls[callCursor++] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            collateralToken,
            abi.encodeWithSignature(
                "approve(address,uint256)",
                term,
                collateralAmount + flashloanCollateralAmount
            )
        );

        // do borrow in order to have, after psm redeem, exactly the amount of pegTokens
        // needed to swap back to {flashloanCollateralAmount} collateralTokens
        uint256 pegTokenAmount;
        {
            address[] memory path = new address[](2);
            path[0] = pegToken;
            path[1] = collateralToken;
            uint256[] memory amountsIn = IUniswapRouter(uniswapRouter)
                .getAmountsIn(flashloanCollateralAmount, path);
            pegTokenAmount = amountsIn[0];
        }
        uint256 creditToBorrow = SimplePSM(psm).getMintAmountOut(
            pegTokenAmount + 1
        );
        require(creditToBorrow < maxLoanDebt, "GatewayV1: loan debt too high");
        calls[callCursor++] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            term,
            abi.encodeWithSignature(
                "borrowOnBehalf(uint256,uint256,address)",
                creditToBorrow,
                collateralAmount + flashloanCollateralAmount,
                msg.sender
            )
        );

        // pull borrowed credit to the gateway
        address _creditToken = LendingTerm(term).creditToken();
        calls[callCursor++] = allowBorrowedCreditCall;
        calls[callCursor++] = abi.encodeWithSignature(
            "consumeAllowance(address,uint256)",
            _creditToken,
            creditToBorrow
        );

        // redeem credit tokens to pegTokens in the PSM
        calls[callCursor++] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            _creditToken,
            abi.encodeWithSignature(
                "approve(address,uint256)",
                psm,
                creditToBorrow
            )
        );
        calls[callCursor++] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            psm,
            abi.encodeWithSignature(
                "redeem(address,uint256)",
                address(this),
                creditToBorrow
            )
        );

        // swap pegTokens for collateralTokens in order to be able to repay the flashloan
        calls[callCursor++] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            pegToken,
            abi.encodeWithSignature(
                "approve(address,uint256)",
                uniswapRouter,
                pegTokenAmount
            )
        );

        {
            address[] memory path = new address[](2);
            path[0] = address(pegToken);
            path[1] = address(collateralToken);
            calls[callCursor++] = abi.encodeWithSignature(
                "callExternal(address,bytes)",
                uniswapRouter,
                abi.encodeWithSignature(
                    "swapTokensForExactTokens(uint256,uint256,address[],address,uint256)",
                    flashloanCollateralAmount, // amount out
                    pegTokenAmount, // amount in max
                    path, // path pegToken->collateralToken
                    address(this), // to
                    uint256(block.timestamp + 1) // deadline
                )
            );
        }

        // Initiate the flash loan
        // the balancer vault will call receiveFlashloan function on this contract before returning
        IERC20[] memory ierc20Tokens = new IERC20[](1);
        ierc20Tokens[0] = IERC20(collateralToken);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = flashloanCollateralAmount;
        IBalancerFlashLoan(balancerVault).flashLoan(
            address(this),
            ierc20Tokens,
            amounts,
            abi.encodeWithSignature("executeFlashloanCalls(bytes[])", calls)
        );

        // here, the flashloan have been successfully reimbursed otherwise it would have reverted
    }

    /// @notice execute a repay with a balancer flashloan.
    /// Example flow :
    /// - flashloan USDC from Balancer
    /// - mint gUSDC in PSM
    /// - repay the loan, get sDAI collateral back
    /// - pull sDAI to the Gateway
    /// - swap sDAI to USDC on Uniswap
    /// - repay USDC flashloan
    /// Slippage protection of maxCollateralSold when pulling sDAI to the gateway, so that
    /// the user can end up with at lease {loan.collateralAmount - maxCollateralSold} sDAI
    /// in their wallet at the end.
    /// @dev up to 1e12 gUSDC might be left in the gateway after execution (<0.000001$).
    function repayWithBalancerFlashLoan(
        bytes32 loanId,
        address term,
        address psm,
        address uniswapRouter,
        address collateralToken,
        address pegToken,
        uint256 maxCollateralSold,
        bytes memory allowCollateralTokenCall
    ) public entryPoint whenNotPaused {
        // prepare the calls to be made
        bytes[] memory calls = new bytes[](8);
        uint256 callCursor = 0;

        // compute amount of pegTokens needed to cover the debt
        uint256 debt = LendingTerm(term).getLoanDebt(loanId);
        uint256 flashloanPegTokenAmount = SimplePSM(psm).getRedeemAmountOut(
            debt
        ) + 1;

        // approve the psm & mint creditTokens
        calls[callCursor++] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            pegToken,
            abi.encodeWithSignature(
                "approve(address,uint256)",
                psm,
                flashloanPegTokenAmount
            )
        );
        calls[callCursor++] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            psm,
            abi.encodeWithSignature(
                "mint(address,uint256)",
                address(this),
                flashloanPegTokenAmount
            )
        );

        // repay the loan
        address _creditToken = LendingTerm(term).creditToken();
        calls[callCursor++] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            _creditToken,
            abi.encodeWithSignature("approve(address,uint256)", term, debt)
        );
        calls[callCursor++] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            term,
            abi.encodeWithSignature("repay(bytes32)", loanId)
        );

        // compute exactly the number of collateralTokens needed to repay the flashloan
        uint256 collateralTokenAmount;
        {
            address[] memory path = new address[](2);
            path[0] = collateralToken;
            path[1] = pegToken;
            uint256[] memory amountsIn = IUniswapRouter(uniswapRouter)
                .getAmountsIn(flashloanPegTokenAmount, path);
            collateralTokenAmount = amountsIn[0];
        }
        require(
            collateralTokenAmount < maxCollateralSold,
            "GatewayV1: collateral left too low"
        );

        // pull collateralTokens to the gateway
        calls[callCursor++] = allowCollateralTokenCall;
        calls[callCursor++] = abi.encodeWithSignature(
            "consumeAllowance(address,uint256)",
            collateralToken,
            collateralTokenAmount
        );

        // swap {collateralTokenAmount} collateralTokens to {flashloanPegTokenAmount} pegTokens
        calls[callCursor++] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            collateralToken,
            abi.encodeWithSignature(
                "approve(address,uint256)",
                uniswapRouter,
                collateralTokenAmount
            )
        );
        {
            address[] memory path = new address[](2);
            path[0] = address(collateralToken);
            path[1] = address(pegToken);
            calls[callCursor++] = abi.encodeWithSignature(
                "callExternal(address,bytes)",
                uniswapRouter,
                abi.encodeWithSignature(
                    "swapTokensForExactTokens(uint256,uint256,address[],address,uint256)",
                    flashloanPegTokenAmount, // amount out
                    collateralTokenAmount, // amount in max
                    path, // path collateralToken->pegToken
                    address(this), // to
                    uint256(block.timestamp + 1) // deadline
                )
            );
        }

        // Initiate the flash loan
        // the balancer vault will call receiveFlashloan function on this contract before returning
        IERC20[] memory ierc20Tokens = new IERC20[](1);
        ierc20Tokens[0] = IERC20(pegToken);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = flashloanPegTokenAmount;
        IBalancerFlashLoan(balancerVault).flashLoan(
            address(this),
            ierc20Tokens,
            amounts,
            abi.encodeWithSignature("executeFlashloanCalls(bytes[])", calls)
        );

        // here, the flashloan have been successfully reimbursed otherwise it would have reverted
    }

    /// @notice bid in an auction with a balancer flashloan.
    /// Example flow :
    /// - flashloan USDC from Balancer
    /// - mint gUSDC in PSM
    /// - approve gUSDC on the LendingTerm
    /// - bid in the auction
    /// - swap sDAI to USDC using a router (1inch, uniswap, openocean) and preencoded call to this router
    /// - repay USDC flashloan
    /// Slippage protection of minPegTokenProfit during swap to ensure auction bid profitability
    /// @dev up to 1e12 gUSDC might be left in the gateway after execution (<0.000001$).
    function bidWithBalancerFlashLoan(
        bytes32 loanId,
        address term,
        address psm,
        address collateralToken,
        address pegToken,
        uint256 minPegTokenProfit,
        address routerAddress,
        bytes calldata routerCallData
    ) public entryPoint whenNotPaused returns (uint256) {
        // prepare calls
        (
            bytes[] memory calls,
            uint256 flashloanPegTokenAmount,
            address creditToken
        ) = _prepareBidCalls(
                loanId,
                term,
                psm,
                collateralToken,
                pegToken,
                routerAddress,
                routerCallData
            );

        // Initiate the flash loan
        // the balancer vault will call receiveFlashloan function on this contract before returning
        {
            IERC20[] memory ierc20Tokens = new IERC20[](1);
            ierc20Tokens[0] = IERC20(pegToken);
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = flashloanPegTokenAmount;
            IBalancerFlashLoan(balancerVault).flashLoan(
                address(this),
                ierc20Tokens,
                amounts,
                abi.encodeWithSignature("executeFlashloanCalls(bytes[])", calls)
            );
        }

        // here, the flashloan have been successfully reimbursed otherwise it would have reverted

        return
            _sendTokensToSender(
                minPegTokenProfit,
                pegToken,
                creditToken,
                collateralToken
            );
    }

    function _prepareBidCalls(
        bytes32 loanId,
        address term,
        address psm,
        address collateralToken,
        address pegToken,
        address routerAddress,
        bytes calldata routerCallData
    )
        internal
        view
        returns (
            bytes[] memory calls,
            uint256 flashloanPegTokenAmount,
            address creditToken
        )
    {
        calls = new bytes[](6);
        // compute amount of pegTokens needed to cover the debt
        {
            address _auctionHouse = LendingTerm(term).auctionHouse();
            (uint256 collateralReceived, uint256 creditAsked) = AuctionHouse(
                _auctionHouse
            ).getBidDetail(loanId);
            flashloanPegTokenAmount =
                SimplePSM(psm).getRedeemAmountOut(creditAsked) +
                1;

            // approve the psm & mint creditTokens
            calls[0] = abi.encodeWithSignature(
                "callExternal(address,bytes)",
                pegToken,
                abi.encodeWithSignature(
                    "approve(address,uint256)",
                    psm,
                    flashloanPegTokenAmount
                )
            );

            calls[1] = abi.encodeWithSignature(
                "callExternal(address,bytes)",
                psm,
                abi.encodeWithSignature(
                    "mint(address,uint256)",
                    address(this),
                    flashloanPegTokenAmount
                )
            );

            // bid in auction
            creditToken = LendingTerm(term).creditToken();
            calls[2] = abi.encodeWithSignature(
                "callExternal(address,bytes)",
                creditToken,
                abi.encodeWithSignature(
                    "approve(address,uint256)",
                    term,
                    creditAsked
                )
            );

            calls[3] = abi.encodeWithSignature(
                "callExternal(address,bytes)",
                _auctionHouse,
                abi.encodeWithSignature("bid(bytes32)", loanId)
            );

            // swap received collateralTokens to pegTokens
            // allow collateral token to be used by the router
            calls[4] = abi.encodeWithSignature(
                "callExternal(address,bytes)",
                collateralToken,
                abi.encodeWithSignature(
                    "approve(address,uint256)",
                    routerAddress,
                    collateralReceived
                )
            );
        }

        // call the function on the router, using the given calldata
        calls[5] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            routerAddress,
            routerCallData
        );
    }

    function _sendTokensToSender(
        uint256 minPegTokenProfit,
        address pegToken,
        address creditToken,
        address collateralToken
    ) internal returns (uint256 pegTokenBalance) {
        pegTokenBalance = IERC20(pegToken).balanceOf(address(this));
        require(
            pegTokenBalance > minPegTokenProfit,
            "GatewayV1: profit too low"
        );
        IERC20(pegToken).transfer(msg.sender, pegTokenBalance);

        // send any remaining CREDIT, this can happen if the mint returned more credit than needed
        uint256 remainingCredit = IERC20(creditToken).balanceOf(address(this));
        if (remainingCredit > 0) {
            IERC20(creditToken).transfer(msg.sender, remainingCredit);
        }

        // send any remaining collateralToken this can happen if the amount of collateral received
        // was more than estimated
        uint256 remainingCollateral = IERC20(collateralToken).balanceOf(
            address(this)
        );
        if (remainingCollateral > 0) {
            IERC20(collateralToken).transfer(msg.sender, remainingCollateral);
        }
    }
}
