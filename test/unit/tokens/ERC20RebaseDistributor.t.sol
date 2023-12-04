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

        // test exitRebase with pending rebase rewards
        vm.prank(alice);
        token.enterRebase();

        // distribute
        token.mint(address(this), 100);
        token.distribute(100);
        vm.warp(block.timestamp + token.DISTRIBUTION_PERIOD());

        assertEq(token.balanceOf(alice), 200);

        vm.prank(alice);
        token.exitRebase();

        assertEq(token.balanceOf(alice), 200);
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
        vm.warp(block.timestamp + token.DISTRIBUTION_PERIOD());

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
        vm.warp(block.timestamp + token.DISTRIBUTION_PERIOD());

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
        vm.warp(block.timestamp + token.DISTRIBUTION_PERIOD());

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

        // allow distribution of profits if nobody is going to receive, which
        // is equivalent to just burning the tokens
        token.mint(address(this), 100);
        token.distribute(100);
        vm.warp(block.timestamp + token.DISTRIBUTION_PERIOD());
        assertEq(token.totalSupply(), 800);
        assertEq(token.nonRebasingSupply(), 800);
        assertEq(token.rebasingSupply(), 0);
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

        // distribute
        token.mint(address(this), 100);
        token.distribute(100);
        vm.warp(block.timestamp + token.DISTRIBUTION_PERIOD());

        assertEq(token.balanceOf(alice), 200);
        assertEq(token.balanceOf(bobby), 100);

        token.mint(alice, 100);
        token.mint(bobby, 100);

        assertEq(token.balanceOf(alice), 300);
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
        
        // test burn with pending rebase rewards
        token.mint(alice, 100);
        assertEq(token.balanceOf(alice), 100);

        // distribute
        token.mint(address(this), 100);
        token.distribute(100);
        vm.warp(block.timestamp + token.DISTRIBUTION_PERIOD());

        assertEq(token.balanceOf(alice), 200);

        vm.prank(alice);
        token.burn(50);

        assertEq(token.balanceOf(alice), 150);
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

        // test transfer with pending rebase rewards on `from`
        // distribute
        token.mint(address(this), 150);
        token.distribute(150);
        vm.warp(block.timestamp + token.DISTRIBUTION_PERIOD());

        assertEq(token.balanceOf(alice), 300);
        assertEq(token.balanceOf(bobby), 50);

        vm.prank(alice);
        token.transfer(bobby, 150);

        assertEq(token.balanceOf(alice), 150);
        assertEq(token.balanceOf(bobby), 200);

        // test transfer with pending rebase rewards on `to`
        // distribute
        token.mint(address(this), 150);
        token.distribute(150);
        vm.warp(block.timestamp + token.DISTRIBUTION_PERIOD());

        assertEq(token.balanceOf(alice), 300);
        assertEq(token.balanceOf(bobby), 200);

        vm.prank(bobby);
        token.transfer(alice, 100);

        assertEq(token.balanceOf(alice), 400);
        assertEq(token.balanceOf(bobby), 100);
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

        // test transferFrom with pending rebase rewards on `from`
        // distribute
        token.mint(address(this), 50);
        token.distribute(50);
        vm.warp(block.timestamp + token.DISTRIBUTION_PERIOD());

        assertEq(token.balanceOf(alice), 100);
        assertEq(token.balanceOf(bobby), 150);

        vm.prank(alice);
        token.approve(address(this), 50);
        token.transferFrom(alice, bobby, 50);

        assertEq(token.balanceOf(alice), 50);
        assertEq(token.balanceOf(bobby), 200);

        // test transferFrom with pending rebase rewards on `to`
        // distribute
        token.mint(address(this), 50);
        token.distribute(50);
        vm.warp(block.timestamp + token.DISTRIBUTION_PERIOD());

        assertEq(token.balanceOf(alice), 100);
        assertEq(token.balanceOf(bobby), 200);

        vm.prank(bobby);
        token.approve(address(this), 100);
        token.transferFrom(bobby, alice, 100);

        assertEq(token.balanceOf(alice), 200);
        assertEq(token.balanceOf(bobby), 100);
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
        vm.warp(block.timestamp + token.DISTRIBUTION_PERIOD());

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
        vm.warp(block.timestamp + token.DISTRIBUTION_PERIOD());

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
        vm.warp(block.timestamp + token.DISTRIBUTION_PERIOD());

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
        distributionAmount = bound(distributionAmount, 0, 10_000e18);
        userBalances[0] = bound(userBalances[0], 0, 1_000_000e18);
        userBalances[1] = bound(userBalances[1], 0, 1_000_000e18);
        userBalances[2] = bound(userBalances[2], 0, 1_000_000e18);

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
        if (distributionAmount == 0) {
            vm.expectRevert("ERC20RebaseDistributor: cannot distribute zero");
        }
        token.distribute(distributionAmount);
        vm.warp(block.timestamp + token.DISTRIBUTION_PERIOD());
        if (rebasingSupplyBefore == 0 || distributionAmount == 0) {
            return;
        }

        // check balances
        // max error is due to rounding down on number of shares & share price
        uint256 maxError = 1;
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
            vm.warp(block.timestamp + token.DISTRIBUTION_PERIOD());

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

    function testMintAfterSharePriceUpdate(uint256 input) public {
        uint256 distributionAmount = bound(input, 1, 1e27);
        token.mint(alice, 100e18);
        token.mint(bobby, 55e18);
        vm.prank(bobby);
        token.enterRebase();  // distrubte will not recalculate the share price unless some account is rebasing
        assertEq(token.totalSupply(), 155e18);
        assertEq(token.nonRebasingSupply(), 100e18);
        assertEq(token.rebasingSupply(), 55e18);

        // some distribution amounts will make the division of share price
        // round down some balance, and force to enter into the 'minBalance' confition
        token.mint(address(this), distributionAmount);
        token.approve(address(token), distributionAmount);
        token.distribute(distributionAmount);
        vm.warp(block.timestamp + token.DISTRIBUTION_PERIOD());

        vm.prank(alice);
        token.enterRebase();

        assertEq(token.balanceOf(alice), 100e18); // unchanged
        assertGt(token.balanceOf(bobby), 55e18 + distributionAmount - 2); // at most 1 wei of round down
        assertLt(token.balanceOf(bobby), 55e18 + distributionAmount + 1); // at most balance + distributed

        token.mint(alice, 100e18);
        assertEq(token.balanceOf(alice), 200e18);
    }

    function testReceiveTransferAfterSharePriceUpdate(uint256 input) public {
        uint256 distributionAmount = bound(input, 1, 1e27);
        token.mint(alice, 100e18);
        token.mint(bobby, 55e18);
        vm.prank(bobby);
        token.enterRebase();  // distrubte will not recalculate the share price unless some account is rebasing
        assertEq(token.totalSupply(), 155e18);
        assertEq(token.nonRebasingSupply(), 100e18);
        assertEq(token.rebasingSupply(), 55e18);

        // some distribution amounts will make the division of share price
        // round down some balance, and force to enter into the 'minBalance' confition
        token.mint(address(this), distributionAmount);
        token.approve(address(token), distributionAmount);
        token.distribute(distributionAmount);
        vm.warp(block.timestamp + token.DISTRIBUTION_PERIOD());

        vm.prank(alice);
        token.enterRebase();

        assertEq(token.balanceOf(alice), 100e18); // unchanged
        assertGt(token.balanceOf(bobby), 55e18 + distributionAmount - 2); // at most 1 wei of round down
        assertLt(token.balanceOf(bobby), 55e18 + distributionAmount + 1); // at most balance + distributed

        vm.prank(bobby);
        token.transfer(alice, 10e18);
        assertEq(token.balanceOf(alice), 110e18);
    }

    function testCanExitRebaseAfterEnteringRebase(uint256 input) public {
        uint256 distributionAmount = bound(input, 1, 1e27);
        token.mint(alice, 100e18);
        token.mint(bobby, 55e18);
        vm.prank(bobby);
        token.enterRebase();  // distrubte will not recalculate the share price unless some account is rebasing
        assertEq(token.totalSupply(), 155e18);
        assertEq(token.nonRebasingSupply(), 100e18);
        assertEq(token.rebasingSupply(), 55e18);

        // some distribution amounts will make the division of share price
        // round down some balance, and force to enter into the 'minBalance' confition
        token.mint(address(this), distributionAmount);
        token.approve(address(token), distributionAmount);
        token.distribute(distributionAmount);
        vm.warp(block.timestamp + token.DISTRIBUTION_PERIOD());

        vm.prank(alice);
        token.enterRebase();

        assertEq(token.balanceOf(alice), 100e18); // unchanged
        assertGt(token.balanceOf(bobby), 55e18 + distributionAmount - 2); // at most 1 wei of round down
        assertLt(token.balanceOf(bobby), 55e18 + distributionAmount + 1); // at most balance + distributed

        vm.prank(alice);
        token.exitRebase();

        assertEq(token.balanceOf(alice), 100e18);
    }

    function testCanTransferAfterEnteringRebase(uint256 input) public {
        uint256 distributionAmount = bound(input, 1, 1e27);
        token.mint(alice, 100e18);
        token.mint(bobby, 55e18);
        vm.prank(bobby);
        token.enterRebase();  // distrubte will not recalculate the share price unless some account is rebasing
        assertEq(token.totalSupply(), 155e18);
        assertEq(token.nonRebasingSupply(), 100e18);
        assertEq(token.rebasingSupply(), 55e18);

        // some distribution amounts will make the division of share price
        // round down some balance, and force to enter into the 'minBalance' confition
        token.mint(address(this), distributionAmount);
        token.approve(address(token), distributionAmount);
        token.distribute(distributionAmount);
        vm.warp(block.timestamp + token.DISTRIBUTION_PERIOD());

        vm.prank(alice);
        token.enterRebase();

        assertEq(token.balanceOf(alice), 100e18); // unchanged
        assertGt(token.balanceOf(bobby), 55e18 + distributionAmount - 2); // at most 1 wei of round down
        assertLt(token.balanceOf(bobby), 55e18 + distributionAmount + 1); // at most balance + distributed

        vm.prank(alice);
        token.transfer(address(this), 100e18);

        assertEq(token.balanceOf(address(this)), 100e18);
        assertEq(token.balanceOf(alice), 0);
    }

    function testCanTransferFromAfterEnteringRebase1(uint256 input) public {
        uint256 distributionAmount = bound(input, 1, 1e27);
        token.mint(alice, 100e18);
        token.mint(bobby, 55e18);
        vm.prank(bobby);
        token.enterRebase();  // distrubte will not recalculate the share price unless some account is rebasing
        assertEq(token.totalSupply(), 155e18);
        assertEq(token.nonRebasingSupply(), 100e18);
        assertEq(token.rebasingSupply(), 55e18);

        // some distribution amounts will make the division of share price
        // round down some balance, and force to enter into the 'minBalance' confition
        token.mint(address(this), distributionAmount);
        token.approve(address(token), distributionAmount);
        token.distribute(distributionAmount);
        vm.warp(block.timestamp + token.DISTRIBUTION_PERIOD());

        vm.prank(alice);
        token.enterRebase();

        assertEq(token.balanceOf(alice), 100e18); // unchanged
        assertGt(token.balanceOf(bobby), 55e18 + distributionAmount - 2); // at most 1 wei of round down
        assertLt(token.balanceOf(bobby), 55e18 + distributionAmount + 1); // at most balance + distributed

        vm.prank(alice);
        token.approve(bobby, 100e18);
        vm.prank(bobby);
        token.transferFrom(alice, bobby, 100e18);

        assertApproxEqAbs(token.balanceOf(bobby), 55e18 + distributionAmount + 100e18, 1);
        assertEq(token.balanceOf(alice), 0);
    }

    function testCanTransferFromAfterEnteringRebase2(uint256 input) public {
        uint256 distributionAmount = bound(input, 1, 1e27);
        token.mint(alice, 100e18);
        token.mint(bobby, 55e18);
        vm.prank(bobby);
        token.enterRebase();  // distrubte will not recalculate the share price unless some account is rebasing
        assertEq(token.totalSupply(), 155e18);
        assertEq(token.nonRebasingSupply(), 100e18);
        assertEq(token.rebasingSupply(), 55e18);

        // some distribution amounts will make the division of share price
        // round down some balance, and force to enter into the 'minBalance' confition
        token.mint(address(this), distributionAmount);
        token.approve(address(token), distributionAmount);
        token.distribute(distributionAmount);
        vm.warp(block.timestamp + token.DISTRIBUTION_PERIOD());

        vm.prank(alice);
        token.enterRebase();

        assertEq(token.balanceOf(alice), 100e18); // unchanged
        assertGt(token.balanceOf(bobby), 55e18 + distributionAmount - 2); // at most 1 wei of round down
        assertLt(token.balanceOf(bobby), 55e18 + distributionAmount + 1); // at most balance + distributed

        token.mint(address(this), 100e18);
        token.approve(alice, 100e18);
        vm.prank(alice);
        token.transferFrom(address(this), alice, 100e18);

        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(alice), 200e18);
    }

    function testCanBurnAfterEnteringRebase(uint256 input) public {
        uint256 distributionAmount = bound(input, 1, 1e27);
        token.mint(alice, 100e18);
        token.mint(bobby, 55e18);
        vm.prank(bobby);
        token.enterRebase();  // distrubte will not recalculate the share price unless some account is rebasing
        assertEq(token.totalSupply(), 155e18);
        assertEq(token.nonRebasingSupply(), 100e18);
        assertEq(token.rebasingSupply(), 55e18);

        // some distribution amounts will make the division of share price
        // round down some balance, and force to enter into the 'minBalance' confition
        token.mint(address(this), distributionAmount);
        token.approve(address(token), distributionAmount);
        token.distribute(distributionAmount);
        vm.warp(block.timestamp + token.DISTRIBUTION_PERIOD());

        vm.prank(alice);
        token.enterRebase();

        assertEq(token.balanceOf(alice), 100e18); // unchanged
        assertGt(token.balanceOf(bobby), 55e18 + distributionAmount - 2); // at most 1 wei of round down
        assertLt(token.balanceOf(bobby), 55e18 + distributionAmount + 1); // at most balance + distributed

        vm.prank(alice);
        token.burn(100e18);

        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(alice), 0);
    }

    function testRewardsInterpolation() public {
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

        // check new supply after half of DISTRIBUTION_PERIOD
        // half of the 100 distribution has been passed through
        vm.warp(block.timestamp + token.DISTRIBUTION_PERIOD() / 2);
        assertEq(token.totalSupply(), 350);
        assertEq(token.nonRebasingSupply(), 100);
        assertEq(token.rebasingSupply(), 250);
        assertEq(token.balanceOf(alice), 125);
        assertEq(token.balanceOf(bobby), 125);
        assertEq(token.balanceOf(carol), 100);

        // carol enters rebase (will update target share price)
        vm.prank(carol);
        token.enterRebase();
        // mint 100 additional tokens to alice (will materialize 50 rewards)
        token.mint(alice, 100);
        assertEq(token.totalSupply(), 450);
        assertEq(token.nonRebasingSupply(), 0);
        assertEq(token.rebasingSupply(), 450);
        assertEq(token.balanceOf(alice), 225);
        assertEq(token.balanceOf(bobby), 125);
        assertEq(token.balanceOf(carol), 100);

        // check new supply after DISTRIBUTION_PERIOD is over
        vm.warp(block.timestamp + token.DISTRIBUTION_PERIOD() / 2);

        assertEq(token.totalSupply(), 500);
        assertEq(token.nonRebasingSupply(), 1); // round down on rebasing supply
        assertEq(token.rebasingSupply(), 450 + 49); // round down
        assertEq(token.balanceOf(alice), 225 + 24); // round down
        assertEq(token.balanceOf(bobby), 125 + 13); // round down
        assertEq(token.balanceOf(carol), 100 + 11); // round down
    }

    function testDistributeDuringInterpolation() public {
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
        assertEq(token.pendingDistributedSupply(), 0);
        assertEq(token.targetTotalSupply(), 300);

        // distribute 100 profits
        token.mint(address(this), 100);
        token.approve(address(token), 100);
        token.distribute(100);

        // check new supply after half of DISTRIBUTION_PERIOD
        // half of the 100 distribution has been passed through
        assertEq(token.pendingDistributedSupply(), 100);
        assertEq(token.targetTotalSupply(), 400);
        vm.warp(block.timestamp + token.DISTRIBUTION_PERIOD() / 2);
        assertEq(token.totalSupply(), 350);
        assertEq(token.nonRebasingSupply(), 100);
        assertEq(token.rebasingSupply(), 250);
        assertEq(token.pendingDistributedSupply(), 50);
        assertEq(token.targetTotalSupply(), 400);
        assertEq(token.balanceOf(alice), 125);
        assertEq(token.balanceOf(bobby), 125);
        assertEq(token.balanceOf(carol), 100);

        // distribute 100 profits
        token.mint(address(this), 100);
        token.approve(address(token), 100);
        token.distribute(100);
        // new distribution is 100 (new) + 50 (leftovers) = 150
        // balances & supply shouldn't change instantly
        assertEq(token.totalSupply(), 350);
        assertEq(token.nonRebasingSupply(), 100);
        assertEq(token.rebasingSupply(), 250);
        assertEq(token.pendingDistributedSupply(), 150);
        assertEq(token.targetTotalSupply(), 500);
        assertEq(token.balanceOf(alice), 125);
        assertEq(token.balanceOf(bobby), 125);
        assertEq(token.balanceOf(carol), 100);

        // check new supply after half of DISTRIBUTION_PERIOD
        // half of the 150 distribution has been passed through
        vm.warp(block.timestamp + token.DISTRIBUTION_PERIOD() / 2);
        assertEq(token.totalSupply(), 350 + 75);
        assertEq(token.nonRebasingSupply(), 100);
        assertEq(token.rebasingSupply(), 250 + 75);
        assertEq(token.pendingDistributedSupply(), 75);
        assertEq(token.targetTotalSupply(), 500);
        assertEq(token.balanceOf(alice), 162); // round down
        assertEq(token.balanceOf(bobby), 162); // round down
        assertEq(token.balanceOf(carol), 100);

        // check new supply after DISTRIBUTION_PERIOD is over
        vm.warp(block.timestamp + token.DISTRIBUTION_PERIOD() / 2);

        assertEq(token.totalSupply(), 500);
        assertEq(token.nonRebasingSupply(), 100);
        assertEq(token.rebasingSupply(), 400);
        assertEq(token.pendingDistributedSupply(), 0);
        assertEq(token.targetTotalSupply(), 500);
        assertEq(token.balanceOf(alice), 200);
        assertEq(token.balanceOf(bobby), 200);
        assertEq(token.balanceOf(carol), 100);

        // after interpolations end, supplies & balances do not change anymore
        vm.warp(block.timestamp + token.DISTRIBUTION_PERIOD() * 10);

        assertEq(token.totalSupply(), 500);
        assertEq(token.nonRebasingSupply(), 100);
        assertEq(token.rebasingSupply(), 400);
        assertEq(token.pendingDistributedSupply(), 0);
        assertEq(token.targetTotalSupply(), 500);
        assertEq(token.balanceOf(alice), 200);
        assertEq(token.balanceOf(bobby), 200);
        assertEq(token.balanceOf(carol), 100);
    }

    function testRewardsInterpolationFuzz(uint8 seed) public {
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

        // check new balances and supply after half of DISTRIBUTION_PERIOD
        vm.warp(block.timestamp + token.DISTRIBUTION_PERIOD() / 2);
        assertEq(token.balanceOf(alice), 125);
        assertEq(token.balanceOf(bobby), 125);
        assertEq(token.balanceOf(carol), 100);
        assertEq(token.totalSupply(), 350);
        assertEq(token.nonRebasingSupply(), 100);
        assertEq(token.rebasingSupply(), 250);

        // bobby stops rebasing, 50 rewards still pending distribution
        int256 expectedAliceBalanceChange = 0;
        int256 expectedBobbyBalanceChange = 0;
        int256 expectedCarolBalanceChange = 0;
        int256 expectedTotalSupplyChange = 0;
        int256 expectedNonRebasingSupplyChange = 0;
        int256 expectedRebasingSupplyChange = 0;

        // Do a random action that will revise the target share price (number
        // of rebasing shares change) and/or the pending rewards amount.
        // case 1) enterRebase
        if (seed % 8 == 0) {
            token.mint(carol, 275);
            vm.prank(carol);
            token.enterRebase();
            // carol enter rebase with 375 tokens to get 60% (30) of rewards
            // alice and bobby will both get 20% (10) of rewards, because they
            // have 3x less tokens than carol
            expectedAliceBalanceChange = 10;
            expectedBobbyBalanceChange = 10;
            expectedCarolBalanceChange = 275 + 30;
            expectedTotalSupplyChange = 50 + 275;
            expectedNonRebasingSupplyChange = -100;
            expectedRebasingSupplyChange = 100 + 50 + 275;
        }
        // case 2) burn from a rebasing address
        else if (seed % 8 == 1) {
            vm.prank(bobby);
            token.burn(100);
            // burn 100 tokens from bobby, so he has 25 tokens left.
            // alice has 125 tokens, rebasing supply is 150, and
            // the distribution of 50 will go 8.33 for bobby and
            // 41.67 to alice.
            expectedAliceBalanceChange = 41;
            expectedBobbyBalanceChange = -100 + 8;
            expectedCarolBalanceChange = 0;
            expectedTotalSupplyChange = -100 + 50;
            expectedNonRebasingSupplyChange = 1; // round down on rebasing balances
            expectedRebasingSupplyChange = -100 + 49;
        }
        // case 3) mint to a rebasing address
        else if (seed % 8 == 2) {
            token.mint(alice, 375);
            // mint 375 tokens to alice, so she has 500 tokens
            // bob has 125 tokens, so rebasing supply is 625,
            // and the distribution of 50 will go 40 to alice
            // and 10 to bob.
            expectedAliceBalanceChange = 375 + 40;
            expectedBobbyBalanceChange = 10;
            expectedCarolBalanceChange = 0;
            expectedTotalSupplyChange = 375 + 50;
            expectedNonRebasingSupplyChange = 0;
            expectedRebasingSupplyChange = 375 + 50;
        }
        // case 4) transfer from a rebasing address
        else if (seed % 8 == 3) {
            vm.prank(alice);
            token.transfer(carol, 50);
            // alice has 75 tokens, bob has 125 tokens,
            // rebasing supply is 200, so distribution of 50
            // will go 18 to alice and 31 to bob.
            expectedAliceBalanceChange = -50 + 18;
            expectedBobbyBalanceChange = 31;
            expectedCarolBalanceChange = 50;
            expectedTotalSupplyChange = 50;
            expectedNonRebasingSupplyChange = 50;
            expectedRebasingSupplyChange = 50 - 50;
        }
        // case 5) transfer to a rebasing address
        else if (seed % 8 == 4) {
            vm.prank(carol);
            token.transfer(alice, 50);
            // alice has 175 tokens, bob has 125 tokens,
            // rebasing supply is 300, so distribution of 50
            // will go 29 to alice and 21 to bob.
            expectedAliceBalanceChange = 50 + 29;
            expectedBobbyBalanceChange = 20;
            expectedCarolBalanceChange = -50;
            expectedTotalSupplyChange = 50;
            expectedNonRebasingSupplyChange = -50 + 1; // round down on rebasing balances
            expectedRebasingSupplyChange = 50 + 49;
        }
        // case 6) transferFrom from a rebasing address
        else if (seed % 8 == 5) {
            vm.prank(alice);
            token.approve(carol, 50);
            vm.prank(carol);
            token.transferFrom(alice, carol, 50);
            // alice has 75 tokens, bob has 125 tokens,
            // rebasing supply is 200, so distribution of 50
            // will go 18 to alice and 31 to bob.
            expectedAliceBalanceChange = -50 + 18;
            expectedBobbyBalanceChange = 31;
            expectedCarolBalanceChange = 50;
            expectedTotalSupplyChange = 50;
            expectedNonRebasingSupplyChange = 50;
            expectedRebasingSupplyChange = 50 - 50;
        }
        // case 7) transferFrom to a rebasing address
        else if (seed % 8 == 6) {
            vm.prank(carol);
            token.approve(alice, 50);
            vm.prank(alice);
            token.transferFrom(carol, alice, 50);
            // alice has 175 tokens, bob has 125 tokens,
            // rebasing supply is 300, so distribution of 50
            // will go 29 to alice and 21 to bob.
            expectedAliceBalanceChange = 50 + 29;
            expectedBobbyBalanceChange = 20;
            expectedCarolBalanceChange = -50;
            expectedTotalSupplyChange = 50;
            expectedNonRebasingSupplyChange = -50 + 1; // round down on rebasing balances
            expectedRebasingSupplyChange = 50 + 49;
        }
        // case 8) exitRebase
        else {
            vm.prank(bobby);
            token.exitRebase();
            // bobby exit rebase with 125 tokens and all the remaining
            // 50 rebasing rewards will go to alice
            expectedAliceBalanceChange = 50;
            expectedBobbyBalanceChange = 0;
            expectedCarolBalanceChange = 0;
            expectedTotalSupplyChange = 50;
            expectedNonRebasingSupplyChange = 125;
            expectedRebasingSupplyChange = -125 + 50;
        }

        vm.warp(block.timestamp + token.DISTRIBUTION_PERIOD() / 2);

        // check new balances and supply
        assertEq(token.balanceOf(alice), uint256(125 + expectedAliceBalanceChange));
        assertEq(token.balanceOf(bobby), uint256(125 + expectedBobbyBalanceChange));
        assertEq(token.balanceOf(carol), uint256(100 + expectedCarolBalanceChange));
        assertEq(token.totalSupply(), uint256(350 + expectedTotalSupplyChange));
        assertEq(token.nonRebasingSupply(), uint256(100 + expectedNonRebasingSupplyChange));
        assertEq(token.rebasingSupply(), uint256(250 + expectedRebasingSupplyChange));
    }
}
