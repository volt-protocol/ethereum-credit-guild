// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ECGTest} from "@test/ECGTest.sol";

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

import {Core} from "@src/core/Core.sol";
import {Gateway} from "@src/gateway/Gateway.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {GatewayV1} from "@src/gateway/GatewayV1.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {SimplePSM} from "@src/loan/SimplePSM.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {AuctionHouse} from "@src/loan/AuctionHouse.sol";
import {ProfitManager} from "@src/governance/ProfitManager.sol";
import {MockBalancerVault} from "@test/mock/MockBalancerVault.sol";
import {RateLimitedMinter} from "@src/rate-limits/RateLimitedMinter.sol";

struct PermitData {
    uint8 v;
    bytes32 r;
    bytes32 s;
    uint256 deadline;
}

/// @title Test suite for the GatewayV1 contract
contract UnitTestGatewayV1 is ECGTest {
    // test users
    address private governor = address(9999999);
    address private guardian = address(8888888);
    address gatewayOwner = address(10101);
    uint256 public alicePrivateKey = uint256(0x42);
    address public alice = vm.addr(alicePrivateKey);
    address bob = address(0xb0bb0b);

    GatewayV1 public gatewayv1;
    Core private core;
    ProfitManager public profitManager;
    CreditToken credit;
    GuildToken guild;
    MockERC20 collateral;
    MockERC20 pegtoken;
    SimplePSM private psm;
    RateLimitedMinter rlcm;
    AuctionHouse auctionHouse;
    LendingTerm term;

    /// @notice Retrieves the bytecode of a contract at a specific address for testing purposes
    function getCode(address _addr) public view returns (bytes memory) {
        bytes memory code;
        assembly {
            // Get the size of the code at address `_addr`
            let size := extcodesize(_addr)
            // Allocate memory for the code
            code := mload(0x40)
            // Update the free memory pointer
            mstore(0x40, add(code, and(add(add(size, 0x20), 0x1f), not(0x1f))))
            // Store the size in memory
            mstore(code, size)
            // Copy the code to memory
            extcodecopy(_addr, add(code, 0x20), 0, size)
        }
        return code;
    }

    // dummy functions to be called by the gateway
    uint256 public amountSaved;

    function successfulFunction(uint256 amount) public {
        amountSaved = amount;
    }

    // mock uniswap router behavior
    function getAmountsIn(
        uint256 amountOut,
        address[] calldata /* path*/
    ) external pure returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amountOut;
        amounts[1] = amountOut;
        return amounts;
    }

    function getAmountsOut(
        uint256 amountIn,
        address[] calldata /* path*/
    ) external pure returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn;
        return amounts;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 /* amountOutMin*/,
        address[] calldata path,
        address to,
        uint256 /* deadline*/
    ) external returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](2);
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        IERC20(path[1]).transfer(to, amountIn);
        return amounts;
    }

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 /* amountInMax*/,
        address[] calldata path,
        address to,
        uint256 /* deadline*/
    ) external returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](2);
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountOut);
        IERC20(path[1]).transfer(to, amountOut);
        return amounts;
    }

    /// @notice Sets up the test by deploying the AccountFactory contract
    function setUp() public {
        vm.prank(gatewayOwner);
        gatewayv1 = new GatewayV1();

        core = new Core();

        profitManager = new ProfitManager(address(core));
        collateral = new MockERC20();
        pegtoken = new MockERC20();
        credit = new CreditToken(address(core), "name", "symbol");
        guild = new GuildToken(address(core));
        rlcm = new RateLimitedMinter(
            address(core) /*_core*/,
            address(credit) /*_token*/,
            CoreRoles.RATE_LIMITED_CREDIT_MINTER /*_role*/,
            type(uint256).max /*_maxRateLimitPerSecond*/,
            type(uint128).max /*_rateLimitPerSecond*/,
            type(uint128).max /*_bufferCap*/
        );
        auctionHouse = new AuctionHouse(address(core), 650, 1800, 0);
        term = LendingTerm(Clones.clone(address(new LendingTerm())));
        term.initialize(
            address(core),
            LendingTerm.LendingTermReferences({
                profitManager: address(profitManager),
                guildToken: address(guild),
                auctionHouse: address(auctionHouse),
                creditMinter: address(rlcm),
                creditToken: address(credit)
            }),
            abi.encode(
                LendingTerm.LendingTermParams({
                    collateralToken: address(collateral),
                    maxDebtPerCollateralToken: 1e18,
                    interestRate: 0.05e18,
                    maxDelayBetweenPartialRepay: 0,
                    minPartialRepayPercent: 0,
                    openingFee: 0,
                    hardCap: 1e27
                })
            )
        );
        psm = new SimplePSM(
            address(core),
            address(profitManager),
            address(credit),
            address(pegtoken)
        );
        profitManager.initializeReferences(address(credit), address(guild));

        // roles
        core.grantRole(CoreRoles.GOVERNOR, governor);
        core.grantRole(CoreRoles.GUARDIAN, guardian);
        core.grantRole(CoreRoles.CREDIT_MINTER, address(this));
        core.grantRole(CoreRoles.CREDIT_MINTER, address(psm));
        core.grantRole(CoreRoles.GUILD_MINTER, address(this));
        core.grantRole(CoreRoles.GAUGE_ADD, address(this));
        core.grantRole(CoreRoles.GAUGE_REMOVE, address(this));
        core.grantRole(CoreRoles.GAUGE_PARAMETERS, address(this));
        core.grantRole(CoreRoles.CREDIT_MINTER, address(rlcm));
        core.grantRole(CoreRoles.RATE_LIMITED_CREDIT_MINTER, address(term));
        core.grantRole(CoreRoles.GAUGE_PNL_NOTIFIER, address(term));
        core.grantRole(CoreRoles.CREDIT_BURNER, address(term));
        core.grantRole(CoreRoles.CREDIT_BURNER, address(profitManager));
        core.grantRole(CoreRoles.CREDIT_BURNER, address(psm));
        core.grantRole(CoreRoles.CREDIT_BURNER, address(this));
        core.renounceRole(CoreRoles.GOVERNOR, address(this));

        // add gauge and vote for it
        guild.setMaxGauges(10);
        guild.addGauge(1, address(term));
        guild.mint(address(this), 1e18);
        guild.incrementGauge(address(term), 1e18);

        // large psm mint
        pegtoken.mint(address(this), 1e27);
        pegtoken.approve(address(psm), 1e27);
        psm.mint(address(this), 1e27);
        credit.enterRebase();

        // labels
        vm.label(address(core), "core");
        vm.label(address(profitManager), "profitManager");
        vm.label(address(collateral), "collateral");
        vm.label(address(pegtoken), "pegtoken");
        vm.label(address(credit), "credit");
        vm.label(address(guild), "guild");
        vm.label(address(rlcm), "rlcm");
        vm.label(address(auctionHouse), "auctionHouse");
        vm.label(address(term), "term");
        vm.label(address(this), "test");
        vm.label(address(gatewayv1), "gatewayV1");

        _prepareBalancerVault();
        _allowCalls();

        // deal tokens to the "vault" & "uniswap"
        collateral.mint(gatewayv1.balancerVault(), 1e27);
        pegtoken.mint(gatewayv1.balancerVault(), 1e27);
        collateral.mint(address(this), 1e27);
        pegtoken.mint(address(this), 1e27);
    }

    /// @notice Prepares and verifies deployment of a mock Balancer vault for testing
    /// this deploy the mock and set etch the bytecode to the real balancerVault address
    function _prepareBalancerVault() internal {
        address mockAddress = address(new MockBalancerVault());
        bytes memory code = getCode(mockAddress);
        vm.etch(gatewayv1.balancerVault(), code);
        // test that the contract is deployed at the good address
        MockBalancerVault balancerVault = MockBalancerVault(
            gatewayv1.balancerVault()
        );
        assertEq("I am MockBalancerVault", balancerVault.WhoAmI());
    }

    function getSelector(bytes memory f) public pure returns (bytes4) {
        return bytes4(keccak256(f));
    }

    function _allowCalls() internal {
        vm.startPrank(gatewayOwner);
        gatewayv1.allowCall(
            address(collateral),
            getSelector("approve(address,uint256)"),
            true
        );
        gatewayv1.allowCall(
            address(pegtoken),
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
            address(this),
            getSelector(
                "swapTokensForExactTokens(uint256,uint256,address[],address,uint256)"
            ),
            true
        );
        gatewayv1.allowCall(
            address(this),
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
        vm.stopPrank();
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

    /// @notice Conducts a test scenario involving a Balancer flash loan
    /// this test shows that the balancer send the tokens and then that the calls are performed
    /// in a multicall way, and that we give the tokens back to the flashloan
    function testBalancerFlashLoan() public {
        // allow call to successfulFunction(uint256)
        vm.prank(gatewayOwner);
        gatewayv1.allowCall(address(this), bytes4(0xb510fa5c), true);

        // setup calls
        address[] memory tokens = new address[](1);
        tokens[0] = address(collateral);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 750;
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            address(this),
            abi.encodeWithSignature("successfulFunction(uint256)", uint256(750))
        );
        vm.prank(alice);
        gatewayv1.multicallWithBalancerFlashLoan(tokens, amounts, calls);
        assertEq(750, amountSaved);
    }

    /// @notice Ensures that unauthorized addresses cannot call the receiveFlashLoan function
    function testNonBalancerVaultCannotCallReceiveFlashLoan() public {
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(collateral);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 750;
        uint256[] memory feeAmounts = new uint256[](1);
        amounts[0] = 150;

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSignature(
            "receiveFlashLoan(address[],uint256[],uint256[],bytes)",
            tokens,
            amounts,
            feeAmounts,
            ""
        );
        vm.prank(bob);
        vm.expectRevert("GatewayV1: sender is not balancer");
        gatewayv1.multicall(calls);
    }

    // borrow with flashloan
    function testBorrowWithBalancerFlashLoan() public {
        // alice will get a loan with a permit, 10x leverage on collateral
        uint256 collateralAmount = 1000e18;
        uint256 flashloanCollateralAmount = 9000e18;
        collateral.mint(alice, 1000e18);

        // sign permit collateral -> Gateway
        PermitData memory permitCollateral = getPermitData(
            ERC20Permit(collateral),
            collateralAmount,
            address(gatewayv1),
            alice,
            alicePrivateKey
        );
        // sign permit credit -> gateway
        PermitData memory permitDataCredit = getPermitData(
            ERC20Permit(credit),
            collateralAmount + flashloanCollateralAmount,
            address(gatewayv1),
            alice,
            alicePrivateKey
        );

        bytes[] memory pullCollateralCalls = new bytes[](2);
        pullCollateralCalls[0] = abi.encodeWithSignature(
            "consumePermit(address,uint256,uint256,uint8,bytes32,bytes32)",
            collateral,
            collateralAmount,
            permitCollateral.deadline,
            permitCollateral.v,
            permitCollateral.r,
            permitCollateral.s
        );
        pullCollateralCalls[1] = abi.encodeWithSignature(
            "consumeAllowance(address,uint256)",
            collateral,
            collateralAmount
        );

        bytes memory allowBorrowedCreditCall = abi.encodeWithSignature(
            "consumePermit(address,uint256,uint256,uint8,bytes32,bytes32)",
            credit,
            collateralAmount + flashloanCollateralAmount,
            permitDataCredit.deadline,
            permitDataCredit.v,
            permitDataCredit.r,
            permitDataCredit.s
        );

        // call borrowWithBalancerFlashLoan
        vm.prank(alice);
        gatewayv1.borrowWithBalancerFlashLoan(
            address(term),
            address(psm),
            address(this),
            address(collateral),
            address(pegtoken),
            collateralAmount,
            flashloanCollateralAmount,
            9_900e18, // maxLoanDebt
            pullCollateralCalls,
            allowBorrowedCreditCall
        );

        // check results
        bytes32 loanId = keccak256(
            abi.encode(alice, address(term), block.timestamp)
        );
        LendingTerm.Loan memory loan = LendingTerm(term).getLoan(loanId);
        assertEq(collateral.balanceOf(alice), 0);
        assertEq(pegtoken.balanceOf(alice), 0);
        assertLt(collateral.balanceOf(address(gatewayv1)), 1e13);
        assertLt(pegtoken.balanceOf(address(gatewayv1)), 1e7);
        assertEq(loan.collateralAmount, 10_000e18);
        assertLt(loan.borrowAmount, 9_900e18);
    }

    // repay with flashloan
    function testRepayWithBalancerFlashLoan() public {
        testBorrowWithBalancerFlashLoan();
        bytes32 loanId = keccak256(
            abi.encode(alice, address(term), block.timestamp)
        );
        vm.warp(block.timestamp + 3 days);
        vm.roll(block.number + 1);

        uint256 collateralAmount = LendingTerm(term)
            .getLoan(loanId)
            .collateralAmount;
        uint256 maxCollateralSold = (collateralAmount * 95) / 100;

        // sign permit collateral -> Gateway
        PermitData memory permitCollateral = getPermitData(
            ERC20Permit(collateral),
            maxCollateralSold,
            address(gatewayv1),
            alice,
            alicePrivateKey
        );
        bytes memory allowCollateralTokenCall = abi.encodeWithSignature(
            "consumePermit(address,uint256,uint256,uint8,bytes32,bytes32)",
            collateral,
            maxCollateralSold,
            permitCollateral.deadline,
            permitCollateral.v,
            permitCollateral.r,
            permitCollateral.s
        );

        // call repayWithBalancerFlashLoan
        vm.prank(alice);
        gatewayv1.repayWithBalancerFlashLoan(
            loanId,
            address(term),
            address(psm),
            address(this),
            address(collateral),
            address(pegtoken),
            maxCollateralSold,
            allowCollateralTokenCall
        );

        assertGt(collateral.balanceOf(alice), 900e18);
        assertEq(pegtoken.balanceOf(alice), 0);
        assertLt(collateral.balanceOf(address(gatewayv1)), 1e13);
        assertLt(pegtoken.balanceOf(address(gatewayv1)), 1e7);
    }

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
        uint256 minProfit = 25e6; // min 25 pegtoken of profit
        while (profit == 0 && block.timestamp < stop) {
            (uint256 collateralReceived, ) = auctionHouse.getBidDetail(loanId);
            // keep 1 wei of extra collateral unused to test the sweep function
            // (any extra collateral should be forwarded to caller)
            if (collateralReceived != 0) {
                collateralReceived = collateralReceived - 1;
            }
            // encode the swap using uniswapv2 router
            address[] memory path = new address[](2);
            path[0] = address(collateral);
            path[1] = address(pegtoken);
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
                    address(collateral),
                    address(pegtoken),
                    minProfit,
                    address(this), // in this test suite, 'this' is the uniswap pool
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
        assertEq(LendingTerm(term).getLoan(loanId).closeTime, block.timestamp);
    }
}
