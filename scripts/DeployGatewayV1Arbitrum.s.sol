// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Script, console} from "@forge-std/Script.sol";
import {GatewayV1} from "@src/gateway/GatewayV1.sol";

/// @notice
/// deploy like that to verify:
/// forge script scripts/DeployGatewayV1.s.sol:DeployGatewayV1 -vvvv --rpc-url {{RPC URL}} --broadcast --etherscan-api-key {ETHERSCAN KEY} --verify --verifier-url https://api-sepolia.etherscan.io/api --chain-id 11155111 --verifier etherscan --force --slow
contract DeployGatewayV1Arbitrum is Script {
    uint256 public PRIVATE_KEY;
    GatewayV1 public gatewayv1;
    address[] public addressesToAllow;
    address[] public tokensToApprove;

    address TEAM_MULTISIG_ADDRESS = 0x1A1075cef632624153176CCf19Ae0175953CF010;

    address GUILD_TOKEN_ARBITRUM = 0xb8ae64F191F829fC00A4E923D460a8F2E0ba3978;

    // PROTOCOL ADDRESSES
    address public PSM_1 = 0xc273c03D7F28f570C6765Be50322BC06bdd4bFab;
    address public PSM_3 = 0x475840078280BaE8EF2428dbe151c7b349CF3f50;
    address public PSM_4 = 0x4dC22679436e4C751bdfe6c518CD7768E999CED3;
    address public PSM_999999999 = 0x47fa48413508b979Ca72Fe638011Ecf0556429bE;
    address public PSM_999999998 = 0x81869fcBF98ab8982B5c30529A2E7C3C24f7554e;
    address public AUCTION_HOUSE_6H =
        0xFb3a062236A7E08b572F17bc9Ad2bBc2becB87b1;
    address public AUCTION_HOUSE_12H =
        0x7AC2Ab8143634419c5bc230A9f9955C3e29f64Ef;
    address public AUCTION_HOUSE_24H =
        0x3a595B9283B96a3aA5292F7c4C64E2FcAbe7848b;

    address public CREDIT_1 = 0xD5FD8456aa96aAA07c23605e9a8d2ce5f737F145;
    address public CREDIT_3 = 0xaFBe44E79E9affB25CEd16D971933219d1d6EC8d;
    address public CREDIT_4 = 0x8D8b654E2B6A0289D8f758cBCCc42aB387c67B61;
    address public CREDIT_999999999 =
        0xcFC43e1251bD7fd2f37766c083948497B7871AEb;
    address public CREDIT_999999998 =
        0xce805022e35fd808139d7E541F10D6e83420d84B;

    // SWAP ROUTERS
    address public UNISWAP_ROUTER = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
    address public KYBER_ROUTER = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
    address public ONE_INCH_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;
    address public OPENOCEAN_ROUTER =
        0x6352a56caadC4F1E25CD6c75970Fa768A3304e64;

    function _parseEnv() internal {
        // Default behavior: use Anvil 0 private key
        PRIVATE_KEY = vm.envOr(
            "ETH_PRIVATE_KEY",
            77814517325470205911140941194401928579557062014761831930645393041380819009408
        );
    }

    function run() public {
        require(block.chainid == 42161, "Only Arbitrum is supported");
        _parseEnv();

        // allow all calls on the swap routers
        addressesToAllow.push(UNISWAP_ROUTER);
        addressesToAllow.push(KYBER_ROUTER);
        addressesToAllow.push(ONE_INCH_ROUTER);
        addressesToAllow.push(OPENOCEAN_ROUTER);

        // allow all calls on protocol contracts
        addressesToAllow.push(PSM_1);
        addressesToAllow.push(PSM_3);
        addressesToAllow.push(PSM_4);
        addressesToAllow.push(PSM_999999999);
        addressesToAllow.push(PSM_999999998);
        addressesToAllow.push(AUCTION_HOUSE_6H);
        addressesToAllow.push(AUCTION_HOUSE_12H);
        addressesToAllow.push(AUCTION_HOUSE_24H);
        addressesToAllow.push(CREDIT_1);
        addressesToAllow.push(CREDIT_3);
        addressesToAllow.push(CREDIT_4);
        addressesToAllow.push(CREDIT_999999999);
        addressesToAllow.push(CREDIT_999999998);

        // allow only approve on all tokens
        tokensToApprove.push(0xaf88d065e77c8cC2239327C5EDb3A432268e5831); // USDC
        tokensToApprove.push(0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9); // USDT
        tokensToApprove.push(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1); // WETH
        tokensToApprove.push(0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f); // WBTC
        tokensToApprove.push(0xEC70Dcb4A1EFa46b8F2D97C310C9c4790ba5ffA8); // rETH
        tokensToApprove.push(0x5979D7b546E38E414F7E9822514be443A4800529); // wstETH
        tokensToApprove.push(0x9bEcd6b4Fb076348A455518aea23d3799361FE95); // PT-weETH-25APR2024
        tokensToApprove.push(0x1c27Ad8a19Ba026ADaBD615F6Bc77158130cfBE4); // PT-weETH-27JUN2024
        tokensToApprove.push(0xAFD22F824D51Fb7EeD4778d303d4388AC644b026); // PT-rsETH-27JUN2024
        tokensToApprove.push(0x0c880f6761F1af8d9Aa9C466984b80DAb9a8c9e8); // PENDLE
        tokensToApprove.push(0x35751007a407ca6FEFfE80b3cB397736D2cf4dbe); // weETH
        tokensToApprove.push(0x912CE59144191C1204E64559FE8253a0e49E6548); // ARB
        tokensToApprove.push(0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1); // DAI
        tokensToApprove.push(0xad853EB4fB3Fe4a66CdFCD7b75922a0494955292); // PT-USDe-29AUG2024

        vm.startBroadcast(PRIVATE_KEY);
        gatewayv1 = new GatewayV1(GUILD_TOKEN_ARBITRUM);
        allowApproveOnTokens();
        allowAddresses();
        gatewayv1.transferOwnership(TEAM_MULTISIG_ADDRESS);
        vm.stopBroadcast();
    }

    function allowApproveOnTokens() public {
        for (uint256 i = 0; i < tokensToApprove.length; i++) {
            gatewayv1.allowCall(
                tokensToApprove[i],
                getSelector("approve(address,uint256)"),
                true
            );
        }
    }

    function allowAddresses() public {
        for (uint256 i = 0; i < addressesToAllow.length; i++) {
            gatewayv1.allowAddress(addressesToAllow[i], true);
        }
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
