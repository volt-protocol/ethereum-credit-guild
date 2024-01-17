// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import "@forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Core} from "@src/core/Core.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {SimplePSM} from "@src/loan/SimplePSM.sol";
import {AddressLib} from "@test/proposals/AddressLib.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {GuildGovernor} from "@src/governance/GuildGovernor.sol";
import {AuctionHouse} from "@src/loan/AuctionHouse.sol";
import {ProfitManager} from "@src/governance/ProfitManager.sol";
import {TestProposals} from "@test/proposals/TestProposals.sol";
import {ERC20MultiVotes} from "@src/tokens/ERC20MultiVotes.sol";
import {GuildVetoGovernor} from "@src/governance/GuildVetoGovernor.sol";
import {RateLimitedMinter} from "@src/rate-limits/RateLimitedMinter.sol";
import {PostProposalCheck} from "@test/integration/PostProposalCheck.sol";
import {SurplusGuildMinter} from "@src/loan/SurplusGuildMinter.sol";
import {LendingTermOnboarding} from "@src/governance/LendingTermOnboarding.sol";
import {LendingTermOffboarding} from "@src/governance/LendingTermOffboarding.sol";
import {GuildTimelockController} from "@src/governance/GuildTimelockController.sol";

import {IBalancerFlashLoan, AccountImplementation} from "@src/account/AccountImplementation.sol";
import {AccountFactory} from "@src/account/AccountFactory.sol";
import {TestnetToken} from "./TestNetToken.sol";

