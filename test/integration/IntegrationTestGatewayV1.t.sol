// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {ProfitManager} from "@src/governance/ProfitManager.sol";
import {GatewayV1} from "@src/gateway/GatewayV1.sol";
import {PostProposalCheckFixture} from "@test/integration/PostProposalCheckFixture.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {console} from "@forge-std/console.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";

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

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);

    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external view returns (uint256[] memory amounts);
}

interface IWeightedPoolFactory {
    function create(
        string memory name,
        string memory symbol,
        address[] memory tokens,
        uint256[] memory normalizedWeights,
        address[] memory rateProviders,
        uint256 swapFeePercentage,
        address owner,
        bytes32 salt
    ) external returns (address);
}

interface IVault {
    function joinPool(
        bytes32 poolId,
        address sender,
        address recipient,
        JoinPoolRequest memory request
    ) external payable;
}

struct JoinPoolRequest {
    address[] assets;
    uint256[] maxAmountsIn;
    bytes userData;
    bool fromInternalBalance;
}

interface IPool {
    function getPoolId() external returns (bytes32);
}

struct PermitData {
    uint8 v;
    bytes32 r;
    bytes32 s;
    uint256 deadline;
}

/// @notice execute a integration test with the account implementation for leveraging a position via flashloan
/// use like that: forge test --match-contract IntegrationTestGatewayV1 --fork-url {RPC_URL} -vv
contract IntegrationTestGatewayV1 is PostProposalCheckFixture {
    address public UNISWAPV2_ROUTER_ADDR = address(0);
    GatewayV1 public gatewayv1 = new GatewayV1(address(guild));
    IWeightedPoolFactory public balancerFactory =
        IWeightedPoolFactory(0x7920BFa1b2041911b354747CA7A6cDD2dfC50Cfd);

    uint256 public alice_private_key = 0x42424242421111111;
    address public alice = vm.addr(alice_private_key);

    function deployGatewayV1() public {
        gatewayv1 = new GatewayV1(address(guild));

        gatewayv1.allowCall(
            address(collateralToken),
            getSelector("approve(address,uint256)"),
            true
        );
        gatewayv1.allowCall(
            address(usdc),
            getSelector("approve(address,uint256)"),
            true
        );
        gatewayv1.allowCall(
            address(credit),
            getSelector("approve(address,uint256)"),
            true
        );

        // allow borrowOnBehalf
        gatewayv1.allowCall(
            address(term),
            getSelector("borrowOnBehalf(uint256,uint256,address)"),
            true
        );

        // allow repay / partial repay
        gatewayv1.allowCall(
            address(term),
            getSelector("partialRepay(bytes32,uint256)"),
            true
        );
        gatewayv1.allowCall(address(term), getSelector("repay(bytes32)"), true);

        // allow redeem and mint on the psm
        gatewayv1.allowCall(
            address(psm),
            getSelector("redeem(address,uint256)"),
            true
        );
        gatewayv1.allowCall(
            address(psm),
            getSelector("mint(address,uint256)"),
            true
        );

        // allow two types of swap on the uniswap router
        gatewayv1.allowCall(
            UNISWAPV2_ROUTER_ADDR,
            getSelector(
                "swapTokensForExactTokens(uint256,uint256,address[],address,uint256)"
            ),
            true
        );
        gatewayv1.allowCall(
            UNISWAPV2_ROUTER_ADDR,
            getSelector(
                "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)"
            ),
            true
        );

        // allow bids on the auction house
        gatewayv1.allowCall(
            address(auctionHouse),
            getSelector("bid(bytes32)"),
            true
        );
    }

    function getSelector(bytes memory f) public pure returns (bytes4) {
        return bytes4(keccak256(f));
    }

    function deployUniv2Pool() public {
        // create a univ2 pool with 10M/10M liquidity (usdc/collateral)
        ERC20(usdc).approve(UNISWAPV2_ROUTER_ADDR, 10_000_000e6);
        ERC20(collateralToken).approve(UNISWAPV2_ROUTER_ADDR, 10_000_000e18);
        IUniswapRouter(UNISWAPV2_ROUTER_ADDR).addLiquidity(
            address(usdc),
            address(collateralToken),
            10_000_000e6,
            10_000_000e18,
            10_000_000e6,
            10_000_000e18,
            teamMultisig,
            block.timestamp + 1000
        );
    }

    function deployBalancerPool() public {
        string memory nameSymbol = "50USDC-50Collateral";
        address token0 = address(usdc);
        uint256 amount0 = 10_000_000e6;
        address token1 = address(collateralToken);
        uint256 amount1 = 10_000_000e18;
        address[] memory tokens = new address[](2);
        tokens[0] = token0;
        tokens[1] = token1;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount0;
        amounts[1] = amount1;

        uint256[] memory normalizedWeights = new uint256[](2);
        normalizedWeights[0] = 0.5e18;
        normalizedWeights[1] = 0.5e18;
        address[] memory rateProviders = new address[](2);
        rateProviders[0] = 0x0000000000000000000000000000000000000000;
        rateProviders[1] = 0x0000000000000000000000000000000000000000;
        uint256 swapFeePercentage = 0.003e18;
        bytes32 salt = keccak256(abi.encodePacked(block.timestamp, msg.sender));
        address poolAddress = balancerFactory.create(
            nameSymbol,
            nameSymbol,
            tokens,
            normalizedWeights,
            rateProviders,
            swapFeePercentage,
            teamMultisig,
            salt
        );

        bytes32 poolId = IPool(poolAddress).getPoolId();

        ERC20(token0).approve(gatewayv1.balancerVault(), amount0);
        ERC20(token1).approve(gatewayv1.balancerVault(), amount1);

        // this encodes the data for the INIT join
        bytes memory dataEncoded = abi.encode(uint256(0), amounts);

        JoinPoolRequest memory request = JoinPoolRequest({
            assets: tokens,
            maxAmountsIn: amounts,
            userData: dataEncoded,
            fromInternalBalance: false
        });

        IVault(gatewayv1.balancerVault()).joinPool(
            poolId,
            teamMultisig,
            teamMultisig,
            request
        );
    }

    function getPermitData(
        ERC20Permit token,
        uint256 amount,
        address to,
        address from,
        uint256 fromPrivateKey
    ) public view returns (PermitData memory permitData) {
        uint256 deadline = block.timestamp + 100;
        // sign permit message valid for 10s
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                ),
                from,
                to,
                amount,
                token.nonces(from),
                deadline
            )
        );

        bytes32 digest = ECDSA.toTypedDataHash(
            token.DOMAIN_SEPARATOR(),
            structHash
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(fromPrivateKey, digest);

        return PermitData({v: v, r: r, s: s, deadline: deadline});
    }

    function getBorrowAmountFromCollateralAmount(
        uint256 collateralAmount
    ) public view returns (uint256 borrowAmount) {
        uint256 creditMultiplier = ProfitManager(
            LendingTerm(term).profitManager()
        ).creditMultiplier();
        LendingTerm.LendingTermParams memory params = LendingTerm(term)
            .getParameters();
        borrowAmount =
            (collateralAmount * params.maxDebtPerCollateralToken) /
            creditMultiplier;
    }

    function setUp() public virtual override {
        super.setUp();

        vm.prank(getAddr("DAO_TIMELOCK"));
        core.grantRole(CoreRoles.GUILD_MINTER, userOne);
        vm.startPrank(userOne);
        guild.mint(userOne, 1_000_000e18);
        guild.incrementGauge(address(term), 1_000_000e18);
        vm.stopPrank();

        vm.label(alice, "Alice");
        // uniswap router for mainnet or sepolia
        if (block.chainid == 1) {
            UNISWAPV2_ROUTER_ADDR = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
        } else if (block.chainid == 11155111) {
            UNISWAPV2_ROUTER_ADDR = 0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008;
        } else if (block.chainid == 42161) {
            UNISWAPV2_ROUTER_ADDR = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
        }
        vm.label(UNISWAPV2_ROUTER_ADDR, "Uniswap_Router");
        vm.label(address(usdc), "USDC");
        vm.label(address(collateralToken), "COLLATERAL_TOKEN");

        // give tokens to the team multisig
        dealToken(address(usdc), teamMultisig, 100_000_000e6);
        dealToken(address(collateralToken), teamMultisig, 100_000_000e18);
        vm.startPrank(teamMultisig);
        deployGatewayV1();
        deployUniv2Pool();
        deployBalancerPool();
        vm.stopPrank();
    }

    function testSetUp() public {
        assertTrue(UNISWAPV2_ROUTER_ADDR != address(0));
        assertEq(usdc.balanceOf(alice), 0);
    }

    // multicall scenario with permit
    function testGatewayLoanWithPermit() public {
        // alice will get a loan with a permit
        dealToken(address(collateralToken), alice, 1000e18);
        uint256 collateralAmount = 100e18; // 100 collateral
        uint256 debtAmount = getBorrowAmountFromCollateralAmount(
            collateralAmount
        );
        // sign permit collateral -> Gateway
        PermitData memory permitCollateral = getPermitData(
            ERC20Permit(collateralToken),
            collateralAmount,
            address(gatewayv1),
            alice,
            alice_private_key
        );
        // sign permit gUSDC -> gateway
        PermitData memory permitDataCredit = getPermitData(
            ERC20Permit(credit),
            debtAmount,
            address(gatewayv1),
            alice,
            alice_private_key
        );

        bytes[] memory calls = new bytes[](8);
        calls[0] = abi.encodeWithSignature(
            "consumePermit(address,uint256,uint256,uint8,bytes32,bytes32)",
            collateralToken,
            collateralAmount,
            permitCollateral.deadline,
            permitCollateral.v,
            permitCollateral.r,
            permitCollateral.s
        );

        calls[1] = abi.encodeWithSignature(
            "consumeAllowance(address,uint256)",
            collateralToken,
            collateralAmount
        );

        calls[2] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            collateralToken,
            abi.encodeWithSignature(
                "approve(address,uint256)",
                term,
                collateralAmount
            )
        );

        calls[3] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            term,
            abi.encodeWithSignature(
                "borrowOnBehalf(uint256,uint256,address)",
                debtAmount,
                collateralAmount,
                alice
            )
        );

        calls[4] = abi.encodeWithSignature(
            "consumePermit(address,uint256,uint256,uint8,bytes32,bytes32)",
            credit,
            debtAmount,
            permitDataCredit.deadline,
            permitDataCredit.v,
            permitDataCredit.r,
            permitDataCredit.s
        );

        calls[5] = abi.encodeWithSignature(
            "consumeAllowance(address,uint256)",
            credit,
            debtAmount
        );

        calls[6] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            credit,
            abi.encodeWithSignature("approve(address,uint256)", psm, debtAmount)
        );

        calls[7] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            psm,
            abi.encodeWithSignature(
                "redeem(address,uint256)",
                alice,
                debtAmount
            )
        );

        // call multicall on the gateway
        vm.prank(alice);
        gatewayv1.multicall(calls);

        // alice should now have 100 USDC after creating a loan and redeeming the
        // credits to USDC via the psm
        // at most 1 wei of error
        assertGt(usdc.balanceOf(alice), 100e6 - 2);
    }

    // multicall scenario with without permit
    function testGatewayLoanWithoutPermit() public {
        // alice will get a loan with a permit
        dealToken(address(collateralToken), alice, 1000e18);
        uint256 collateralAmount = 100e18; // 100 collateral
        uint256 debtAmount = getBorrowAmountFromCollateralAmount(
            collateralAmount
        );

        vm.startPrank(alice);
        collateralToken.approve(address(gatewayv1), collateralAmount);
        credit.approve(address(gatewayv1), debtAmount);
        vm.stopPrank();

        bytes[] memory calls = new bytes[](6);
        calls[0] = abi.encodeWithSignature(
            "consumeAllowance(address,uint256)",
            collateralToken,
            collateralAmount
        );

        calls[1] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            collateralToken,
            abi.encodeWithSignature(
                "approve(address,uint256)",
                term,
                collateralAmount
            )
        );

        calls[2] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            term,
            abi.encodeWithSignature(
                "borrowOnBehalf(uint256,uint256,address)",
                debtAmount,
                collateralAmount,
                alice
            )
        );

        calls[3] = abi.encodeWithSignature(
            "consumeAllowance(address,uint256)",
            credit,
            debtAmount
        );

        calls[4] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            credit,
            abi.encodeWithSignature("approve(address,uint256)", psm, debtAmount)
        );

        calls[5] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            psm,
            abi.encodeWithSignature(
                "redeem(address,uint256)",
                alice,
                debtAmount
            )
        );

        // call multicall on the gateway
        vm.prank(alice);
        gatewayv1.multicall(calls);

        // alice should now have 100 USDC after creating a loan and redeeming the
        // credits to USDC via the psm
        // at most 1 wei of error
        assertGt(usdc.balanceOf(alice), 100e6 - 2);
    }

    // multicall with flashloan
    function testGatewayLoanWithBalancerFlasloan() public {
        // alice will get a loan with a permit
        dealToken(address(collateralToken), alice, 1000e18);
        uint256 collateralAmount = 25e18; // 25 collateral
        uint256 flashloanAmount = 75e18; // 75 flashloan collateral
        uint256 debtAmount = getBorrowAmountFromCollateralAmount(
            collateralAmount + flashloanAmount
        );
        // sign permit collateral -> Gateway
        PermitData memory permitCollateral = getPermitData(
            ERC20Permit(collateralToken),
            collateralAmount,
            address(gatewayv1),
            alice,
            alice_private_key
        );
        // sign permit gUSDC -> gateway
        PermitData memory permitDataCredit = getPermitData(
            ERC20Permit(credit),
            debtAmount,
            address(gatewayv1),
            alice,
            alice_private_key
        );

        bytes[] memory calls = new bytes[](12);
        calls[0] = abi.encodeWithSignature(
            "consumePermit(address,uint256,uint256,uint8,bytes32,bytes32)",
            collateralToken,
            collateralAmount,
            permitCollateral.deadline,
            permitCollateral.v,
            permitCollateral.r,
            permitCollateral.s
        );

        calls[1] = abi.encodeWithSignature(
            "consumeAllowance(address,uint256)",
            collateralToken,
            collateralAmount
        );

        calls[2] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            collateralToken,
            abi.encodeWithSignature(
                "approve(address,uint256)",
                term,
                collateralAmount + flashloanAmount
            )
        );

        calls[3] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            term,
            abi.encodeWithSignature(
                "borrowOnBehalf(uint256,uint256,address)",
                debtAmount,
                collateralAmount + flashloanAmount,
                alice
            )
        );

        calls[4] = abi.encodeWithSignature(
            "consumePermit(address,uint256,uint256,uint8,bytes32,bytes32)",
            credit,
            debtAmount,
            permitDataCredit.deadline,
            permitDataCredit.v,
            permitDataCredit.r,
            permitDataCredit.s
        );

        calls[5] = abi.encodeWithSignature(
            "consumeAllowance(address,uint256)",
            credit,
            debtAmount
        );

        calls[6] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            credit,
            abi.encodeWithSignature("approve(address,uint256)", psm, debtAmount)
        );

        // redeem credit token => USDC to the gateway (not the user !!)
        calls[7] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            psm,
            abi.encodeWithSignature(
                "redeem(address,uint256)",
                address(gatewayv1),
                debtAmount
            )
        );

        // compute the amount USDC we should have received
        uint256 amountUSDC = psm.getRedeemAmountOut(debtAmount);

        // here we have the full value in USDC after redeeming, need to change to collateral
        // doing a swap on the univ2 pool
        // approve uniswap router
        calls[8] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            usdc,
            abi.encodeWithSignature(
                "approve(address,uint256)",
                UNISWAPV2_ROUTER_ADDR,
                amountUSDC
            )
        );

        // perform the swap
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(collateralToken);
        calls[9] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            UNISWAPV2_ROUTER_ADDR,
            abi.encodeWithSignature(
                "swapTokensForExactTokens(uint256,uint256,address[],address,uint256)",
                flashloanAmount, // amount out
                amountUSDC, // amount in max
                path, // path USDC->collateral
                address(gatewayv1), // to
                uint256(block.timestamp + 3600) // deadline
            )
        );

        // reset approval on the uniswap router
        calls[10] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            usdc,
            abi.encodeWithSignature(
                "approve(address,uint256)",
                UNISWAPV2_ROUTER_ADDR,
                0
            )
        );

        // sweep any usdc from the gateway
        calls[11] = abi.encodeWithSignature("sweep(address)", usdc);

        // call multicall with flashloan on the gateway
        address[] memory flashLoanTokens = new address[](1);
        flashLoanTokens[0] = address(collateralToken);
        uint256[] memory flashloanAmounts = new uint256[](1);
        flashloanAmounts[0] = flashloanAmount;
        vm.prank(alice);
        gatewayv1.multicallWithBalancerFlashLoan(
            flashLoanTokens,
            flashloanAmounts,
            calls
        );

        // alice should now have a bit less than her starting collateral, redeemed to USDC
        // after the swap, so allow 5% diff
        assertLt(usdc.balanceOf(alice), 25e6);
        assertApproxEqRel(usdc.balanceOf(alice), 25e6, 0.05e18);
    }

    // borrow with flashloan
    function testBorrowWithBalancerFlashLoan() public {
        // alice will get a loan with a permit, 10x leverage on collateral
        uint256 collateralAmount = 1000e18;
        dealToken(address(collateralToken), alice, collateralAmount);
        uint256 flashloanPegTokenAmount = 9000e6;

        // encode the swap using uniswapv2 router
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(collateralToken);
        uint256[] memory amountsOut = IUniswapRouter(UNISWAPV2_ROUTER_ADDR)
            .getAmountsOut(flashloanPegTokenAmount, path);
        uint256 minCollateralToReceive = amountsOut[0];

        bytes memory routerCallData = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            flashloanPegTokenAmount, // amount in
            minCollateralToReceive, // amount out min
            path, // path collateralToken->pegToken
            address(gatewayv1), // to
            uint256(block.timestamp + 1)
        ); // deadline

        // sign permit collateral -> Gateway
        PermitData memory permitCollateral = getPermitData(
            ERC20Permit(collateralToken),
            collateralAmount,
            address(gatewayv1),
            alice,
            alice_private_key
        );

        // only borrow for the amount of collateral we received after swapping the flashloan
        // meaning the user collateral is added for overcollateralization
        uint256 borrowAmount = getBorrowAmountFromCollateralAmount(
            collateralAmount
        );

        // sign permit gUSDC -> gateway
        PermitData memory permitDataCredit = getPermitData(
            ERC20Permit(credit),
            borrowAmount,
            address(gatewayv1),
            alice,
            alice_private_key
        );

        bytes[] memory pullCollateralCalls = new bytes[](2);
        pullCollateralCalls[0] = abi.encodeWithSignature(
            "consumePermit(address,uint256,uint256,uint8,bytes32,bytes32)",
            collateralToken,
            collateralAmount,
            permitCollateral.deadline,
            permitCollateral.v,
            permitCollateral.r,
            permitCollateral.s
        );
        pullCollateralCalls[1] = abi.encodeWithSignature(
            "consumeAllowance(address,uint256)",
            collateralToken,
            collateralAmount
        );

        bytes memory consumePermitBorrowedCreditCall = abi.encodeWithSignature(
            "consumePermit(address,uint256,uint256,uint8,bytes32,bytes32)",
            credit,
            borrowAmount,
            permitDataCredit.deadline,
            permitDataCredit.v,
            permitDataCredit.r,
            permitDataCredit.s
        );

        // call borrowWithBalancerFlashLoan
        vm.prank(alice);
        gatewayv1.borrowWithBalancerFlashLoan(
            GatewayV1.BorrowWithBalancerFlashLoanInput(
                address(term),
                address(psm),
                address(collateralToken),
                address(usdc),
                flashloanPegTokenAmount,
                minCollateralToReceive,
                borrowAmount,
                pullCollateralCalls,
                consumePermitBorrowedCreditCall,
                UNISWAPV2_ROUTER_ADDR,
                routerCallData
            )
        );

        // check results
        bytes32 loanId = keccak256(
            abi.encode(alice, address(term), block.timestamp)
        );
        LendingTerm.Loan memory loan = LendingTerm(term).getLoan(loanId);

        assertEq(collateralToken.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(collateralToken.balanceOf(address(gatewayv1)), 0);
        assertEq(usdc.balanceOf(address(gatewayv1)), 0);
        assertEq(loan.collateralAmount, 10_000e18);
        assertEq(loan.borrowAmount, borrowAmount);
    }

    // repay with flashloan
    // function testRepayWithBalancerFlashLoan() public {
    //     testBorrowWithBalancerFlashLoan();
    //     bytes32 loanId = keccak256(
    //         abi.encode(alice, address(term), block.timestamp)
    //     );
    //     vm.warp(block.timestamp + 3 days);
    //     vm.roll(block.number + 1);

    //     uint256 collateralAmount = LendingTerm(term)
    //         .getLoan(loanId)
    //         .collateralAmount;
    //     uint256 maxCollateralSold = (collateralAmount * 95) / 100;

    //     // sign permit collateral -> Gateway
    //     PermitData memory permitCollateral = getPermitData(
    //         ERC20Permit(collateralToken),
    //         maxCollateralSold,
    //         address(gatewayv1),
    //         alice,
    //         alice_private_key
    //     );
    //     bytes memory allowCollateralTokenCall = abi.encodeWithSignature(
    //         "consumePermit(address,uint256,uint256,uint8,bytes32,bytes32)",
    //         collateralToken,
    //         maxCollateralSold,
    //         permitCollateral.deadline,
    //         permitCollateral.v,
    //         permitCollateral.r,
    //         permitCollateral.s
    //     );

    //     // call repayWithBalancerFlashLoan
    //     vm.prank(alice);
    //     gatewayv1.repayWithBalancerFlashLoan(
    //         loanId,
    //         address(term),
    //         address(psm),
    //         UNISWAPV2_ROUTER_ADDR,
    //         address(collateralToken),
    //         address(usdc),
    //         maxCollateralSold,
    //         allowCollateralTokenCall
    //     );

    //     assertGt(collateralToken.balanceOf(alice), 900e18);
    //     assertEq(usdc.balanceOf(alice), 0);
    //     assertLt(collateralToken.balanceOf(address(gatewayv1)), 1e13);
    //     assertLt(usdc.balanceOf(address(gatewayv1)), 1e7);
    // }

    // bid with flashloan
    function testBidWithBalancerFlashLoan() public {
        testBorrowWithBalancerFlashLoan();
        bytes32 loanId = keccak256(
            abi.encode(alice, address(term), block.timestamp)
        );

        // fast-forward time for loan to become insolvent
        uint256 collateralAmount = LendingTerm(term)
            .getLoan(loanId)
            .collateralAmount;
        uint256 loanDebt = LendingTerm(term).getLoanDebt(loanId);
        while (loanDebt < collateralAmount) {
            vm.warp(block.timestamp + 365 days);
            vm.roll(block.number + 1);
            loanDebt = LendingTerm(term).getLoanDebt(loanId);
        }

        // call loan
        term.call(loanId);

        // wait for a good time to bid, and bid
        uint256 profit = 0;
        uint256 timeStep = auctionHouse.auctionDuration() / 10 - 1;
        uint256 stop = block.timestamp + auctionHouse.auctionDuration();
        uint256 minProfit = 25e6; // min 25 USDC of profit

        while (profit == 0 && block.timestamp < stop) {
            (uint256 collateralReceived, ) = auctionHouse.getBidDetail(loanId);
            // encode the swap using uniswapv2 router
            address[] memory path = new address[](2);
            path[0] = address(collateralToken);
            path[1] = address(usdc);
            bytes memory swapData = abi.encodeWithSignature(
                "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
                collateralReceived, // amount in
                0, // amount out min
                path, // path collateralToken->pegToken
                address(gatewayv1), // to
                uint256(block.timestamp + 1)
            ); // deadline

            try
                gatewayv1.bidWithBalancerFlashLoan(
                    loanId,
                    address(term),
                    address(psm),
                    address(collateralToken),
                    address(usdc),
                    minProfit,
                    UNISWAPV2_ROUTER_ADDR,
                    swapData
                )
            returns (uint256 _profit) {
                profit = _profit;
            } catch {
                vm.warp(block.timestamp + timeStep);
                vm.roll(block.number + 1);
            }
        }

        assertGt(profit, minProfit);
        assertEq(usdc.balanceOf(address(this)), profit);
        assertEq(LendingTerm(term).getLoan(loanId).closeTime, block.timestamp);
    }
}
