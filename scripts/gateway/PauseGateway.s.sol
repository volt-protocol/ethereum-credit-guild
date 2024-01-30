// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Script, console} from "@forge-std/Script.sol";
import {GatewayV1} from "@src/gateway/GatewayV1.sol";

contract PauseGateway is Script {
    uint256 public PRIVATE_KEY;
    address public oldGateway = 0x760Cb292043a99b867E0b994BC22071ceE958faa;

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
        GatewayV1(oldGateway).pause();
        vm.stopBroadcast();
    }
}
