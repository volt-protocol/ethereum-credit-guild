// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.24;

import {ECGTest, console} from "@test/ECGTest.sol";

import {GatewayV2} from "@src/gateway/v2/GatewayV2.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";

contract GatewayV2UnitTest is ECGTest {
    // test users
    uint256 public alicePrivateKey = uint256(0x42);
    address public alice = vm.addr(alicePrivateKey);
    address bob = address(0xb0bb0b);

    GatewayV2 public gw;
    MockERC20 token1;

    function setUp() public {
        gw = new GatewayV2();
        token1 = new MockERC20();

        // labels
        vm.label(address(this), "test");
        vm.label(alice, "alice");
        vm.label(bob, "bob");
        vm.label(address(gw), "gw");
        vm.label(address(token1), "token1");
    }

    // mock flashloan initiator function
    // 0x58b80a4b selector
    function initiateToken1UniswapV3Flashloan(uint256 amount) public {
        token1.mint(msg.sender, amount);
        (bool success, ) = msg.sender.call(abi.encodeWithSignature(
            "uniswapV3FlashCallback(uint256,uint256,bytes)",
            0,
            0,
            ""
        ));
        require(success, "Flashloan call reverted");
        require(token1.balanceOf(address(this)) >= amount * 110 / 100, "Flashloan not repaid");
        token1.burn(amount * 110 / 100);
    }

    function testActionWithFlashLoan() public {
        // allowlist configuration
        gw.allowByAddress(address(token1), true);
        gw.allowBySelector(address(this), 0x58b80a4b, true);

        gw.actionWithFlashLoan(
            address(token1), // flashloanToken
            1000, // flashloanAmount
            100, // flashloanFee
            address(this), // flashloanProvider
            abi.encodeWithSignature("initiateToken1UniswapV3Flashloan(uint256)", 1000), // initiateFlashloanCall
            abi.encodeWithSignature( // preFlashloanCall
                "callExternal(address,bytes)",
                address(token1),
                abi.encodeWithSignature(
                    "mint(address,uint256)",
                    address(gw),
                    33
                )
            ),
            abi.encodeWithSignature( // withFlashloanCall
                "callExternal(address,bytes)",
                address(token1),
                abi.encodeWithSignature(
                    "mint(address,uint256)",
                    address(gw),
                    67
                )
            ),
            abi.encodeWithSignature( // postFlashloanCall
                "callExternal(address,bytes)",
                address(token1),
                abi.encodeWithSignature(
                    "mint(address,uint256)",
                    address(gw),
                    123
                )
            )
        );
        assertEq(token1.balanceOf(address(gw)), 123);
    }
}
