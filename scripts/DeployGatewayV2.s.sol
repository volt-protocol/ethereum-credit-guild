// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.24;

import {Script} from "@forge-std/Script.sol";
import {GatewayV2} from "@src/gateway/v2/GatewayV2.sol";

// ETHERSCAN_API_KEY=$ARBISCAN_API_KEY ETH_PRIVATE_KEY=$ETH_PRIVATE_KEY forge script scripts/DeployGatewayV2.s.sol -vvvv --rpc-url $ARB_RPC_URL --with-gas-price 20000000 --memory-limit 32000000000 --verify --verifier-url https://api.arbiscan.io/api --broadcast
contract DeployGatewayV2 is Script {
    uint256 public PRIVATE_KEY;

    function _parseEnv() internal {
        PRIVATE_KEY = vm.envOr(
            "ETH_PRIVATE_KEY",
            77814517325470205911140941194401928579557062014761831930645393041380819009408
        );
    }

    function run() public {
        _parseEnv();

        vm.startBroadcast(PRIVATE_KEY);
        new GatewayV2();
        vm.stopBroadcast();
    }
}
