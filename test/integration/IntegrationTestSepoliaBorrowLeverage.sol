// // SPDX-License-Identifier: GPL-3.0-or-later
// pragma solidity 0.8.13;

// import "@forge-std/Test.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// import {SimplePSM} from "@src/loan/SimplePSM.sol";
// import {CreditToken} from "@src/tokens/CreditToken.sol";
// import {LendingTerm} from "@src/loan/LendingTerm.sol";
// import {ProfitManager} from "@src/governance/ProfitManager.sol";

// import {IBalancerFlashLoan, AccountImplementation} from "@src/account/AccountImplementation.sol";
// import {AccountFactory} from "@src/account/AccountFactory.sol";
// import {TestnetToken} from "@src/tokens/TestNetToken.sol";

// interface IUniswapRouter {
//     function swapTokensForExactTokens(
//         uint256 amountOut,
//         uint256 amountInMax,
//         address[] calldata path,
//         address to,
//         uint256 deadline
//     ) external returns (uint256[] memory amounts);
// }

// /// @notice execute a integration test with the account implementation for leveraging a position via flashloan
// /// use like that: forge test --match-contract IntegrationTestSepoliaBorrowLeverage --fork-url {RPC_URL} -vv
// contract IntegrationTestSepoliaBorrowLeverage is Test {
//     // LendingTerm public immutable SDAI_TERM =
//     //     LendingTerm(0xFBE67752BC63686707966b8Ace817094d26f5381);
//     // address public immutable GOVERNOR =
//     //     0xb027658e189F9814663631b12B9CDF8dd7CC977C;
//     // TestnetToken public immutable SDAI_TOKEN =
//     //     TestnetToken(0xeeF0AB67262046d5bED00CE9C447e08D92b8dA61);
//     // TestnetToken public immutable USDC_TOKEN =
//     //     TestnetToken(0xe9248437489bC542c68aC90E178f6Ca3699C3F6b);
//     // CreditToken public immutable CREDIT_TOKEN =
//     //     CreditToken(0x33b79F707C137AD8b70FA27d63847254CF4cF80f);
//     // IUniswapRouter public immutable UNISWAP_ROUTER =
//     //     IUniswapRouter(0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008);
//     // // Alice will borrow on the sDAI term.
//     // address public alice = address(0x1010101);
//     // // factory owner will deploy and whitelist calls for the account factory
//     // address public factoryOwner = address(0x20202020);
//     // // instanciated in setUP();
//     // ProfitManager public profitManager;
//     // SimplePSM public psm;
//     // AccountImplementation allowedImplementation;
//     // AccountImplementation alicesAccount;
//     // AccountFactory accountFactory;
//     // function setUp() public {
//     //     LendingTerm.LendingTermReferences memory refs = SDAI_TERM
//     //         .getReferences();
//     //     profitManager = ProfitManager(refs.profitManager);
//     //     console.log("profit manager: %s", address(profitManager));
//     //     psm = SimplePSM(profitManager.psm());
//     //     console.log("psm: %s", address(psm));
//     //     // give 1M USDC to the PSM
//     //     vm.startPrank(GOVERNOR);
//     //     USDC_TOKEN.mint(address(GOVERNOR), 1_000_000e6);
//     //     USDC_TOKEN.approve(address(psm), 1_000_000e6);
//     //     psm.mint(address(GOVERNOR), 1_000_000e6);
//     //     vm.stopPrank();
//     //     console.log("psm USDC: %s", psm.pegTokenBalance());
//     //     // setUp the account factory & allowed calls
//     //     setUpAccountFactory();
//     //     // alice needs to create her account
//     //     vm.prank(alice);
//     //     alicesAccount = AccountImplementation(
//     //         accountFactory.createAccount(address(allowedImplementation))
//     //     );
//     //     assertEq(alicesAccount.owner(), alice);
//     //     labelUp();
//     // }
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
