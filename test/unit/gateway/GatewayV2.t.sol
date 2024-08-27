// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.24;

import {ECGTest, console} from "@test/ECGTest.sol";

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
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

    function revertWithMessage(string memory message) public pure {
        revert(message);
    }

    function testActionWithFlashLoan() public {
        // allowlist configuration
        gw.allowCall(address(token1), 0x40c10f19, true); // mint(address,uint256)
        gw.allowCall(address(this), 0x58b80a4b, true); // initiateToken1UniswapV3Flashloan(uint256)

        // build actions
        bytes[] memory withFlashloanCalls = new bytes[](2);
        // arbitrary action
        withFlashloanCalls[0] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            address(token1),
            abi.encodeWithSignature(
                "mint(address,uint256)",
                address(gw),
                67
            )
        );
        // repay flashloan
        withFlashloanCalls[1] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            address(token1),
            abi.encodeWithSignature(
                "transfer(address,uint256)",
                address(this),
                1100
            )
        );

        // do action with flashloan
        gw.actionWithFlashLoan(
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
                "multicall(bytes[])",
                withFlashloanCalls
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

    function testPausability() public {
        gw.pause();
        vm.expectRevert("Pausable: paused");
        gw.action(
            abi.encodeWithSignature(
                "callExternal(address,bytes)",
                address(token1),
                abi.encodeWithSignature(
                    "mint(address,uint256)",
                    address(this),
                    123
                )
            )
        );
        gw.unpause();
        gw.action(
            abi.encodeWithSignature(
                "callExternal(address,bytes)",
                address(token1),
                abi.encodeWithSignature(
                    "mint(address,uint256)",
                    address(this),
                    123
                )
            )
        );
        assertEq(token1.balanceOf(address(this)), 123);
    }

    function testCheckBalanceAtLeast() public {
        vm.expectRevert("GatewayV2: token balance too low");
        gw.action(
            abi.encodeWithSignature(
                "checkBalanceAtLeast(address,uint256)",
                address(token1),
                100
            )
        );
        token1.mint(address(gw), 100);
        gw.action(
            abi.encodeWithSignature(
                "checkBalanceAtLeast(address,uint256)",
                address(token1),
                100
            )
        );
    }

    function testPullPermitTokens() public {
        uint256 amount = 1000;
        uint256 deadline = block.timestamp + 100;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                ),
                alice,
                address(gw),
                amount,
                token1.nonces(alice),
                deadline
            )
        );
        bytes32 digest = ECDSA.toTypedDataHash(
            token1.DOMAIN_SEPARATOR(),
            structHash
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, digest);

        token1.mint(alice, amount);

        vm.prank(alice);
        gw.action(
            abi.encodeWithSignature(
                "consumePermit(address,uint256,uint256,uint8,bytes32,bytes32)",
                address(token1),
                amount,
                deadline,
                v,
                r,
                s
            )
        );
        
        assertEq(token1.balanceOf(alice), amount);
        assertEq(token1.balanceOf(address(gw)), 0);
        assertEq(token1.allowance(alice, address(gw)), amount);

        // someone else cannot transferFrom alice's tokens
        vm.expectRevert("GatewayV2: forbidden external call");
        gw.action(
            abi.encodeWithSignature(
                "callExternal(address,bytes)",
                address(token1),
                abi.encodeWithSignature(
                    "transferFrom(address,address,uint256)",
                    alice,
                    bob,
                    amount
                )
            )
        );

        vm.prank(alice);
        gw.action(
            abi.encodeWithSignature(
                "consumeAllowance(address,uint256)",
                address(token1),
                amount
            )
        );

        assertEq(token1.balanceOf(alice), 0);
        assertEq(token1.balanceOf(address(gw)), amount);
        assertEq(token1.allowance(alice, address(gw)), 0);

        gw.action(
            abi.encodeWithSignature(
                "sweep(address)",
                address(token1)
            )
        );

        assertEq(token1.balanceOf(address(this)), amount);
        assertEq(token1.balanceOf(alice), 0);
        assertEq(token1.balanceOf(address(gw)), 0);
    }

    function testErrorForwarding() public {
        vm.expectRevert("test error");
        gw.action(
            abi.encodeWithSignature(
                "callExternal(address,bytes)",
                address(this),
                abi.encodeWithSignature(
                    "revertWithMessage(string)",
                    "test error"
                )
            )
        );
    }
}
