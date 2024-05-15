// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ECGTest} from "@test/ECGTest.sol";
import {GatewayV1NoACL} from "@src/gateway/GatewayV1NoACL.sol";

/// @title Test suite for the GatewayV1 contract
contract UnitTestGatewayV1NoACL is ECGTest {
    // test users
    address gatewayOwner = address(10101);
    GatewayV1NoACL public gatewayv1;

    function revertingFunction(uint256 /*amount*/) public pure {
        revert("I told you I would revert");
    }

    /// @notice Sets up the test by deploying the AccountFactory contract
    function setUp() public {
        vm.prank(gatewayOwner);
        gatewayv1 = new GatewayV1NoACL();
    }

    function _singleCallExternal(address target, bytes memory data) internal {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            target,
            data
        );
        gatewayv1.multicall(calls);
    }

    /// @notice Ensures that calls to non-allowed targets are properly restricted
    function testAllowCallCannotWork() public {
        
        vm.prank(gatewayOwner);
        vm.expectRevert("GatewayV1NoACL: unused function");
        gatewayv1.allowCall(address(1),bytes4(keccak256("randomFunction(uint256)")), true);
    }

    /// @notice Verifies that failing external calls revert as expected
    function testCallExternalFailingShouldRevert() public {
        bytes memory data = abi.encodeWithSignature(
            "revertingFunction(uint256)",
            uint256(1000)
        );
        vm.expectRevert("I told you I would revert");
        _singleCallExternal(address(this), data);
    }

    /// @notice Ensures that calls to non-allowed targets are properly restricted
    function testCallExternalShouldWork() public {
        bytes memory data = abi.encodeWithSignature(
            "nonAllowedFunction(uint256,string)",
            42,
            "Hello"
        );
        _singleCallExternal(address(1), data);
    }

    /// @notice Ensures that calls to non-allowed targets are properly restricted
    function testTransferFromShouldNotWork() public {
        bytes memory data = abi.encodeWithSignature(
            "transferFrom(address,address,uint256)",
            address(1),
            address(2),
            1e18
        );

        vm.expectRevert("GatewayV1NoACL: cannot call transferFrom");
        _singleCallExternal(address(1), data);
    }
    
}
