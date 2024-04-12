// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Script, console} from "@forge-std/Script.sol";
import {GatewayV1NoACL} from "@src/gateway/GatewayV1NoACL.sol";

/// @notice
/// deploy like that to verify:
/// forge script scripts/DeployGatewayNoACL.s.sol:DeployGatewayNoACL -vvvv --rpc-url {{RPC URL}} --broadcast --etherscan-api-key {ETHERSCAN KEY} --verify --verifier-url https://api-sepolia.etherscan.io/api --chain-id 11155111 --verifier etherscan --force --slow
/// forge script scripts/DeployGatewayNoACL.s.sol:DeployGatewayNoACL -vvvv --rpc-url {{RPC URL}} --broadcast --etherscan-api-key {ETHERSCAN KEY} --verify --verifier-url https://api.arbiscan.io/api --chain-id 42161 --verifier etherscan
contract DeployGatewayNoACL is Script {
    uint256 public PRIVATE_KEY;

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
        new GatewayV1NoACL();
        vm.stopBroadcast();
    }
}
