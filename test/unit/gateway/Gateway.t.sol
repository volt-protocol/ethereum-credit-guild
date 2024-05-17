// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ECGTest} from "@test/ECGTest.sol";

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {GatewayV1} from "@src/gateway/GatewayV1.sol";
import {Gateway} from "@src/gateway/Gateway.sol";
import {MockERC20} from "../../mock/MockERC20.sol";
import {MockERC20Gauges} from "../../mock/MockERC20Gauges.sol";

/// @title Test suite for the Gateway contract
contract UnitTestGatewayGeneric is ECGTest {
    uint256 public alicePrivateKey = uint256(0x42);
    address public alice = vm.addr(alicePrivateKey);

    /// @notice Address used to represent another user (Bob)
    address bob = address(0xb0bb0b);

    GatewayV1 public gateway;

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
    uint256 public amountSaved;

    function nonAllowedFunction(uint256 amount, string memory /*str*/) public {
        amountSaved = amount;
    }

    function revertingFunction(uint256 /*amount*/) public pure {
        revert("I told you I would revert");
    }

    function revertingFunctionWithoutMsg(uint256 /*amount*/) public pure {
        revert();
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
        gateway = new GatewayV1(address(guild));
        gateway.allowCall(allowedTarget, allowedSig1, true);
        gateway.allowCall(allowedTarget, allowedSig2, true);
        vm.stopPrank();

        // set up a mockerc20
        mockToken = new MockERC20();
    }

    /// @notice Tests the initial state of the AccountFactory contract
    /// @param target The address to be tested with allowedCalls
    /// @param functionSelector The function selector to be tested with allowedCalls
    function testSetup(address target, bytes4 functionSelector) public {
        vm.assume(target != allowedTarget);

        assertEq(gateway.owner(), gatewayOwner);
        assertEq(gateway.allowedCalls(allowedTarget, allowedSig1), true);
        assertEq(gateway.allowedCalls(allowedTarget, allowedSig2), true);

        // allowedCalls should return false for any calls by default except the one whitelisted
        assertEq(gateway.allowedCalls(target, functionSelector), false);

        assertEq(guild.isGauge(termAddress), true);
    }

    /// @notice Tests that non-owners cannot allow calls
    function testAllowCallShouldRevertIfNotOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        gateway.allowCall(address(1), 0x01020304, true);
    }

    /// @notice Tests that non-owners cannot allow calls
    function testAllowAddressShouldRevertIfNotOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        gateway.allowAddress(address(1), true);
    }

    /// @notice Tests that transferFrom cannot be allowed
    function testAllowCallShouldRevertIfTransferFrom() public {
        vm.prank(gatewayOwner);
        vm.expectRevert("Gateway: cannot allow transferFrom");
        gateway.allowCall(address(1), 0x23b872dd, true);
    }

    function testAllowAddressShouldWorkIfOwner(address target) public {
        vm.prank(gatewayOwner);
        gateway.allowAddress(target, true);
        assertEq(gateway.allowedAddresses(target), true);
        vm.prank(gatewayOwner);
        gateway.allowAddress(target, false);
        assertEq(gateway.allowedAddresses(target), false);
    }

    /// @notice Tests that the gateway owner can successfully allow and disallow calls
    /// @param a1 The first address to test call allowance
    /// @param s1 The first function selector to test call allowance
    /// @param a2 The second address to test call allowance
    /// @param s2 The second function selector to test call allowance
    function testAllowDisallowCallAsOwnerShouldWork(
        address a1,
        bytes4 s1,
        address a2,
        bytes4 s2
    ) public {
        vm.assume(a1 != a2);
        vm.assume(a1 != allowedTarget);
        vm.assume(a2 != allowedTarget);
        vm.assume(
            s1 != bytes4(keccak256("transferFrom(address,address,uint256)"))
        );
        vm.assume(
            s2 != bytes4(keccak256("transferFrom(address,address,uint256)"))
        );
        vm.startPrank(gatewayOwner);
        assertEq(gateway.allowedCalls(a1, s1), false);
        assertEq(gateway.allowedCalls(a2, s2), false);
        gateway.allowCall(a1, s1, true);
        gateway.allowCall(a2, s2, true);
        assertEq(gateway.allowedCalls(a1, s1), true);
        assertEq(gateway.allowedCalls(a2, s2), true);
        gateway.allowCall(a2, s2, false);
        assertEq(gateway.allowedCalls(a1, s1), true);
        assertEq(gateway.allowedCalls(a2, s2), false);
        vm.stopPrank();
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
    function testCallExternalShouldWorkOnAllowedAddress() public {
        vm.prank(gatewayOwner);
        gateway.allowAddress(address(this), true);
        assertEq(gateway.allowedAddresses(address(this)), true);

        bytes memory data = abi.encodeWithSignature(
            "nonAllowedFunction(uint256,string)",
            42,
            "Hello"
        );
        _singleCallExternal(address(this), data);
        assertEq(amountSaved, 42);
    }

    /// @notice Ensures that calls to non-allowed targets are properly restricted
    function testCallExternalShouldFailOnNonAllowedTarget() public {
        bytes memory data = abi.encodeWithSignature(
            "nonAllowedFunction(uint256,string)",
            42,
            "Hello"
        );
        vm.expectRevert("Gateway: cannot call target");
        _singleCallExternal(address(1), data);
    }

    /// @notice Checks that calls with non-allowed signatures are prohibited
    function testCallExternalShouldFailOnNonAllowedSignature() public {
        bytes memory data = abi.encodeWithSignature(
            "nonAllowedFunction(uint256,string)",
            42,
            "Hello"
        );
        vm.expectRevert("Gateway: cannot call target");
        _singleCallExternal(allowedTarget, data);
    }

    /// @notice Checks that calls with non-allowed signatures are prohibited
    function testCallExternalShouldWorkOnNonAllowedSignature() public {
        bytes memory data = abi.encodeWithSignature(
            "nonAllowedFunction(uint256,string)",
            42,
            "Hello"
        );

        _singleCallExternal(termAddress, data);
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
        bytes4 functionSelector = bytes4(
            keccak256("revertingFunctionWithoutMsg(uint256)")
        );
        vm.prank(gatewayOwner);
        // allow "revertingFunctionWithoutMsg(uint256)"
        gateway.allowCall(allowedTarget, functionSelector, true);

        // then call that function that revert without msg
        vm.expectRevert(bytes(""));
        _singleCallExternal(allowedTarget, data);
    }

    /// @notice Confirms successful execution of allowed external calls
    function testCallExternalSuccessShouldWork() public {
        assertEq(0, amountSaved);
        bytes memory data = abi.encodeWithSignature(
            "successfulFunction(uint256)",
            uint256(1000)
        );

        vm.prank(alice);
        _singleCallExternal(allowedTarget, data);
        assertEq(1000, amountSaved);
    }

    /// @notice Confirms that call external cannot be called when paused
    function testCallExternalCannotWorkWhenPaused() public {
        assertEq(0, amountSaved);
        bytes memory data = abi.encodeWithSignature(
            "successfulFunction(uint256)",
            uint256(1000)
        );
        vm.prank(gatewayOwner);
        gateway.pause();

        vm.prank(alice);
        vm.expectRevert("Pausable: paused");
        _singleCallExternal(allowedTarget, data);
    }

    function testPauseCanOnlyBeDoneByOwner() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        gateway.pause();
    }

    function testUnPauseCanOnlyBeDoneByOwner() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        gateway.unpause();
    }

    function testCallExternalCanPauseUnpause() public {
        assertEq(0, amountSaved);
        bytes memory data = abi.encodeWithSignature(
            "successfulFunction(uint256)",
            uint256(1000)
        );
        vm.prank(gatewayOwner);
        gateway.pause();

        vm.prank(alice);
        vm.expectRevert("Pausable: paused");
        _singleCallExternal(allowedTarget, data);

        vm.prank(gatewayOwner);
        gateway.unpause();

        vm.prank(alice);
        _singleCallExternal(allowedTarget, data);
    }

    function testMulticall() public {
        mockToken.mint(alice, 1000e18);

        // alice will approve 1000 token to the gateway
        // and then transfer them via the gateway to bob
        vm.prank(alice);
        mockToken.approve(address(gateway), 1000e18);

        // for the test, allow transfer function on the mockToken
        vm.prank(gatewayOwner);
        gateway.allowCall(
            address(mockToken),
            bytes4(keccak256("transfer(address,uint256)")),
            true
        );

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSignature(
            "consumeAllowance(address,uint256)", // token, amount
            address(mockToken),
            1000e18
        );

        // send tokens to bob
        calls[1] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            address(mockToken),
            abi.encodeWithSignature(
                "transfer(address,uint256)",
                bob,
                uint256(1000e18)
            )
        );

        vm.prank(alice);
        gateway.multicall(calls);

        assertEq(mockToken.balanceOf(bob), 1000e18);
    }

    function getPermitDataFromAlice(
        MockERC20 _mockToken,
        uint256 amount,
        address to
    ) public returns (uint8 v, bytes32 r, bytes32 s, uint256 deadline) {
        deadline = block.timestamp + 100;
        // sign permit message valid for 10s
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                ),
                alice,
                to,
                amount,
                _mockToken.nonces(alice),
                deadline
            )
        );

        bytes32 digest = ECDSA.toTypedDataHash(
            _mockToken.DOMAIN_SEPARATOR(),
            structHash
        );

        (v, r, s) = vm.sign(alicePrivateKey, digest);
        assertEq(ECDSA.recover(digest, v, r, s), alice);
    }

    function testMulticallWithPermit() public {
        mockToken.mint(alice, 1000e18);

        (
            uint8 v,
            bytes32 r,
            bytes32 s,
            uint256 deadline
        ) = getPermitDataFromAlice(mockToken, 1000e18, address(gateway));

        // for the test, allow transfer function on the mockToken
        vm.prank(gatewayOwner);
        gateway.allowCall(
            address(mockToken),
            bytes4(keccak256("transfer(address,uint256)")),
            true
        );

        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeWithSignature(
            "consumePermit(address,uint256,uint256,uint8,bytes32,bytes32)", // token, amount
            address(mockToken),
            1000e18,
            deadline,
            v,
            r,
            s
        );
        calls[1] = abi.encodeWithSignature(
            "consumeAllowance(address,uint256)", // token, amount
            address(mockToken),
            1000e18
        );

        // send tokens to bob
        calls[2] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            address(mockToken),
            abi.encodeWithSignature(
                "transfer(address,uint256)",
                bob,
                uint256(1000e18)
            )
        );

        vm.prank(alice);
        gateway.multicall(calls);

        assertEq(mockToken.balanceOf(bob), 1000e18);
    }

    function testMulticallWithSweep() public {
        mockToken.mint(alice, 1000e18);

        // alice will approve 1000 token to the gateway
        // and then transfer them via the gateway to bob
        vm.prank(alice);
        mockToken.approve(address(gateway), 1000e18);

        // for the test, allow transfer function on the mockToken
        vm.prank(gatewayOwner);
        gateway.allowCall(
            address(mockToken),
            bytes4(keccak256("transfer(address,uint256)")),
            true
        );

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSignature(
            "consumeAllowance(address,uint256)", // token, amount
            address(mockToken),
            1000e18
        );

        // sweep tokens to alice
        calls[1] = abi.encodeWithSignature(
            "sweep(address)", // token
            address(mockToken)
        );

        vm.prank(alice);
        gateway.multicall(calls);

        assertEq(mockToken.balanceOf(address(gateway)), 0);
        assertEq(mockToken.balanceOf(alice), 1000e18);
    }

    function testBobCannotSpendAliceTokens() public {
        mockToken.mint(alice, 1000e18);

        // alice will approve 1000 token to the gateway
        // and then transfer them via the gateway to bob
        vm.prank(alice);
        mockToken.approve(address(gateway), 1000e18);

        // for the test, allow transfer function on the mockToken
        vm.prank(gatewayOwner);
        gateway.allowCall(
            address(mockToken),
            bytes4(keccak256("transfer(address,uint256)")),
            true
        );

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSignature(
            "consumeAllowance(address,uint256)", // token, amount
            address(mockToken),
            1000e18
        );

        // send tokens to bob
        calls[1] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            address(mockToken),
            abi.encodeWithSignature(
                "transfer(address,uint256)",
                bob,
                uint256(1000e18)
            )
        );

        vm.prank(bob);
        vm.expectRevert("ERC20: insufficient allowance");
        gateway.multicall(calls);
    }
}
