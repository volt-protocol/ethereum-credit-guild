// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ECGTest} from "@test/ECGTest.sol";
import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";

contract CoreUnitTest is ECGTest {
    Core private core;

    function setUp() public {
        core = new Core();
        vm.label(address(core), "core");
    }

    // on deployment, deployer has GOVERNOR role
    function testInitialState() public {
        assertTrue(core.hasRole(CoreRoles.GOVERNOR, address(this)));
    }

    // can create new roles
    function testCreateNewRole() public {
        assertEq(core.getRoleAdmin(bytes32(uint256(12345))), bytes32(0));
        core.createRole(bytes32(uint256(12345)), CoreRoles.GOVERNOR);
        assertEq(
            core.getRoleAdmin(bytes32(uint256(12345))),
            CoreRoles.GOVERNOR
        );

        // non-governor cannot create roles
        vm.prank(address(0xabcdef));
        vm.expectRevert();
        core.createRole(bytes32(uint256(67890)), CoreRoles.GOVERNOR);
    }

    // can override hierarchy of existing roles
    function testOverrideHierarchy() public {
        assertEq(core.getRoleAdmin(CoreRoles.GUARDIAN), CoreRoles.GOVERNOR);
        core.createRole(CoreRoles.GUARDIAN, bytes32(uint256(12345)));
        assertEq(
            core.getRoleAdmin(CoreRoles.GUARDIAN),
            bytes32(uint256(12345))
        );
    }

    // can batch grant roles
    function testBatchGrant() public {
        bytes32[] memory roles = new bytes32[](2);
        address[] memory addrs = new address[](2);

        roles[0] = CoreRoles.GUARDIAN;
        roles[1] = CoreRoles.GOVERNOR;
        addrs[0] = address(0xaaaa);
        addrs[1] = address(0xbbbb);
        core.grantRoles(roles, addrs);
        assertTrue(core.hasRole(CoreRoles.GUARDIAN, address(0xaaaa)));
        assertTrue(core.hasRole(CoreRoles.GOVERNOR, address(0xbbbb)));

        // if caller is not admin of any of the granted roles, revert
        roles[1] = bytes32(uint256(12345));
        vm.expectRevert();
        core.grantRoles(roles, addrs);

        // length mismatch
        addrs = new address[](1);
        vm.expectRevert();
        core.grantRoles(roles, addrs);
    }
}
