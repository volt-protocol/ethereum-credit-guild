// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Script} from "@forge-std/Script.sol";

import {Arbitrum_0_BaseContracts as p0} from "@test/proposals/gips/Arbitrum_0_BaseContracts.sol";
import {Arbitrum_1_MarketUSDCTest as p1} from "@test/proposals/gips/Arbitrum_1_MarketUSDCTest.sol";
import {IntegrationTestRoles} from "@test/integration/IntegrationTestRoles.sol";

contract DeployArbitrum is Script, p0, p1 {
    uint256 public PRIVATE_KEY;

    function _parseEnv() internal {
        // Default behavior: do debug prints
        DEBUG = vm.envOr("DEBUG", true);
        // Default behavior: use Anvil 0 private key
        PRIVATE_KEY = vm.envOr(
            "ETH_PRIVATE_KEY",
            77814517325470205911140941194401928579557062014761831930645393041380819009408
        );
    }

    function run() public {
        _parseEnv();
        address deployerAddress = vm.addr(PRIVATE_KEY);
        vm.startBroadcast(PRIVATE_KEY);

        p0.deploy();
        p0.afterDeploy(deployerAddress);
        p1.deploy();
        p1.afterDeploy(deployerAddress);

        vm.stopBroadcast();

        IntegrationTestRoles test = new IntegrationTestRoles();
        test.testCurrentRoles();
    }

    function name() public pure override(p0, p1) returns (string memory) {
        return "DeployProposal";
    }

    function deploy() public pure override(p0, p1) {}

    function afterDeploy(address deployer) public pure override(p0, p1) {}

    function run(address deployer) public pure override(p0, p1) {}

    function teardown(address deployer) public pure override(p0, p1) {}

    function validate(address deployer) public pure override(p0, p1) {}
}
