// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ECGTest} from "@test/ECGTest.sol";

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {GatewayV1NoACL} from "@src/gateway/GatewayV1NoACL.sol";
import {Gateway} from "@src/gateway/Gateway.sol";
import {MockERC20} from "../../mock/MockERC20.sol";
import {MockERC20Gauges} from "../../mock/MockERC20Gauges.sol";

/// @title Test suite for the Gateway contract
contract UnitTestGatewayV1NoACL is ECGTest {
    uint256 public alicePrivateKey = uint256(0x42);
    address public alice = vm.addr(alicePrivateKey);

    /// @notice Address used to represent another user (Bob)
    address bob = address(0xb0bb0b);

    GatewayV1NoACL public gateway;

    /// @notice Address used as factory owner in tests
    address gatewayOwner = address(10101);

    /// @notice address of a term to test the auto allow feature
    address termAddress = address(10501);
    /// @notice Signature for an allowed function call (revertingFunction(uint256)
    bytes4 allowedSig1 = bytes4(0x826b700f);
    /// @notice Signature for an allowed function call (successfulFunction(uint256)
    bytes4 allowedSig2 = bytes4(0xb510fa5c);

    // /// @notice MockERC20 token instance used in tests
    MockERC20 mockToken;
    /// @notice Address used as an allowed target external calls
    address allowedTarget;

    MockERC20Gauges guild;

    /// @notice Retrieves the bytecode of a contract at a specific address for testing purposes
    function getCode(address _addr) public view returns (bytes memory) {
        bytes memory code;
        assembly {
            // Get the size of the code at address `_addr`
            let size := extcodesize(_addr)
            // Allocate memory for the code
            code := mload(0x40)
            // Update the free memory pointer
            mstore(0x40, add(code, and(add(add(size, 0x20), 0x1f), not(0x1f))))
            // Store the size in memory
            mstore(code, size)
            // Copy the code to memory
            extcodecopy(_addr, add(code, 0x20), 0, size)
        }
        return code;
    }

    // functions to be called by the gateway
    uint256 public amountSaved = 0;

    function revertingFunction(uint256 /*amount*/) public pure {
        revert("I told you I would revert");
    }

    function revertingFunctionWithoutMsg(uint256 /*amount*/) public pure {
        revert();
    }

    function nonAllowedFunction(uint256 amount) public {
        amountSaved = amount;
    }

    function successfulFunction(uint256 amount) public {
        amountSaved = amount;
    }

    /// @notice Sets up the test by deploying the AccountFactory contract
    function setUp() public {
        guild = new MockERC20Gauges();
        guild.addGauge(0, termAddress);
        allowedTarget = address(this);

        vm.startPrank(gatewayOwner);
        gateway = new GatewayV1NoACL(address(guild));
        vm.stopPrank();

        // set up a mockerc20
        mockToken = new MockERC20();
    }

    function testSetup() public {
        assertEq(gateway.owner(), gatewayOwner);
        assertEq(guild.isGauge(termAddress), true);
    }

    /// @notice Tests that non-owners cannot allow calls
    function testAllowCallShouldRevertIfNotOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        gateway.allowCall(address(1), 0x01020304, true);
    }

    /// @notice Tests that non-owners cannot allow calls
    function testAllowCallShouldRevertEvenIfOwner() public {
        vm.expectRevert("GatewayV1NoACL: unused function");
        vm.prank(gatewayOwner);
        gateway.allowCall(address(1), 0x01020304, true);
    }

    function _singleCallExternal(address target, bytes memory data) internal {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            target,
            data
        );
        gateway.multicall(calls);
    }

    /// @notice Ensures that calls to non-allowed targets are properly restricted
    function testCallExternalShouldWorkOnNonAllowedTarget() public {
        bytes memory data = abi.encodeWithSignature(
            "nonAllowedFunction(uint256)",
            42
        );
        assertEq(amountSaved, 0);
        _singleCallExternal(address(this), data);
        assertEq(amountSaved, 42);
    }

    /// @notice Verifies that failing external calls revert as expected
    function testCallExternalFailingShouldRevert() public {
        bytes memory data = abi.encodeWithSignature(
            "revertingFunction(uint256)",
            uint256(1000)
        );
        vm.expectRevert("I told you I would revert");
        _singleCallExternal(allowedTarget, data);
    }

    /// @notice Tests that external calls without a revert message are handled correctly
    function testCallExternalFailingShouldRevertWithoutMsg() public {
        bytes memory data = abi.encodeWithSignature(
            "revertingFunctionWithoutMsg(uint256)",
            uint256(1000)
        );
        // then call that function that revert without msg
        vm.expectRevert(bytes(""));
        _singleCallExternal(allowedTarget, data);
    }
}
