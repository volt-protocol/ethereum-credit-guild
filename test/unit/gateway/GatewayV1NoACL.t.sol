// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ECGTest} from "@test/ECGTest.sol";

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

import {Core} from "@src/core/Core.sol";
import {Gateway} from "@src/gateway/Gateway.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {GatewayV1NoACL} from "@src/gateway/GatewayV1NoACL.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {SimplePSM} from "@src/loan/SimplePSM.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {AuctionHouse} from "@src/loan/AuctionHouse.sol";
import {ProfitManager} from "@src/governance/ProfitManager.sol";
import {MockBalancerVault} from "@test/mock/MockBalancerVault.sol";
import {RateLimitedMinter} from "@src/rate-limits/RateLimitedMinter.sol";

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
