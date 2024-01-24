// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Script, console} from "@forge-std/Script.sol";
import {GatewayV1} from "@src/gateway/GatewayV1.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ProfitManager} from "@src/governance/ProfitManager.sol";
import {SimplePSM} from "@src/loan/SimplePSM.sol";

/// @notice
/// @dev start with forge script scripts/gateway/SimpleBorrowOnSDAI.s.sol:SimpleBorrowOnSDAI -vvvv --rpc-url {RPC URL}
contract SimpleBorrowOnSDAIWithLeverage is Script {
    uint256 public PRIVATE_KEY;
    GatewayV1 public gatewayv1 =
        GatewayV1(0x760Cb292043a99b867E0b994BC22071ceE958faa);
    address public SDAI_TOKEN = 0xeeF0AB67262046d5bED00CE9C447e08D92b8dA61;
    address public USDC_TOKEN = 0xe9248437489bC542c68aC90E178f6Ca3699C3F6b;
    address public SDAI_TERM = 0x64812e299076Bc01DF37C83Ce288E11d373D454c;
    address public PSM = 0x66839a9a16BebA26af1c717e9C1D604dff9d91F7;
    ProfitManager public profitManager =
        ProfitManager(0xD8c5748984d27Af2b1FC8235848B16C326e1F6de);
    address public CREDIT_TOKEN = 0x33b79F707C137AD8b70FA27d63847254CF4cF80f;
    address public UNISWAP_ROUTER = 0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008;

    struct PermitData {
        uint8 v;
        bytes32 r;
        bytes32 s;
        uint256 deadline;
    }

    function _parseEnv() internal {
        // Default behavior: use Anvil 0 private key
        PRIVATE_KEY = vm.envOr(
            "ETH_PRIVATE_KEY",
            77814517325470205911140941194401928579557062014761831930645393041380819009408
        );
    }

    function _labelUp() public {
        vm.label(address(SDAI_TERM), "SDAI_TERM");
        vm.label(address(SDAI_TOKEN), "SDAI_TOKEN");
        vm.label(address(CREDIT_TOKEN), "CREDIT_TOKEN");
        vm.label(address(PSM), "psm");
        vm.label(address(gatewayv1), "gateway");
    }

    function run() public {
        _parseEnv();
        _labelUp();
        vm.startBroadcast(PRIVATE_KEY);

        uint256 collateralAmount = 200e18; // 200 sDAI as collateral
        uint256 flashloanAmount = 2000e18; // 2000 DAI flashloaned
        uint256 debtAmount = getBorrowAmountFromCollateralAmount(
            collateralAmount + flashloanAmount
        );

        // sign permit SDAI -> Gateway
        PermitData memory permitDataSDAI = getPermitData(
            ERC20Permit(SDAI_TOKEN),
            collateralAmount,
            address(gatewayv1)
        );
        // sign permit gUSDC -> gateway
        PermitData memory permitDataGUSDC = getPermitData(
            ERC20Permit(CREDIT_TOKEN),
            debtAmount,
            address(gatewayv1)
        );

        // create the calls
        bytes[] memory calls = new bytes[](12);

        // consume user permit
        calls[0] = abi.encodeWithSignature(
            "consumePermit(address,uint256,uint256,uint8,bytes32,bytes32)", // token, amount
            SDAI_TOKEN,
            collateralAmount,
            permitDataSDAI.deadline,
            permitDataSDAI.v,
            permitDataSDAI.r,
            permitDataSDAI.s
        );

        // consumer user allowance
        calls[1] = abi.encodeWithSignature(
            "consumeAllowance(address,uint256)", // token, amount
            SDAI_TOKEN,
            collateralAmount
        );

        calls[2] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            SDAI_TOKEN,
            abi.encodeWithSignature(
                "approve(address,uint256)",
                SDAI_TERM,
                collateralAmount + flashloanAmount
            )
        );

        calls[3] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            SDAI_TERM,
            abi.encodeWithSignature(
                "borrowOnBehalf(uint256,uint256,address)",
                debtAmount,
                collateralAmount + flashloanAmount,
                vm.addr(PRIVATE_KEY)
            )
        );

        calls[4] = abi.encodeWithSignature(
            "consumePermit(address,uint256,uint256,uint8,bytes32,bytes32)", // token, amount
            CREDIT_TOKEN,
            debtAmount,
            permitDataGUSDC.deadline,
            permitDataGUSDC.v,
            permitDataGUSDC.r,
            permitDataGUSDC.s
        );

        calls[5] = abi.encodeWithSignature(
            "consumeAllowance(address,uint256)", // token, amount
            CREDIT_TOKEN,
            debtAmount
        );

        calls[6] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            CREDIT_TOKEN,
            abi.encodeWithSignature("approve(address,uint256)", PSM, debtAmount)
        );

        // redeem gUSDC => USDC to the gateway
        calls[7] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            PSM,
            abi.encodeWithSignature(
                "redeem(address,uint256)",
                address(gatewayv1),
                debtAmount
            )
        );
        // get the amount USDC we should have received
        uint256 amountUSDC = SimplePSM(PSM).getRedeemAmountOut(debtAmount);

        // here we have the full value in USDC after redeeming, need to change to sDAI
        // approve uniswap router
        calls[8] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            USDC_TOKEN,
            abi.encodeWithSignature(
                "approve(address,uint256)",
                UNISWAP_ROUTER,
                amountUSDC
            )
        );

        address[] memory path = new address[](2);
        path[0] = address(USDC_TOKEN);
        path[1] = address(SDAI_TOKEN);
        calls[9] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            address(UNISWAP_ROUTER),
            abi.encodeWithSignature(
                "swapTokensForExactTokens(uint256,uint256,address[],address,uint256)",
                flashloanAmount, // amount out
                amountUSDC, // amount in max
                path, // path USDC->SDAI
                address(gatewayv1), // to
                uint256(block.timestamp + 3600) // deadline
            )
        );

        // reset approval on the uniswap router
        calls[10] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            USDC_TOKEN,
            abi.encodeWithSignature(
                "approve(address,uint256)",
                UNISWAP_ROUTER,
                0
            )
        );

        calls[11] = abi.encodeWithSignature("sweep(address)", USDC_TOKEN);

        // call multicall on the gateway
        address[] memory flashLoanTokens = new address[](1);
        flashLoanTokens[0] = SDAI_TOKEN;
        uint256[] memory flashloanAmounts = new uint256[](1);
        flashloanAmounts[0] = flashloanAmount;
        gatewayv1.multicallWithBalancerFlashLoan(
            flashLoanTokens,
            flashloanAmounts,
            calls
        );

        vm.stopBroadcast();
    }

    function getPermitData(
        ERC20Permit token,
        uint256 amount,
        address to
    ) public view returns (PermitData memory permitData) {
        address deployerAddress = vm.addr(PRIVATE_KEY);
        uint256 deadline = block.timestamp + 100;
        // sign permit message valid for 10s
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                ),
                deployerAddress,
                to,
                amount,
                token.nonces(deployerAddress),
                deadline
            )
        );

        bytes32 digest = ECDSA.toTypedDataHash(
            token.DOMAIN_SEPARATOR(),
            structHash
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PRIVATE_KEY, digest);

        return PermitData({v: v, r: r, s: s, deadline: deadline});
    }

    function getBorrowAmountFromCollateralAmount(
        uint256 collateralAmount
    ) public view returns (uint256 borrowAmount) {
        uint256 creditMultiplier = profitManager.creditMultiplier();
        console.log("creditMultiplier: %s", creditMultiplier);
        LendingTerm.LendingTermParams memory params = LendingTerm(SDAI_TERM)
            .getParameters();
        borrowAmount =
            (collateralAmount * params.maxDebtPerCollateralToken) /
            creditMultiplier;
        console.log("borrowAmount: %s", borrowAmount);
    }
}
