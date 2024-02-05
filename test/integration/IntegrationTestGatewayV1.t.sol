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
    GatewayV1 public gatewayv1 = new GatewayV1();
    IWeightedPoolFactory public balancerFactory =
        IWeightedPoolFactory(0x7920BFa1b2041911b354747CA7A6cDD2dfC50Cfd);

    uint256 public alice_private_key = 0x42;
    address public alice = vm.addr(alice_private_key);

    function deployGatewayV1() public {
        gatewayv1 = new GatewayV1();

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

        console.log("balancer pool address: %s", poolAddress);

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
        console.log("creditMultiplier: %s", creditMultiplier);
        LendingTerm.LendingTermParams memory params = LendingTerm(term)
            .getParameters();
        borrowAmount =
            (collateralAmount * params.maxDebtPerCollateralToken) /
            creditMultiplier;
        console.log("borrowAmount: %s", borrowAmount);
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
        }

        // give tokens to the team multisig
        deal(address(usdc), teamMultisig, 100_000_000e6);
        deal(address(collateralToken), teamMultisig, 100_000_000e18);
        vm.startPrank(teamMultisig);
        deployGatewayV1();
        deployUniv2Pool();
        deployBalancerPool();
        vm.stopPrank();
    }

    function testSetUp() public {
        assertTrue(UNISWAPV2_ROUTER_ADDR != address(0));
    }

    // multicall scenario with permit
    function testLoanWithPermit() public {
        // alice will get a loan with a permit
        deal(address(collateralToken), alice, 1000e18);
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
        assertEq(usdc.balanceOf(alice), 100e6);
    }

    // multicall scenario with without permit

    // multicall with flashloan
}

