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

    /// @notice Stores calls to be executed after receiving a flash loan.
    /// @dev The StoredCalls should/must only be set in the 'multicallWithBalancerFlashLoan'
    bytes[] internal _storedCalls;

    /// @notice execute a multicall (see abstract Gateway.sol) after a flashloan on balancer
    /// store the multicall calls in the _storedCalls state variable to be executed on the receiveFlashloan method (executed from the balancer vault)
    /// @param tokens the addresses of tokens to be borrowed
    /// @param amounts the amounts of each tokens to be borrowed
    /// @dev this method instanciate _originalSender like the multicall function does in the abstract contract
    function multicallWithBalancerFlashLoan(
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes[] calldata calls // Calls to be made after receiving the flash loan
    ) public whenNotPaused {
        require(
            _originalSender == address(1),
            "GatewayV1: original sender already set"
        );

        _originalSender = msg.sender;

        // store the calls, they'll be executed in the 'receiveFlashloan' function later
        for (uint i = 0; i < calls.length; i++) {
            _storedCalls.push(calls[i]);
        }

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
            ""
        );

        // here, the flashloan have been successfully reimbursed otherwise it would have reverted

        // clear stored calls
        delete _storedCalls;
        // clear _originalSender
        _originalSender = address(1);
    }

    /// @notice Handles the receipt of a flash loan from balancer, executes stored calls, and repays the loan.
    /// @param tokens Array of ERC20 tokens received in the flash loan.
    /// @param amounts Array of amounts for each token received.
    /// @param feeAmounts Array of fee amounts for each token received.
    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory /*userData*/
    ) external whenNotPaused {
        require(
            msg.sender == balancerVault,
            "GatewayV1: sender is not balancer"
        );

        // ensure the originalSender is set (via the multicallWithBalancerFlashLoan function)
        require(
            _originalSender != address(1),
            "GatewayV1: original sender must be set"
        );

        // execute the storedCalls stored in the multicallWithBalancerFlashLoan function
        _executeCalls(_storedCalls);

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
    ) public whenNotPaused {
        require(
            _originalSender == address(1),
            "GatewayV1: original sender already set"
        );

        _originalSender = msg.sender;

        // after flashloan tokens are received, first calls are to pull collateral
        // tokens from the user to the gateway, e.g. consumePermit + consumeAllowance
        // or just consumeAllowance if the user has already approved the gateway
        for (uint256 i = 0; i < pullCollateralCalls.length; i++) {
            _storedCalls.push(pullCollateralCalls[i]);
        }

        // approve the term before borrow
        _storedCalls.push(
            abi.encodeWithSignature(
                "callExternal(address,bytes)",
                collateralToken,
                abi.encodeWithSignature(
                    "approve(address,uint256)",
                    term,
                    collateralAmount + flashloanCollateralAmount
                )
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
        _storedCalls.push(
            abi.encodeWithSignature(
                "callExternal(address,bytes)",
                term,
                abi.encodeWithSignature(
                    "borrowOnBehalf(uint256,uint256,address)",
                    creditToBorrow,
                    collateralAmount + flashloanCollateralAmount,
                    msg.sender
                )
            )
        );

        // pull borrowed credit to the gateway
        address _creditToken = LendingTerm(term).creditToken();
        _storedCalls.push(allowBorrowedCreditCall);
        _storedCalls.push(
            abi.encodeWithSignature(
                "consumeAllowance(address,uint256)",
                _creditToken,
                creditToBorrow
            )
        );

        // redeem credit tokens to pegTokens in the PSM
        _storedCalls.push(
            abi.encodeWithSignature(
                "callExternal(address,bytes)",
                _creditToken,
                abi.encodeWithSignature(
                    "approve(address,uint256)",
                    psm,
                    creditToBorrow
                )
            )
        );
        _storedCalls.push(
            abi.encodeWithSignature(
                "callExternal(address,bytes)",
                psm,
                abi.encodeWithSignature(
                    "redeem(address,uint256)",
                    address(this),
                    creditToBorrow
                )
            )
        );

        // swap pegTokens for collateralTokens in order to be able to repay the flashloan
        _storedCalls.push(
            abi.encodeWithSignature(
                "callExternal(address,bytes)",
                pegToken,
                abi.encodeWithSignature(
                    "approve(address,uint256)",
                    uniswapRouter,
                    pegTokenAmount
                )
            )
        );
        {
            address[] memory path = new address[](2);
            path[0] = address(pegToken);
            path[1] = address(collateralToken);
            _storedCalls.push(
                abi.encodeWithSignature(
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
            ""
        );

        // here, the flashloan have been successfully reimbursed otherwise it would have reverted

        // clear stored calls
        delete _storedCalls;
        // clear _originalSender
        _originalSender = address(1);
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
    ) public whenNotPaused {
        require(
            _originalSender == address(1),
            "GatewayV1: original sender already set"
        );

        _originalSender = msg.sender;

        // compute amount of pegTokens needed to cover the debt
        uint256 debt = LendingTerm(term).getLoanDebt(loanId);
        uint256 flashloanPegTokenAmount = SimplePSM(psm).getRedeemAmountOut(
            debt
        ) + 1;

        // approve the psm & mint creditTokens
        _storedCalls.push(
            abi.encodeWithSignature(
                "callExternal(address,bytes)",
                pegToken,
                abi.encodeWithSignature(
                    "approve(address,uint256)",
                    psm,
                    flashloanPegTokenAmount
                )
            )
        );
        _storedCalls.push(
            abi.encodeWithSignature(
                "callExternal(address,bytes)",
                psm,
                abi.encodeWithSignature(
                    "mint(address,uint256)",
                    address(this),
                    flashloanPegTokenAmount
                )
            )
        );

        // repay the loan
        address _creditToken = LendingTerm(term).creditToken();
        _storedCalls.push(
            abi.encodeWithSignature(
                "callExternal(address,bytes)",
                _creditToken,
                abi.encodeWithSignature("approve(address,uint256)", term, debt)
            )
        );
        _storedCalls.push(
            abi.encodeWithSignature(
                "callExternal(address,bytes)",
                term,
                abi.encodeWithSignature("repay(bytes32)", loanId)
            )
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
        _storedCalls.push(allowCollateralTokenCall);
        _storedCalls.push(
            abi.encodeWithSignature(
                "consumeAllowance(address,uint256)",
                collateralToken,
                collateralTokenAmount
            )
        );

        // swap {collateralTokenAmount} collateralTokens to {flashloanPegTokenAmount} pegTokens
        _storedCalls.push(
            abi.encodeWithSignature(
                "callExternal(address,bytes)",
                collateralToken,
                abi.encodeWithSignature(
                    "approve(address,uint256)",
                    uniswapRouter,
                    collateralTokenAmount
                )
            )
        );
        {
            address[] memory path = new address[](2);
            path[0] = address(collateralToken);
            path[1] = address(pegToken);
            _storedCalls.push(
                abi.encodeWithSignature(
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
            ""
        );

        // here, the flashloan have been successfully reimbursed otherwise it would have reverted

        // clear stored calls
        delete _storedCalls;
        // clear _originalSender
        _originalSender = address(1);
    }

    /// @notice bid in an auction with a balancer flashloan.
    /// Example flow :
    /// - flashloan USDC from Balancer
    /// - mint gUSDC in PSM
    /// - approve gUSDC on the LendingTerm
    /// - bid in the auction
    /// - swap sDAI to USDC on Uniswap
    /// - repay USDC flashloan
    /// Slippage protection of minPegTokenProfit during swap to ensure auction bid profitability
    /// @dev up to 1e12 gUSDC might be left in the gateway after execution (<0.000001$).
    function bidWithBalancerFlashLoan(
        bytes32 loanId,
        address term,
        address psm,
        address uniswapRouter,
        address collateralToken,
        address pegToken,
        uint256 minPegTokenProfit
    ) public whenNotPaused returns (uint256) {
        require(
            _originalSender == address(1),
            "GatewayV1: original sender already set"
        );

        _originalSender = msg.sender;

        // compute amount of pegTokens needed to cover the debt
        address _auctionHouse = LendingTerm(term).auctionHouse();
        (uint256 collateralReceived, uint256 creditAsked) = AuctionHouse(
            _auctionHouse
        ).getBidDetail(loanId);
        uint256 flashloanPegTokenAmount = SimplePSM(psm).getRedeemAmountOut(
            creditAsked
        ) + 1;

        // approve the psm & mint creditTokens
        _storedCalls.push(
            abi.encodeWithSignature(
                "callExternal(address,bytes)",
                pegToken,
                abi.encodeWithSignature(
                    "approve(address,uint256)",
                    psm,
                    flashloanPegTokenAmount
                )
            )
        );
        _storedCalls.push(
            abi.encodeWithSignature(
                "callExternal(address,bytes)",
                psm,
                abi.encodeWithSignature(
                    "mint(address,uint256)",
                    address(this),
                    flashloanPegTokenAmount
                )
            )
        );

        // bid in auction
        address _creditToken = LendingTerm(term).creditToken();
        _storedCalls.push(
            abi.encodeWithSignature(
                "callExternal(address,bytes)",
                _creditToken,
                abi.encodeWithSignature(
                    "approve(address,uint256)",
                    term,
                    creditAsked
                )
            )
        );
        _storedCalls.push(
            abi.encodeWithSignature(
                "callExternal(address,bytes)",
                _auctionHouse,
                abi.encodeWithSignature("bid(bytes32)", loanId)
            )
        );

        // swap received collateralTokens to pegTokens
        _storedCalls.push(
            abi.encodeWithSignature(
                "callExternal(address,bytes)",
                collateralToken,
                abi.encodeWithSignature(
                    "approve(address,uint256)",
                    uniswapRouter,
                    collateralReceived
                )
            )
        );
        {
            address[] memory path = new address[](2);
            path[0] = address(collateralToken);
            path[1] = address(pegToken);
            _storedCalls.push(
                abi.encodeWithSignature(
                    "callExternal(address,bytes)",
                    uniswapRouter,
                    abi.encodeWithSignature(
                        "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
                        collateralReceived, // amount in
                        0, // amount out min
                        path, // path collateralToken->pegToken
                        address(this), // to
                        uint256(block.timestamp + 1) // deadline
                    )
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
            ""
        );

        // here, the flashloan have been successfully reimbursed otherwise it would have reverted

        // send surplus pegTokens to msg.sender
        uint256 pegTokenBalance = IERC20(pegToken).balanceOf(address(this));
        require(
            pegTokenBalance > minPegTokenProfit,
            "GatewayV1: profit too low"
        );
        IERC20(pegToken).transfer(msg.sender, pegTokenBalance);

        // clear stored calls
        delete _storedCalls;
        // clear _originalSender
        _originalSender = address(1);

        return pegTokenBalance;
    }
}
