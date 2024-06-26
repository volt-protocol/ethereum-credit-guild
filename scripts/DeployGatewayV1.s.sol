// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Script, console} from "@forge-std/Script.sol";
import {GatewayV1} from "@src/gateway/GatewayV1.sol";

/// @notice
/// deploy like that to verify:
/// forge script scripts/DeployGatewayV1.s.sol:DeployGatewayV1 -vvvv --rpc-url {{RPC URL}} --broadcast --etherscan-api-key {ETHERSCAN KEY} --verify --verifier-url https://api-sepolia.etherscan.io/api --chain-id 11155111 --verifier etherscan --force --slow
contract DeployGatewayV1 is Script {
    uint256 public PRIVATE_KEY;
    GatewayV1 public gatewayv1;

    // ADDRESSES ON SEPOLIA
    // TOKENS
    address public SDAI_TOKEN = 0x9F07498d9f4903B10dB57a3Bd1D91b6B64AEd61e;
    address public USDC_TOKEN = 0x7b8b4418990e4Daf35F5c7f0165DC487b1963641;
    address public WBTC_TOKEN = 0x1cED1eB530b5E71E6dB9221A22C725e862fC0e60;
    address public CREDIT_TOKEN = 0x7dFF544F61b262d7218811f78c94c3b2F4e3DCA1;

    // TERMS
    address public SDAI_TERM = 0x938998fca53D8BFD91BC1726D26238e9Eada596C;
    address public SDAI_TERM_REPAY_1SEC =
        0x427425372b643fc082328b70A0466302179260f5;
    address public WBTC_TERM = 0x820E8F9399514264Fd8CB21cEE5F282c723131f6;

    // OTHERS
    address public PSM = 0xC19D710f13a725FD67021e8c45bDedFfE95202e3;
    address public AUCTION_HOUSE = 0x912e76518b318c209eF7FF04D119967AcAe3569e;
    address public UNISWAP_ROUTER = 0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008;

    function _parseEnv() internal {
        // Default behavior: use Anvil 0 private key
        PRIVATE_KEY = vm.envOr(
            "ETH_PRIVATE_KEY",
            77814517325470205911140941194401928579557062014761831930645393041380819009408
        );
    }

    function run() public {
        _parseEnv();

        vm.startBroadcast(PRIVATE_KEY);
        gatewayv1 = new GatewayV1(0xb8ae64F191F829fC00A4E923D460a8F2E0ba3978);
        allowCalls();
        vm.stopBroadcast();
    }

    function allowCalls() public {
        // allow approve on the various tokens
        gatewayv1.allowCall(
            SDAI_TOKEN,
            getSelector("approve(address,uint256)"),
            true
        );
        gatewayv1.allowCall(
            USDC_TOKEN,
            getSelector("approve(address,uint256)"),
            true
        );
        gatewayv1.allowCall(
            WBTC_TOKEN,
            getSelector("approve(address,uint256)"),
            true
        );
        gatewayv1.allowCall(
            CREDIT_TOKEN,
            getSelector("approve(address,uint256)"),
            true
        );

        // allow borrowOnBehalf on various terms
        gatewayv1.allowCall(
            SDAI_TERM,
            getSelector("borrowOnBehalf(uint256,uint256,address)"),
            true
        );
        gatewayv1.allowCall(
            SDAI_TERM_REPAY_1SEC,
            getSelector("borrowOnBehalf(uint256,uint256,address)"),
            true
        );
        gatewayv1.allowCall(
            WBTC_TERM,
            getSelector("borrowOnBehalf(uint256,uint256,address)"),
            true
        );

        // allow repay / partial repay on various terms
        gatewayv1.allowCall(
            SDAI_TERM,
            getSelector("partialRepay(bytes32,uint256)"),
            true
        );
        gatewayv1.allowCall(
            SDAI_TERM_REPAY_1SEC,
            getSelector("partialRepay(bytes32,uint256)"),
            true
        );
        gatewayv1.allowCall(
            WBTC_TERM,
            getSelector("partialRepay(bytes32,uint256)"),
            true
        );
        gatewayv1.allowCall(SDAI_TERM, getSelector("repay(bytes32)"), true);
        gatewayv1.allowCall(
            SDAI_TERM_REPAY_1SEC,
            getSelector("repay(bytes32)"),
            true
        );
        gatewayv1.allowCall(WBTC_TERM, getSelector("repay(bytes32)"), true);

        // allow redeem and mint on the psm
        gatewayv1.allowCall(PSM, getSelector("redeem(address,uint256)"), true);
        gatewayv1.allowCall(PSM, getSelector("mint(address,uint256)"), true);

        // allow auction house bid
        gatewayv1.allowCall(AUCTION_HOUSE, getSelector("bid(bytes32)"), true);

        // allow two types of swap on the uniswap router
        gatewayv1.allowCall(
            UNISWAP_ROUTER,
            getSelector(
                "swapTokensForExactTokens(uint256,uint256,address[],address,uint256)"
            ),
            true
        );
        gatewayv1.allowCall(
            UNISWAP_ROUTER,
            getSelector(
                "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)"
            ),
            true
        );
    }

    function getSelector(
        bytes memory functionStr
    ) public pure returns (bytes4) {
        return bytes4(keccak256(functionStr));
    }
}

contract UpdateGatewayV1 is Script {
    uint256 public PRIVATE_KEY;
    GatewayV1 public gatewayv1 =
        GatewayV1(0x6b00C1ac7a1680dd5326bcd9DC735514419F7A33);

    // ADDRESSES ON SEPOLIA

    function _parseEnv() internal {
        // Default behavior: use Anvil 0 private key
        PRIVATE_KEY = vm.envOr(
            "ETH_PRIVATE_KEY",
            77814517325470205911140941194401928579557062014761831930645393041380819009408
        );
    }

    function run() public {
        _parseEnv();

        address deployerAddress = vm.addr(PRIVATE_KEY);
        console.log("DEPLOYER: %s", deployerAddress);

        vm.startBroadcast(PRIVATE_KEY);

        gatewayv1.allowCall(
            0x938998fca53D8BFD91BC1726D26238e9Eada596C,
            getSelector("repay(bytes32)"),
            true
        );
        gatewayv1.allowCall(
            0x820E8F9399514264Fd8CB21cEE5F282c723131f6,
            getSelector("repay(bytes32)"),
            true
        );

        vm.stopBroadcast();
    }

    function getSelector(
        bytes memory functionStr
    ) public pure returns (bytes4) {
        return bytes4(keccak256(functionStr));
    }
}
