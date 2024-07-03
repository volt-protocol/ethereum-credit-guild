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

/// @title ECG Gateway V1
/// @notice Gateway to interract via multicall with the ECG
/// Owner can select which calls are allowed
/// @custom:feature flashloan from balancer vault
contract GatewayV1 is Gateway {
    /// @notice Address of the Balancer Vault, used for initiating flash loans.
    address public immutable balancerVault =
        0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    constructor(address _guildTokenAddress) Gateway(_guildTokenAddress) {}

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
    /// @param afterReceiveCall encoded calls to be made after receiving the flashloaned token(s)
    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory afterReceiveCall
    ) external afterEntry {
        require(
            msg.sender == balancerVault,
            "GatewayV1: sender is not balancer"
        );

        (bool success, bytes memory result) = address(this).call(
            afterReceiveCall
        );
        if (!success) {
            _getRevertMsg(result);
        }

        // Transfer back the required amounts to the Balancer Vault
        for (uint256 i = 0; i < tokens.length; i++) {
            tokens[i].transfer(balancerVault, amounts[i] + feeAmounts[i]);
        }
    }

    /// @notice input for borrowWithBalancerFlashLoan
    /// @param term the lending term to borrow from
    /// @param psm the PSM to redeem the borrowed creditToken
    /// @param collateralToken the collateral token
    /// @param pegToken the peg token
    /// @param flashloanPegTokenAmount the amount of peg tokens to flashloan from Balancer
    /// @param minCollateralToReceive the min amount of collateral token to receive after the swap
    /// @param borrowAmount the amount of credit to borrow
    /// @param pullCollateralCalls the calls to make to pull the collateral tokens from the user to the gateway. either consumePermit + consumeAllowance or just consumeAllowance
    /// @param consumePermitBorrowedCreditCall the call to make to consume the allowance of credit tokens received by the user
    /// @param routerAddress the address of the router to swap the peg tokens to the collateral tokens
    /// @param routerCallData the call data to make to swap the peg tokens to the collateral tokens
    struct BorrowWithBalancerFlashLoanInput {
        address term;
        address psm;
        address collateralToken;
        address pegToken;
        address flashloanedToken;
        uint256 flashloanAmount;
        uint256 minCollateralToReceive;
        uint256 borrowAmount;
        bytes[] pullCollateralCalls;
        bytes consumePermitBorrowedCreditCall;
        address routerAddress;
        bytes routerCallData;
        address routerAddressToFlashloanedToken;
        bytes routerCallDataToFlashloanedToken;
    }

    /// @notice execute a borrow with a balancer flashloan
    /// borrow with flashloan flow:
    /// - flashloan {pegToken} from Balancer
    /// - swap {pegToken} obtained from Balancer to {collateralToken}, using {routerAddress} and {routerCallData}
    /// - pull user {collateralToken} from user to the Gateway
    /// - borrow on behalf {creditToken} from the term, with {collateralToken + flashloanCollateralToken} collateral
    /// - pull the {creditToken} borrowed to the Gateway
    /// - Redeem {creditToken} for {pegToken} in the PSM
    /// - repay {pegToken} flashloan
    /// - send remaining {pegToken} to the user if any
    function borrowWithBalancerFlashLoan(
        BorrowWithBalancerFlashLoanInput memory inputs
    ) public entryPoint whenNotPaused {
        // Initiate the flash loan
        // the balancer vault will call receiveFlashloan function on this contract before returning
        IERC20[] memory ierc20Tokens = new IERC20[](1);
        ierc20Tokens[0] = IERC20(inputs.flashloanedToken);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = inputs.flashloanAmount;
        IBalancerFlashLoan(balancerVault).flashLoan(
            address(this),
            ierc20Tokens,
            amounts,
            abi.encodeWithSignature(
                "borrowWithBalancerFlashLoanAfterReceive((address,address,address,address,address,uint256,uint256,uint256,bytes[],bytes,address,bytes,address,bytes))",
                inputs
            )
        );

        // here, the flashloan have been successfully reimbursed otherwise it would have reverted
        // we can sweep the remaining pegToken and flashloaned tokens (if any) to the user
        sweep(inputs.pegToken);
        sweep(inputs.flashloanedToken);
    }

    /// @notice execute a borrow with a balancer flashloan after receiving the flashloaned tokens
    /// see borrowWithBalancerFlashLoanV2 for details
    function borrowWithBalancerFlashLoanAfterReceive(
        BorrowWithBalancerFlashLoanInput memory inputs
    ) public afterEntry {
        // approve the swap router to swap the {flashloanedToken} for {collateralToken}
        callExternal(
            inputs.flashloanedToken,
            abi.encodeWithSignature(
                "approve(address,uint256)",
                inputs.routerAddress,
                inputs.flashloanAmount
            )
        );
        // then we swap the {flashloanedToken} to the {collateralToken} using the router
        callExternal(inputs.routerAddress, inputs.routerCallData);

        // check we received enoug collateral token
        require(
            IERC20(inputs.collateralToken).balanceOf(address(this)) >=
                inputs.minCollateralToReceive,
            "GatewayV1: not enough collateral received from swap"
        );

        // execute calls to pull collateral tokens from the user to the gateway,
        // e.g. consumePermit + consumeAllowance
        // or just consumeAllowance if the user has already approved the gateway
        _executeCalls(inputs.pullCollateralCalls);

        // this is the collateral amount from the user + flashloaned swap result
        uint256 totalCollateralAmount = IERC20(inputs.collateralToken)
            .balanceOf(address(this));
        // approve the term before borrow
        callExternal(
            inputs.collateralToken,
            abi.encodeWithSignature(
                "approve(address,uint256)",
                inputs.term,
                totalCollateralAmount
            )
        );

        // borrow borrowAmount on behalf of the original sender
        callExternal(
            inputs.term,
            abi.encodeWithSignature(
                "borrowOnBehalf(uint256,uint256,address)",
                inputs.borrowAmount,
                totalCollateralAmount,
                _originalSender
            )
        );

        address creditToken = LendingTerm(inputs.term).creditToken();
        // pull borrowed credit to the gateway
        // consume the permit
        (bool success, ) = address(this).call(
            inputs.consumePermitBorrowedCreditCall
        );
        require(
            success,
            "GatewayV1: consumePermitBorrowedCreditCall calls failed"
        );
        // consume allowance of the credit token
        consumeAllowance(creditToken, inputs.borrowAmount);

        // redeem credit tokens to pegTokens in the PSM
        callExternal(
            creditToken,
            abi.encodeWithSignature(
                "approve(address,uint256)",
                inputs.psm,
                inputs.borrowAmount
            )
        );

        callExternal(
            inputs.psm,
            abi.encodeWithSignature(
                "redeem(address,uint256)",
                address(this),
                inputs.borrowAmount
            )
        );

        // if a router address is provided in inputs.routerAddressToFlashloanedToken, we swap the received pegToken amount to the flashloaned token
        // this is not always used, for example when the flashloaned token is the peg token, this is useless
        if (inputs.routerAddressToFlashloanedToken != address(0)) {
            callExternal(
                inputs.pegToken,
                abi.encodeWithSignature(
                    "approve(address,uint256)",
                    inputs.routerAddressToFlashloanedToken,
                    IERC20(inputs.pegToken).balanceOf(address(this))
                )
            );
            callExternal(
                inputs.routerAddressToFlashloanedToken,
                inputs.routerCallDataToFlashloanedToken
            );
        }

        require(
            IERC20(inputs.flashloanedToken).balanceOf(address(this)) >=
                inputs.flashloanAmount,
            "GatewayV1: flashloan token balance too low to reimburse flashloan"
        );
    }

    /// @notice input for repayWithBalancerFlashLoan
    struct RepayWithBalancerFlashLoanInput {
        bytes32 loanId;
        address term;
        address psm;
        address collateralToken;
        address pegToken;
        uint256 minCollateralRemaining;
        bytes[] pullCollateralCalls;
        address routerAddress;
        bytes routerCallData;
    }

    /// @notice execute a repay with a balancer flashloan.
    /// Example flow :
    /// - flashloan {pegToken} from balancer
    /// - mint {creditToken} from PSM
    /// - repay the loan and get {collateralToken}
    /// - pull {collateralToken} from user to gateway
    /// - swap {collateralToken} to {pegToken} using {routerAddress} and {routerCallData}
    /// - reimburse {pegToken} flashloan
    /// - check remaining collateral is >= minCollateralRemaining
    /// - send remaining {collateralToken} and {pegToken} to the user
    function repayWithBalancerFlashLoan(
        RepayWithBalancerFlashLoanInput memory inputs
    ) public entryPoint whenNotPaused {
        // compute amount of pegTokens needed to cover the debt
        uint256 debt = LendingTerm(inputs.term).getLoanDebt(inputs.loanId);
        uint256 flashloanPegTokenAmount = SimplePSM(inputs.psm)
            .getRedeemAmountOut(debt) + 1;

        // Initiate the flash loan
        // the balancer vault will call receiveFlashloan function on this contract before returning
        IERC20[] memory ierc20Tokens = new IERC20[](1);
        ierc20Tokens[0] = IERC20(inputs.pegToken);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = flashloanPegTokenAmount;
        IBalancerFlashLoan(balancerVault).flashLoan(
            address(this),
            ierc20Tokens,
            amounts,
            abi.encodeWithSignature(
                "repayWithBalancerFlashLoanAfterReceive((bytes32,address,address,address,address,uint256,bytes[],address,bytes),uint256,uint256)",
                inputs,
                debt,
                flashloanPegTokenAmount
            )
        );

        // here, the flashloan have been successfully reimbursed otherwise it would have reverted
        // we can sweep collateralToken and the remaining pegToken (if any) to the user
        sweep(inputs.collateralToken);
        sweep(inputs.pegToken);
    }

    function repayWithBalancerFlashLoanAfterReceive(
        RepayWithBalancerFlashLoanInput memory inputs,
        uint256 debt,
        uint256 flashloanPegTokenAmount
    ) public afterEntry {
        // approve the psm & mint creditTokens
        callExternal(
            inputs.pegToken,
            abi.encodeWithSignature(
                "approve(address,uint256)",
                inputs.psm,
                flashloanPegTokenAmount
            )
        );

        callExternal(
            inputs.psm,
            abi.encodeWithSignature(
                "mint(address,uint256)",
                address(this),
                flashloanPegTokenAmount
            )
        );

        // repay the loan
        address _creditToken = LendingTerm(inputs.term).creditToken();

        callExternal(
            _creditToken,
            abi.encodeWithSignature(
                "approve(address,uint256)",
                inputs.term,
                debt
            )
        );

        callExternal(
            inputs.term,
            abi.encodeWithSignature("repay(bytes32)", inputs.loanId)
        );

        // execute calls to pull collateral tokens from the user to the gateway,
        // e.g. consumePermit + consumeAllowance
        // or just consumeAllowance if the user has already approved the gateway
        // this is done because the lending term is sending the collateral to the borrower
        // when repaying, not the gateway. So the gateway needs to pull the collateral back from the
        // user to itself
        _executeCalls(inputs.pullCollateralCalls);

        /// - swap {collateralToken} to {pegToken} using {routerAddress} and {routerCallData}
        // approve the swap router to swap the {collateralToken} for {pegToken}
        callExternal(
            inputs.collateralToken,
            abi.encodeWithSignature(
                "approve(address,uint256)",
                inputs.routerAddress,
                IERC20(inputs.collateralToken).balanceOf(address(this))
            )
        );

        callExternal(inputs.routerAddress, inputs.routerCallData);

        require(
            IERC20(inputs.collateralToken).balanceOf(address(this)) >=
                inputs.minCollateralRemaining,
            "GatewayV1: collateral token balance too low"
        );

        require(
            IERC20(inputs.pegToken).balanceOf(address(this)) >=
                flashloanPegTokenAmount,
            "GatewayV1: pegToken balance too low to reimburse flashloan"
        );
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

    /// @notice send the tokens to the original sender, ensuring that at least minPegTokenProfit pegTokens are sent
    /// @param minPegTokenProfit the minimum amount of pegTokens to send to the original sender
    /// @param pegToken the peg token
    /// @param creditToken the credit token
    /// @param collateralToken the collateral token
    /// @return pegTokenBalance the amount of pegTokens sent to the original sender
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