interface IUniswapRouter {
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

contract IntegrationTestSepoliaBorrowLeverage is Test {
    bytes32 public immutable WBTCUSDC_POOLID =
        0xc4623b1345af4e23dc6b86ed010c493e3e601267000200000000000000000073; // https://beta.balancer.fi/#/sepolia/pool/0xc4623b1345af4e23dc6b86ed010c493e3e601267000200000000000000000073
    bytes32 public immutable USDCSDAI_POOLID =
        0xc9c3e0e8f800c3efe116b16de314c13ebef9a359000200000000000000000074; // https://beta.balancer.fi/#/sepolia/pool/0xc9c3e0e8f800c3efe116b16de314c13ebef9a359000200000000000000000074

    IBalancerFlashLoan public immutable BALANCER_VAULT =
        IBalancerFlashLoan(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    LendingTerm public immutable SDAI_TERM =
        LendingTerm(0xFBE67752BC63686707966b8Ace817094d26f5381);

    address public immutable GOVERNOR =
        0xb027658e189F9814663631b12B9CDF8dd7CC977C;

    TestnetToken public immutable SDAI_TOKEN =
        TestnetToken(0xeeF0AB67262046d5bED00CE9C447e08D92b8dA61);
    TestnetToken public immutable USDC_TOKEN =
        TestnetToken(0xe9248437489bC542c68aC90E178f6Ca3699C3F6b);

    CreditToken public immutable CREDIT_TOKEN =
        CreditToken(0x33b79F707C137AD8b70FA27d63847254CF4cF80f);

    address public immutable UNISWAP_USDCSDAI_PAIR =
        0x2Da1418165474B60DD5Dd3Dd097422Aea9EE1655;
    IUniswapRouter public immutable UNISWAP_ROUTER =
        IUniswapRouter(0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008);

    // Alice will borrow on the sDAI term.
    address public alice = address(0x1010101);

    // factory owner will deploy and whitelist calls for the account factory
    address public factoryOwner = address(0x20202020);

    // instanciated in setUP();
    ProfitManager public profitManager;
    SimplePSM public psm;
    AccountImplementation allowedImplementation;
    AccountImplementation alicesAccount;
    AccountFactory accountFactory;

    /* uint256 creditMultiplier = ProfitManager(refs.profitManager)
            .creditMultiplier();
        uint256 maxBorrow = (collateralAmount *
            params.maxDebtPerCollateralToken) / creditMultiplier;
        require(
            borrowAmount <= maxBorrow,
            "LendingTerm: not enough collateral"
        );*/

    function setUp() public {
        LendingTerm.LendingTermReferences memory refs = SDAI_TERM
            .getReferences();
        profitManager = ProfitManager(refs.profitManager);
        console.log("profit manager: %s", address(profitManager));
        psm = SimplePSM(profitManager.psm());
        console.log("psm: %s", address(psm));

        // give 1M USDC to the PSM
        vm.startPrank(GOVERNOR);
        USDC_TOKEN.mint(address(GOVERNOR), 1_000_000e6);
        USDC_TOKEN.approve(address(psm), 1_000_000e6);
        psm.mint(address(GOVERNOR), 1_000_000e6);
        vm.stopPrank();
        console.log("psm USDC: %s", psm.pegTokenBalance());
        // setUp the account factory & allowed calls
        setUpAccountFactory();

        // alice needs to create her account
        vm.prank(alice);
        alicesAccount = AccountImplementation(
            accountFactory.createAccount(address(allowedImplementation))
        );

        assertEq(alicesAccount.owner(), alice);

        labelUp();
    }

    function setUpAccountFactory() public {
        vm.startPrank(factoryOwner);
        // deploy the factory
        accountFactory = AccountFactory(new AccountFactory());
        // deploy the account implementation
        allowedImplementation = AccountImplementation(
            new AccountImplementation()
        );

        // whitelist account implementation
        accountFactory.allowImplementation(
            address(allowedImplementation),
            true
        );

        // allow approve on sDAI token
        accountFactory.allowCall(
            address(SDAI_TOKEN),
            bytes4(keccak256("approve(address,uint256)")),
            true
        );

        // allow approve on USDC token
        accountFactory.allowCall(
            address(USDC_TOKEN),
            bytes4(keccak256("approve(address,uint256)")),
            true
        );

        // allow borrow on CREDIT token
        accountFactory.allowCall(
            address(CREDIT_TOKEN),
            bytes4(keccak256("approve(address,uint256)")),
            true
        );

        // allow borrow on sDAI lending term
        accountFactory.allowCall(
            address(SDAI_TERM),
            bytes4(keccak256("borrow(uint256,uint256)")),
            true
        );

        // allow redeem on psm
        accountFactory.allowCall(
            address(psm),
            bytes4(keccak256("redeem(address,uint256)")),
            true
        );

        // allow swap on balancer vault
        // accountFactory.allowCall(
        //     address(BALANCER_VAULT),
        //     bytes4(
        //         keccak256(
        //             "swap((bytes32,uint8,address,address,uint256,bytes),(address,bool,address,bool),uint256,uint256)"
        //         )
        //     ),
        //     true
        // );

        // allow swap on uniswap router
        accountFactory.allowCall(
            address(UNISWAP_ROUTER),
            bytes4(
                keccak256(
                    "swapTokensForExactTokens(uint256,uint256,address[],address,uint256)"
                )
            ),
            true
        );

        vm.stopPrank();
    }

    function labelUp() public {
        vm.label(address(BALANCER_VAULT), "BALANCER_VAULT");
        vm.label(address(SDAI_TERM), "SDAI_TERM");
        vm.label(address(GOVERNOR), "GOVERNOR");
        vm.label(address(SDAI_TOKEN), "SDAI_TOKEN");
        vm.label(address(USDC_TOKEN), "USDC_TOKEN");
        vm.label(address(CREDIT_TOKEN), "CREDIT_TOKEN");
        vm.label(address(alice), "alice");
        vm.label(address(factoryOwner), "factoryOwner");
        vm.label(address(psm), "psm");
        vm.label(address(allowedImplementation), "allowedImplementation");
        vm.label(address(alicesAccount), "alicesAccount");
        vm.label(address(accountFactory), "accountFactory");
        vm.label(address(UNISWAP_USDCSDAI_PAIR), "UNISWAP_USDCSDAI_PAIR");
        vm.label(address(UNISWAP_ROUTER), "UNISWAP_ROUTER");
    }

    // should test the following scenario with a balancer flashloan and the new multicall account feature:
    // - have an account with 10k sDAI
    // - flashloan 200k sDAI from balancer
    // - approve 210k sDAI to the lending term
    // - borrow with 210k sDAI collateral
    // - get X gUSDC
    // - PSM.redeem X gUSDC for Y USDC
    // - swap Y USDC for Z sDAI on balancer
    // - reimburse balancer flashloan
    function testFlashLoanWithBalancer() public {
        // - have an account with 10k sDAI
        vm.prank(GOVERNOR);
        SDAI_TOKEN.mint(alice, 10_000e18);
        assertEq(SDAI_TOKEN.balanceOf(alice), 10_000e18);

        // alice will send 10k sDAI to her account
        vm.prank(alice);
        SDAI_TOKEN.transfer(address(alicesAccount), 10_000e18);
        assertEq(SDAI_TOKEN.balanceOf(address(alicesAccount)), 10_000e18);

        // - flashloan 200k sDAI from balancer
        uint256 flashloanAmount = 200_000e18;
        // this is done when calling the 'multicallWithBalancerFlashLoan' function on alice's Account

        // now we will prepare the call list to be sent as the "postCalls" to the 'multicallWithBalancerFlashLoan' function
        bytes[] memory postCalls = new bytes[](6);

        // - approve 210k sDAI to the lending term, this will be the max
        postCalls[0] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            address(SDAI_TOKEN),
            abi.encodeWithSignature(
                "approve(address,uint256)",
                address(SDAI_TERM),
                uint256(210_000e18)
            )
        );

        // compute the borrowAmount and collateral amount
        uint256 borrowAmount = getBorrowAmountFromCollateralAmount(210_000e18);
        // - borrow with 210k sDAI collateral, get X gUSDC
        postCalls[1] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            address(SDAI_TERM),
            abi.encodeWithSignature(
                "borrow(uint256,uint256)",
                borrowAmount,
                uint256(210_000e18)
            )
        );

        // - PSM.redeem X gUSDC for Y USDC
        // approve gUSDC from the PSM
        postCalls[2] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            address(CREDIT_TOKEN),
            abi.encodeWithSignature(
                "approve(address,uint256)",
                address(psm),
                borrowAmount
            )
        );