//     // function setUpAccountFactory() public {
//     //     vm.startPrank(factoryOwner);
//     //     // deploy the factory
//     //     accountFactory = AccountFactory(new AccountFactory());
//     //     // deploy the account implementation
//     //     allowedImplementation = AccountImplementation(
//     //         new AccountImplementation()
//     //     );
//     //     // whitelist account implementation
//     //     accountFactory.allowImplementation(
//     //         address(allowedImplementation),
//     //         true
//     //     );
//     //     // allow approve on sDAI token
//     //     accountFactory.allowCall(
//     //         address(SDAI_TOKEN),
//     //         bytes4(keccak256("approve(address,uint256)")),
//     //         true
//     //     );
//     //     // allow approve on USDC token
//     //     accountFactory.allowCall(
//     //         address(USDC_TOKEN),
//     //         bytes4(keccak256("approve(address,uint256)")),
//     //         true
//     //     );
//     //     // allow borrow on CREDIT token
//     //     accountFactory.allowCall(
//     //         address(CREDIT_TOKEN),
//     //         bytes4(keccak256("approve(address,uint256)")),
//     //         true
//     //     );
//     //     // allow borrow on sDAI lending term
//     //     accountFactory.allowCall(
//     //         address(SDAI_TERM),
//     //         bytes4(keccak256("borrow(uint256,uint256)")),
//     //         true
//     //     );
//     //     // allow redeem on psm
//     //     accountFactory.allowCall(
//     //         address(psm),
//     //         bytes4(keccak256("redeem(address,uint256)")),
//     //         true
//     //     );
//     //     // allow swap on uniswap router
//     //     accountFactory.allowCall(
//     //         address(UNISWAP_ROUTER),
//     //         bytes4(
//     //             keccak256(
//     //                 "swapTokensForExactTokens(uint256,uint256,address[],address,uint256)"
//     //             )
//     //         ),
//     //         true
//     //     );
//     //     vm.stopPrank();
//     // }
//     // function labelUp() public {
//     //     vm.label(address(SDAI_TERM), "SDAI_TERM");
//     //     vm.label(address(GOVERNOR), "GOVERNOR");
//     //     vm.label(address(SDAI_TOKEN), "SDAI_TOKEN");
//     //     vm.label(address(USDC_TOKEN), "USDC_TOKEN");
//     //     vm.label(address(CREDIT_TOKEN), "CREDIT_TOKEN");
//     //     vm.label(address(alice), "alice");
//     //     vm.label(address(factoryOwner), "factoryOwner");
//     //     vm.label(address(psm), "psm");
//     //     vm.label(address(allowedImplementation), "allowedImplementation");
//     //     vm.label(address(alicesAccount), "alicesAccount");
//     //     vm.label(address(accountFactory), "accountFactory");
//     //     vm.label(address(UNISWAP_ROUTER), "UNISWAP_ROUTER");
//     // }
//     // // should test the following scenario with a balancer flashloan and the new multicall account feature:
//     // // - have an account with 10k sDAI
//     // // - flashloan 200k sDAI from balancer
//     // // - approve 210k sDAI to the lending term
//     // // - borrow with 210k sDAI collateral
//     // // - get X gUSDC
//     // // - PSM.redeem X gUSDC for Y USDC
//     // // - swap Y USDC for Z sDAI on uniswapv2
//     // // - reimburse balancer flashloan
//     // // REQUIREMENTS: have enough token in the balancer vault (for the flashloan) and a large enough liquidity in univ2 for the swap without too much slippage.
//     // function testFlashLoanWithBalancer() public {
//     //     // - have an account with 10k sDAI
//     //     vm.prank(GOVERNOR);
//     //     SDAI_TOKEN.mint(alice, 10_000e18);
//     //     assertEq(SDAI_TOKEN.balanceOf(alice), 10_000e18);
//     //     // alice will send 10k sDAI to her account
//     //     vm.prank(alice);
//     //     SDAI_TOKEN.transfer(address(alicesAccount), 10_000e18);
//     //     assertEq(SDAI_TOKEN.balanceOf(address(alicesAccount)), 10_000e18);
//     //     // - flashloan 200k sDAI from balancer
//     //     uint256 flashloanAmount = 200_000e18;
//     //     // this is done when calling the 'multicallWithBalancerFlashLoan' function on alice's Account
//     //     // compute the loanId that will be generated
//     //     bytes32 expectedLoanId = keccak256(
//     //         abi.encode(
//     //             address(alicesAccount),
//     //             address(SDAI_TERM),
//     //             block.timestamp
//     //         )
//     //     );
//     //     // now we will prepare the call list to be sent as the "postCalls" to the 'multicallWithBalancerFlashLoan' function
//     //     bytes[] memory postCalls = new bytes[](6);
//     //     // - approve 210k sDAI to the lending term, this will be the max
//     //     postCalls[0] = abi.encodeWithSignature(
//     //         "callExternal(address,bytes)",
//     //         address(SDAI_TOKEN),
//     //         abi.encodeWithSignature(
//     //             "approve(address,uint256)",
//     //             address(SDAI_TERM),
//     //             uint256(210_000e18)
//     //         )
//     //     );
//     //     // compute the borrowAmount and collateral amount
//     //     uint256 borrowAmount = getBorrowAmountFromCollateralAmount(210_000e18);
//     //     // - borrow with 210k sDAI collateral, get X gUSDC
//     //     postCalls[1] = abi.encodeWithSignature(
//     //         "callExternal(address,bytes)",
//     //         address(SDAI_TERM),
//     //         abi.encodeWithSignature(
//     //             "borrow(uint256,uint256)",
//     //             borrowAmount,
//     //             uint256(210_000e18)
//     //         )
//     //     );
//     //     // - PSM.redeem X gUSDC for Y USDC
//     //     // approve gUSDC from the PSM
//     //     postCalls[2] = abi.encodeWithSignature(
//     //         "callExternal(address,bytes)",
//     //         address(CREDIT_TOKEN),
//     //         abi.encodeWithSignature(
//     //             "approve(address,uint256)",
//     //             address(psm),
//     //             borrowAmount
//     //         )
//     //     );
//     //     // call redeem
//     //     postCalls[3] = abi.encodeWithSignature(
//     //         "callExternal(address,bytes)",
//     //         address(psm),
//     //         abi.encodeWithSignature(
//     //             "redeem(address,uint256)",
//     //             address(alicesAccount),
//     //             borrowAmount
//     //         )
//     //     );
//     //     // approve USDC spending by the uniswap router
//     //     postCalls[4] = abi.encodeWithSignature(
//     //         "callExternal(address,bytes)",
//     //         address(USDC_TOKEN),
//     //         abi.encodeWithSignature(
//     //             "approve(address,uint256)",
//     //             address(UNISWAP_ROUTER),
//     //             uint256(210_000e6)
//     //         )
//     //     );
//     //     address[] memory path = new address[](2);
//     //     path[0] = address(USDC_TOKEN);
//     //     path[1] = address(SDAI_TOKEN);
//     //     // - swap Y USDC for Z sDAI on uniswapv2
//     //     postCalls[5] = abi.encodeWithSignature(
//     //         "callExternal(address,bytes)",
//     //         address(UNISWAP_ROUTER),
//     //         abi.encodeWithSignature(
//     //             "swapTokensForExactTokens(uint256,uint256,address[],address,uint256)",
//     //             flashloanAmount, // amount out
//     //             uint256(210_000e6), // amount in max
//     //             path, // path USDC->SDAI
//     //             address(alicesAccount), // to
//     //             uint256(block.timestamp + 3600) // deadline
//     //         )
//     //     );
//     //     // - reimburse balancer flashloan
//     //     // automatically done by the account implementation
//     //     IERC20[] memory tokensArray = new IERC20[](1);
//     //     tokensArray[0] = IERC20(SDAI_TOKEN);
//     //     uint256[] memory amountsArray = new uint256[](1);
//     //     amountsArray[0] = flashloanAmount;
//     //     // call the multicallWithBalancerFlashLoan as alice
//     //     vm.prank(alice);
//     //     alicesAccount.multicallWithBalancerFlashLoan(
//     //         tokensArray,
//     //         amountsArray,
//     //         new bytes[](0), // precalls is empty
//     //         postCalls
//     //     );
//     //     // check that the loan exists
//     //     LendingTerm.Loan memory loan = SDAI_TERM.getLoan(expectedLoanId);
//     //     assertEq(loan.borrower, address(alicesAccount));
//     //     assertEq(loan.collateralAmount, 210_000e18);
//     //     assertEq(loan.borrowAmount, borrowAmount);
//     //     console.log(
//     //         "Remaining USDC in Alice's account: %s",
//     //         USDC_TOKEN.balanceOf(address(alicesAccount))
//     //     );
//     // }
//     // function getBorrowAmountFromCollateralAmount(
//     //     uint256 collateralAmount
//     // ) public view returns (uint256 borrowAmount) {
//     //     uint256 creditMultiplier = profitManager.creditMultiplier();
//     //     console.log("creditMultiplier: %s", creditMultiplier);
//     //     LendingTerm.LendingTermParams memory params = SDAI_TERM.getParameters();
//     //     borrowAmount =
//     //         (collateralAmount * params.maxDebtPerCollateralToken) /
//     //         creditMultiplier;
//     //     console.log("borrowAmount: %s", borrowAmount);
//     // }
// }
