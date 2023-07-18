// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Test} from "@forge-std/Test.sol";
import {MockERC20RebaseDistributor} from "@test/mock/MockERC20RebaseDistributor.sol";

contract ERC20RebaseDistributorUnitTest is Test {
    MockERC20RebaseDistributor token;

    address constant alice = address(0x616c696365);
    address constant bobby = address(0xb0b);
    address constant carol = address(0xca201);

    function setUp() public {
        vm.warp(1679067867);
        vm.roll(16848497);
        token = new MockERC20RebaseDistributor();
        vm.label(address(this), "test");
        vm.label(address(token), "token");
        vm.label(alice, "alice");
        vm.label(bobby, "bobby");
        vm.label(carol, "carol");
    }

    function testInitialState() public {
        assertEq(token.totalSupply(), 0);
        assertEq(token.rebasingSupply(), 0);
        assertEq(token.isRebasing(alice), false);
        assertEq(token.isRebasing(bobby), false);
        assertEq(token.isRebasing(carol), false);
    }

    function testEnterRebase() public {
        vm.prank(alice);
        token.enterRebase();

        assertEq(token.isRebasing(alice), true);
        assertEq(token.rebasingSupply(), 0);

        token.mint(alice, 100);
        assertEq(token.totalSupply(), 100);
        assertEq(token.rebasingSupply(), 100);

        // cannot enter twice
        vm.expectRevert("ERC20RebaseDistributor: already rebasing");
        vm.prank(alice);
        token.enterRebase();
    }

    function testExitRebase() public {
        vm.prank(alice);
        token.enterRebase();

        assertEq(token.isRebasing(alice), true);
        assertEq(token.rebasingSupply(), 0);

        token.mint(alice, 100);
        assertEq(token.totalSupply(), 100);
        assertEq(token.rebasingSupply(), 100);

        vm.prank(alice);
        token.exitRebase();

        assertEq(token.isRebasing(alice), false);
        assertEq(token.rebasingSupply(), 0);

        // cannot exit twice
        vm.expectRevert("ERC20RebaseDistributor: not rebasing");
        vm.prank(alice);
        token.exitRebase();
    }

    function testDistribute() public {
        // initial state: 2 addresses rebasing, 1 not rebasing, all addresses have 100 tokens
        vm.prank(alice);
        token.enterRebase();
        vm.prank(bobby);
        token.enterRebase();
        token.mint(alice, 100);
        token.mint(bobby, 100);
        token.mint(carol, 100);
        assertEq(token.totalSupply(), 300);
        assertEq(token.nonRebasingSupply(), 100);
        assertEq(token.rebasingSupply(), 200);

        // distribute 100 profits
        token.mint(address(this), 100);
        token.approve(address(token), 100);
        token.distribute(100);

        // check new balances and supply
        assertEq(token.balanceOf(alice), 150);
        assertEq(token.balanceOf(bobby), 150);
        assertEq(token.balanceOf(carol), 100);
        assertEq(token.totalSupply(), 400);
        assertEq(token.nonRebasingSupply(), 100);
        assertEq(token.rebasingSupply(), 300);

        // distribute 100 profits
        token.mint(address(this), 100);
        token.approve(address(token), 100);
        token.distribute(100);

        // check new balances and supply
        assertEq(token.balanceOf(alice), 200);
        assertEq(token.balanceOf(bobby), 200);
        assertEq(token.balanceOf(carol), 100);
        assertEq(token.totalSupply(), 500);
        assertEq(token.nonRebasingSupply(), 100);
        assertEq(token.rebasingSupply(), 400);

        // bobby exits rebase
        vm.prank(bobby);
        token.exitRebase();

        // check new balances and supply
        assertEq(token.balanceOf(alice), 200);
        assertEq(token.balanceOf(bobby), 200);
        assertEq(token.balanceOf(carol), 100);
        assertEq(token.totalSupply(), 500);
        assertEq(token.nonRebasingSupply(), 300);
        assertEq(token.rebasingSupply(), 200);

        // carol enters rebase
        vm.prank(carol);
        token.enterRebase();

        // check new balances and supply
        assertEq(token.balanceOf(alice), 200);
        assertEq(token.balanceOf(bobby), 200);
        assertEq(token.balanceOf(carol), 100);
        assertEq(token.totalSupply(), 500);
        assertEq(token.nonRebasingSupply(), 200);
        assertEq(token.rebasingSupply(), 300);

        // distribute 300 profits
        // should give 200 to Alice and 100 to Carol, not 150 each,
        // to have an auto-compounding logic.
        token.mint(address(this), 300);
        token.approve(address(token), 300);
        token.distribute(300);

        // check new balances and supply
        assertEq(token.balanceOf(alice), 400);
        assertEq(token.balanceOf(bobby), 200);
        assertEq(token.balanceOf(carol), 200);
        assertEq(token.totalSupply(), 800);
        assertEq(token.nonRebasingSupply(), 200);
        assertEq(token.rebasingSupply(), 600);

        // everyone exits rebase
        vm.prank(alice);
        token.exitRebase();
        vm.prank(carol);
        token.exitRebase();

        // check new balances and supply
        assertEq(token.balanceOf(alice), 400);
        assertEq(token.balanceOf(bobby), 200);
        assertEq(token.balanceOf(carol), 200);
        assertEq(token.totalSupply(), 800);
        assertEq(token.nonRebasingSupply(), 800);
        assertEq(token.rebasingSupply(), 0);

        // should not allow distribution of profits if nobody is going to receive
        token.mint(address(this), 100);
        token.approve(address(token), 100);
        vm.expectRevert("ERC20RebaseDistributor: no rebase recipients");
        token.distribute(100);
    }

    function testMint() public {
        // initial state: 2 addresses with 100 tokens, 1 rebasing, the other not
        vm.prank(alice);
        token.enterRebase();

        assertEq(token.isRebasing(alice), true);
        assertEq(token.isRebasing(bobby), false);

        token.mint(alice, 100);
        token.mint(bobby, 100);

        // minting should keep rebasing status
        assertEq(token.isRebasing(alice), true);
        assertEq(token.isRebasing(bobby), false);
        
        // check balances
        assertEq(token.balanceOf(alice), 100);
        assertEq(token.balanceOf(bobby), 100);
    }

    function testBurn() public {
        // initial state: 2 addresses with 100 tokens, 1 rebasing, the other not
        vm.prank(alice);
        token.enterRebase();
        token.mint(alice, 100);
        token.mint(bobby, 100);

        assertEq(token.isRebasing(alice), true);
        assertEq(token.isRebasing(bobby), false);
        
        vm.prank(alice);
        token.burn(100);
        vm.prank(bobby);
        token.burn(100);

        // burning should keep rebasing status
        assertEq(token.isRebasing(alice), true);
        assertEq(token.isRebasing(bobby), false);
        
        // check balances
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bobby), 0);
    }

    function testTransfer() public {
        // initial state: 2 addresses with 100 tokens, 1 rebasing, the other not
        vm.prank(alice);
        token.enterRebase();
        token.mint(alice, 100);
        token.mint(bobby, 100);

        assertEq(token.isRebasing(alice), true);
        assertEq(token.isRebasing(bobby), false);
        assertEq(token.totalSupply(), 200);
        assertEq(token.rebasingSupply(), 100);
        assertEq(token.nonRebasingSupply(), 100);
        
        vm.prank(alice);
        token.transfer(bobby, 50);

        // transfer should keep rebasing status
        assertEq(token.isRebasing(alice), true);
        assertEq(token.isRebasing(bobby), false);
        assertEq(token.balanceOf(alice), 50);
        assertEq(token.balanceOf(bobby), 150);
        assertEq(token.totalSupply(), 200);
        assertEq(token.rebasingSupply(), 50);
        assertEq(token.nonRebasingSupply(), 150);

        vm.prank(bobby);
        token.transfer(alice, 100);

        // transfer should keep rebasing status
        assertEq(token.isRebasing(alice), true);
        assertEq(token.isRebasing(bobby), false);
        assertEq(token.balanceOf(alice), 150);
        assertEq(token.balanceOf(bobby), 50);
        assertEq(token.totalSupply(), 200);
        assertEq(token.rebasingSupply(), 150);
        assertEq(token.nonRebasingSupply(), 50);
    }

    function testTransferFrom() public {
        // initial state: 2 addresses with 100 tokens, 1 rebasing, the other not
        vm.prank(alice);
        token.enterRebase();
        token.mint(alice, 100);
        token.mint(bobby, 100);

        // approve each other to move the tokens of the other
        vm.prank(alice);
        token.approve(bobby, 100);
        vm.prank(bobby);
        token.approve(alice, 100);

        assertEq(token.isRebasing(alice), true);
        assertEq(token.isRebasing(bobby), false);
        
        vm.prank(alice);
        token.transferFrom(bobby, alice, 50);

        // transferFrom should keep rebasing status
        assertEq(token.isRebasing(alice), true);
        assertEq(token.isRebasing(bobby), false);
        assertEq(token.balanceOf(alice), 150);
        assertEq(token.balanceOf(bobby), 50);

        vm.prank(bobby);
        token.transferFrom(alice, bobby, 100);

        // transferFrom should keep rebasing status
        assertEq(token.isRebasing(alice), true);
        assertEq(token.isRebasing(bobby), false);
        assertEq(token.balanceOf(alice), 50);
        assertEq(token.balanceOf(bobby), 150);
    }

    function testMovementsAfterDistribute() public {
        // initial state: 2 addresses with 100 tokens, 1 rebasing, the other not
        vm.prank(alice);
        token.enterRebase();
        token.mint(alice, 100);
        token.mint(bobby, 100);

        // check initial state
        assertEq(token.isRebasing(alice), true);
        assertEq(token.isRebasing(bobby), false);
        assertEq(token.balanceOf(alice), 100);
        assertEq(token.balanceOf(bobby), 100);
        assertEq(token.totalSupply(), 200);
        assertEq(token.rebasingSupply(), 100);
        assertEq(token.nonRebasingSupply(), 100);

        // distribute 100 profits
        token.mint(address(this), 100);
        token.approve(address(token), 100);
        token.distribute(100);

        // check balances
        assertEq(token.balanceOf(alice), 200);
        assertEq(token.balanceOf(bobby), 100);
        assertEq(token.totalSupply(), 300);
        assertEq(token.rebasingSupply(), 200);
        assertEq(token.nonRebasingSupply(), 100);

        // mint more
        token.mint(alice, 100);
        token.mint(bobby, 100);

        // check balances
        assertEq(token.balanceOf(alice), 300);
        assertEq(token.balanceOf(bobby), 200);
        assertEq(token.totalSupply(), 500);
        assertEq(token.rebasingSupply(), 300);
        assertEq(token.nonRebasingSupply(), 200);

        // burn tokens
        vm.prank(alice);
        token.burn(100);
        vm.prank(bobby);
        token.burn(100);

        // check balances
        assertEq(token.balanceOf(alice), 200);
        assertEq(token.balanceOf(bobby), 100);
        assertEq(token.totalSupply(), 300);
        assertEq(token.rebasingSupply(), 200);
        assertEq(token.nonRebasingSupply(), 100);

        // distribute 300 profits
        token.mint(address(this), 300);
        token.approve(address(token), 300);
        token.distribute(300);

        // check balances
        assertEq(token.balanceOf(alice), 500);
        assertEq(token.balanceOf(bobby), 100);
        assertEq(token.totalSupply(), 600);
        assertEq(token.rebasingSupply(), 500);
        assertEq(token.nonRebasingSupply(), 100);

        // alice transfer() to bobby
        vm.prank(alice);
        token.transfer(bobby, 200);

        // check balances
        assertEq(token.balanceOf(alice), 300);
        assertEq(token.balanceOf(bobby), 300);
        assertEq(token.totalSupply(), 600);
        assertEq(token.rebasingSupply(), 300);
        assertEq(token.nonRebasingSupply(), 300);

        // bobby transfer() to alice
        vm.prank(bobby);
        token.transfer(alice, 200);

       // check balances
        assertEq(token.balanceOf(alice), 500);
        assertEq(token.balanceOf(bobby), 100);
        assertEq(token.totalSupply(), 600);
        assertEq(token.rebasingSupply(), 500);
        assertEq(token.nonRebasingSupply(), 100);

        // distribute 500 profits
        token.mint(address(this), 500);
        token.approve(address(token), 500);
        token.distribute(500);

        // check balances
        assertEq(token.balanceOf(alice), 1000);
        assertEq(token.balanceOf(bobby), 100);
        assertEq(token.totalSupply(), 1100);
        assertEq(token.rebasingSupply(), 1000);
        assertEq(token.nonRebasingSupply(), 100);

        // bobby transferFrom() alice
        vm.prank(alice);
        token.approve(bobby, 500);
        vm.prank(bobby);
        token.transferFrom(alice, bobby, 500);

        // check balances
        assertEq(token.balanceOf(alice), 500);
        assertEq(token.balanceOf(bobby), 600);
        assertEq(token.totalSupply(), 1100);
        assertEq(token.rebasingSupply(), 500);
        assertEq(token.nonRebasingSupply(), 600);

        // alice transferFrom() bobby
        vm.prank(bobby);
        token.approve(alice, 500);
        vm.prank(alice);
        token.transferFrom(bobby, alice, 500);

        // check balances
        assertEq(token.balanceOf(alice), 1000);
        assertEq(token.balanceOf(bobby), 100);
        assertEq(token.totalSupply(), 1100);
        assertEq(token.rebasingSupply(), 1000);
        assertEq(token.nonRebasingSupply(), 100);
    }

    function testDistributeFuzz(uint256 distributionAmount, uint256[3] memory userBalances) public {
        // fuzz values in the plausibility range
        vm.assume(distributionAmount < 10_000e18);
        vm.assume(userBalances[0] < 1_000_000e18);
        vm.assume(userBalances[1] < 1_000_000e18);
        vm.assume(userBalances[2] < 1_000_000e18);

        // initial state: alice & bobby rebasing, carol not rebasing
        token.mint(alice, userBalances[0]);
        token.mint(bobby, userBalances[1]);
        token.mint(carol, userBalances[2]);
        vm.prank(alice);
        token.enterRebase();
        vm.prank(bobby);
        token.enterRebase();

        // check initial state
        assertEq(token.isRebasing(alice), true);
        assertEq(token.isRebasing(bobby), true);
        assertEq(token.isRebasing(carol), false);

        // check balances
        uint256 totalSupplyBefore = userBalances[0] + userBalances[1] + userBalances[2];
        uint256 rebasingSupplyBefore = userBalances[0] + userBalances[1];
        uint256 nonRebasingSupplyBefore = userBalances[2];
        assertEq(token.balanceOf(alice), userBalances[0]);
        assertEq(token.balanceOf(bobby), userBalances[1]);
        assertEq(token.balanceOf(carol), userBalances[2]);
        assertEq(token.totalSupply(), totalSupplyBefore);
        assertEq(token.rebasingSupply(), rebasingSupplyBefore);
        assertEq(token.nonRebasingSupply(), nonRebasingSupplyBefore);

        // distribute
        token.mint(address(this), distributionAmount);
        token.approve(address(token), distributionAmount);
        if (rebasingSupplyBefore == 0) {
            vm.expectRevert("ERC20RebaseDistributor: no rebase recipients");
        }
        if (distributionAmount == 0 && rebasingSupplyBefore != 0) {
            vm.expectRevert("ERC20RebaseDistributor: cannot distribute zero");
        }
        token.distribute(distributionAmount);
        if (rebasingSupplyBefore == 0 || distributionAmount == 0) {
            return;
        }

        // check balances
        // max error is due to rounding down on number of shares & share price
        uint256 maxError = 2;
        assertApproxEqAbs(token.balanceOf(alice), userBalances[0] + distributionAmount * userBalances[0] / rebasingSupplyBefore, maxError);
        assertApproxEqAbs(token.balanceOf(bobby), userBalances[1] + distributionAmount * userBalances[1] / rebasingSupplyBefore, maxError);
        assertEq(token.balanceOf(carol), userBalances[2]);
        assertApproxEqAbs(token.totalSupply(), totalSupplyBefore + distributionAmount, maxError);
        assertApproxEqAbs(token.rebasingSupply(), rebasingSupplyBefore + distributionAmount, maxError);
        assertApproxEqAbs(token.nonRebasingSupply(), nonRebasingSupplyBefore, maxError);

        // do more distribute to study rounding errors
        for (uint256 i = 2; i < 10; i++) {
            // distribute
            token.mint(address(this), distributionAmount);
            token.approve(address(token), distributionAmount);
            token.distribute(distributionAmount);

            maxError++; // each distribute can add up to 1 wei of error

            // check balances
            assertApproxEqAbs(token.balanceOf(alice), userBalances[0] + distributionAmount * i * userBalances[0] / rebasingSupplyBefore, maxError);
            assertApproxEqAbs(token.balanceOf(bobby), userBalances[1] + distributionAmount * i * userBalances[1] / rebasingSupplyBefore, maxError);
            assertEq(token.balanceOf(carol), userBalances[2]);
            assertApproxEqAbs(token.totalSupply(), totalSupplyBefore + distributionAmount * i, maxError);
            assertApproxEqAbs(token.rebasingSupply(), rebasingSupplyBefore + distributionAmount * i, maxError);
            assertApproxEqAbs(token.nonRebasingSupply(), nonRebasingSupplyBefore, maxError);
        }
    }
}