        // call redeem
        postCalls[3] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            address(psm),
            abi.encodeWithSignature(
                "redeem(address,uint256)",
                address(alicesAccount),
                borrowAmount
            )
        );

        // approve USDC spending by the uniswap router
        postCalls[4] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            address(USDC_TOKEN),
            abi.encodeWithSignature(
                "approve(address,uint256)",
                address(UNISWAP_ROUTER),
                uint256(210_000e6)
            )
        );

        address[] memory path = new address[](2);
        path[0] = address(USDC_TOKEN);
        path[1] = address(SDAI_TOKEN);
        // - swap Y USDC for Z sDAI on uniswapv2
        postCalls[5] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            address(UNISWAP_ROUTER),
            abi.encodeWithSignature(
                "swapTokensForExactTokens(uint256,uint256,address[],address,uint256)",
                flashloanAmount, // amount out
                uint256(210_000e6), // amount in max
                path, // path USDC->SDAI
                address(alicesAccount), // to
                uint256(block.timestamp + 3600) // deadline
            )
        );

        // - swap Y USDC for Z sDAI on uniswapv2
        // postCalls[5] = abi.encodeWithSignature(
        //     "callExternal(address,bytes)",
        //     address(BALANCER_VAULT),
        //     abi.encodeWithSignature(
        //         "swap((bytes32,uint8,address,address,uint256,bytes),(address,bool,address,bool),uint256,uint256)",
        //         abi.encodePacked(
        //             bytes32(USDCSDAI_POOLID), // poolid
        //             uint8(1), // swapkind = GIVEN_OUT, 0 is GIVEN_IN
        //             address(USDC_TOKEN), // assetIn
        //             address(SDAI_TOKEN), // assetOut
        //             uint256(flashloanAmount), // amount = flashloan amount, to reimburse balancer
        //             bytes("something") // userData
        //         ),
        //         abi.encodePacked(
        //             address(alicesAccount), // sender
        //             bool(false), // fromInternalBalance,
        //             payable(address(alicesAccount)), // recipient
        //             bool(false) // toInternalBalance
        //         ),
        //         uint256(210_000e6), // amountIn limit for a GIVEN_OUT, do not swap more than 210k USDC
        //         uint256(block.timestamp + 3600) // deadline timestamp
        //     )
        // );

        // postCalls[5] = abi.encodeWithSignature(
        //     "callExternal(address,bytes)",
        //     address(BALANCER_VAULT),
        //     abi.encodeWithSignature(
        //         "swap((bytes32,uint8,address,address,uint256,bytes),(address,bool,address,bool),uint256,uint256)",
        //         IBalancerFlashLoan.SingleSwap({
        //             poolId: bytes32(USDCSDAI_POOLID), // poolid
        //             kind: IBalancerFlashLoan.SwapKind.GIVEN_OUT, // swapkind = GIVEN_OUT, 0 is GIVEN_IN
        //             assetIn: address(USDC_TOKEN), // assetIn
        //             assetOut: address(SDAI_TOKEN), // assetOut
        //             amount: uint256(flashloanAmount), // amount = flashloan amount, to reimburse balancer
        //             userData: bytes("something") // userData
        //         }),
        //         IBalancerFlashLoan.FundManagement({
        //             sender: address(alicesAccount), // sender
        //             fromInternalBalance: bool(false), // fromInternalBalance,
        //             recipient: payable(address(alicesAccount)), // recipient
        //             toInternalBalance: bool(false) // toInternalBalance
        //         }),
        //         uint256(210_000e6), // amountIn limit for a GIVEN_OUT, do not swap more than 210k USDC
        //         uint256(block.timestamp + 3600) // deadline timestamp
        //     )
        // );

        // - reimburse balancer flashloan
        // automatically done by the account implementation

        IERC20[] memory tokensArray = new IERC20[](1);
        tokensArray[0] = IERC20(SDAI_TOKEN);

        uint256[] memory amountsArray = new uint256[](1);
        amountsArray[0] = flashloanAmount;

        // call the multicallWithBalancerFlashLoan as alice
        vm.prank(alice);
        alicesAccount.multicallWithBalancerFlashLoan(
            tokensArray,
            amountsArray,
            new bytes[](0),
            postCalls
        );
    }

    function getBorrowAmountFromCollateralAmount(
        uint256 collateralAmount
    ) public view returns (uint256 borrowAmount) {
        uint256 creditMultiplier = profitManager.creditMultiplier();
        console.log("creditMultiplier: %s", creditMultiplier);
        LendingTerm.LendingTermParams memory params = SDAI_TERM.getParameters();
        borrowAmount =
            (collateralAmount * params.maxDebtPerCollateralToken) /
            creditMultiplier;

        console.log("borrowAmount: %s", borrowAmount);
    }
}
