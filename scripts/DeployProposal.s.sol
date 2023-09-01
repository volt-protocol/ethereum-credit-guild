// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {console} from "@forge-std/console.sol";
import {Proposal_0 as proposal} from "@test/proposals/Proposal_0.sol";
import {Script} from "@forge-std/Script.sol";
import {Addresses} from "@test/proposals/Addresses.sol";

contract DeployProposal is Script, proposal {
    uint256 public PRIVATE_KEY;
    bool public DO_DEPLOY;
    bool public DO_AFTERDEPLOY;
    bool public DO_TEARDOWN;

    function _parseEnv() internal {
        // Default behavior: do debug prints
        DEBUG = vm.envOr("DEBUG", true);
        // Default behavior: use Anvil 0 private key
        PRIVATE_KEY = vm.envOr(
            "ETH_PRIVATE_KEY",
            77814517325470205911140941194401928579557062014761831930645393041380819009408
        );
        // Default behavior: do all steps
        // Environment variables can skip some of them.
        DO_DEPLOY = vm.envOr("DO_DEPLOY", true);
        DO_AFTERDEPLOY = vm.envOr("DO_AFTERDEPLOY", true);
        DO_TEARDOWN = vm.envOr("DO_TEARDOWN", true);
    }

    function run() public {
        _parseEnv();
        Addresses addresses = new Addresses();
        addresses.resetRecordingAddresses();
        address deployerAddress = vm.addr(PRIVATE_KEY);

        vm.startBroadcast(PRIVATE_KEY);
        if (DO_DEPLOY) deploy(addresses);
        if (DO_AFTERDEPLOY) afterDeploy(addresses, deployerAddress);
        if (DO_TEARDOWN) teardown(addresses, deployerAddress);
        vm.stopBroadcast();

        if (DO_DEPLOY) {
            (
                string[] memory recordedNames,
                address[] memory recordedAddresses
            ) = addresses.getRecordedAddresses();
            for (uint256 i = 0; i < recordedNames.length; i++) {
                console.log("Deployed", recordedAddresses[i], recordedNames[i]);
            }
        }
    }
}
