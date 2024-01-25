// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Script} from "@forge-std/Script.sol";
import {GatewayV1} from "@src/gateway/GatewayV1.sol";

contract AddGatewayCalls is Script {
    uint256 public PRIVATE_KEY;
    GatewayV1 public gatewayv1 =
        GatewayV1(0x760Cb292043a99b867E0b994BC22071ceE958faa);

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

        gatewayv1.allowCall(
            0x64812e299076Bc01DF37C83Ce288E11d373D454c,
            bytes4(keccak256("borrowOnBehalf(uint256,uint256,address)")),
            true
        );
        gatewayv1.allowCall(
            0x64812e299076Bc01DF37C83Ce288E11d373D454c,
            bytes4(keccak256("partialRepay(bytes32,uint256)")),
            true
        );

        vm.stopBroadcast();
    }
}

/// @notice
/// deploy like that to verify:
/// forge script scripts/DeployGatewayV1.s.sol:DeployGatewayV1 -vvvv --rpc-url {{RPC URL}} --broadcast --etherscan-api-key {ETHERSCAN KEY} --verify --verifier-url https://api-sepolia.etherscan.io/api --chain-id 11155111 --verifier etherscan --force --slow
contract DeployGatewayV1 is Script {
    uint256 public PRIVATE_KEY;
    GatewayV1 public gatewayv1;

    // ADDRESSES ON SEPOLIA
    // TOKENS
    address public SDAI_TOKEN = 0xeeF0AB67262046d5bED00CE9C447e08D92b8dA61;
    address public USDC_TOKEN = 0xe9248437489bC542c68aC90E178f6Ca3699C3F6b;
    address public WBTC_TOKEN = 0xCfFBA3A25c3cC99A05443163C63209972bfFd1C1;
    address public CREDIT_TOKEN = 0x33b79F707C137AD8b70FA27d63847254CF4cF80f;

    // TERMS
    address public SDAI_TERM = 0xFBE67752BC63686707966b8Ace817094d26f5381;
    address public SDAI_TERM_2 = 0x64812e299076Bc01DF37C83Ce288E11d373D454c;
    address public WBTC_TERM = 0x94122FD2772622ED2C9E2DDfCe46214242f11419;

    // OTHERS
    address public PSM = 0x66839a9a16BebA26af1c717e9C1D604dff9d91F7;
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
        gatewayv1 = new GatewayV1();
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
            SDAI_TERM_2,
            getSelector("borrowOnBehalf(uint256,uint256,address)"),
            true
        );
        gatewayv1.allowCall(
            WBTC_TERM,
            getSelector("borrowOnBehalf(uint256,uint256,address)"),
            true
        );

        // allow partial repay on various terms
        gatewayv1.allowCall(
            SDAI_TERM,
            getSelector("partialRepay(bytes32,uint256)"),
            true
        );
        gatewayv1.allowCall(
            SDAI_TERM_2,
            getSelector("partialRepay(bytes32,uint256)"),
            true
        );
        gatewayv1.allowCall(
            WBTC_TERM,
            getSelector("partialRepay(bytes32,uint256)"),
            true
        );

        // allow redeem and mint on the psm
        gatewayv1.allowCall(PSM, getSelector("redeem(address,uint256)"), true);
        gatewayv1.allowCall(PSM, getSelector("mint(address,uint256)"), true);

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
