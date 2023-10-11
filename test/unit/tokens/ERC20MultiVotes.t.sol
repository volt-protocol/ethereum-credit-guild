// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.13;

import {Test} from "@forge-std/Test.sol";
import {ERC20MultiVotes} from "@src/tokens/ERC20MultiVotes.sol";
import {MockERC20MultiVotes} from "@test/mock/MockERC20MultiVotes.sol";

contract ERC20MultiVotesUnitTest is Test {
    MockERC20MultiVotes token;
    address constant delegate1 = address(0xDEAD);
    address constant delegate2 = address(0xBEEF);

    function setUp() public {
        vm.warp(1679067867);
        vm.roll(16848497);
        token = new MockERC20MultiVotes();
    }

    /*///////////////////////////////////////////////////////////////
                        TEST ADMIN OPERATIONS
    //////////////////////////////////////////////////////////////*/

    function testSetMaxDelegates(uint256 max) public {
        token.setMaxDelegates(max);
        require(token.maxDelegates() == max);
    }

    function testCanContractExceedMax() public {
        token.setContractExceedMaxDelegates(address(this), true);
        require(token.canContractExceedMaxDelegates(address(this)));
    }

    function testCanContractExceedMaxNonContractFails() public {
        vm.expectRevert("ERC20MultiVotes: not a smart contract");
        token.setContractExceedMaxDelegates(address(1), true);
    }

    /*///////////////////////////////////////////////////////////////
                        TEST USER DELEGATION OPERATIONS
    //////////////////////////////////////////////////////////////*/

    function testDelegate() public {
        token.setMaxDelegates(2);
        token.mint(delegate1, 100);

        assertEq(token.delegates(delegate1).length, 0);
        assertEq(token.delegatesVotesCount(delegate1, delegate1), 0);
        assertEq(token.delegatesVotesCount(delegate1, delegate2), 0);
        assertFalse(token.containsDelegate(delegate1, delegate2));
        assertFalse(token.containsDelegate(delegate1, delegate1));

        vm.prank(delegate1);
        token.incrementDelegation(delegate1, 50);

        assertEq(token.delegates(delegate1).length, 1);
        assertEq(token.delegates(delegate1)[0], delegate1);
        assertEq(token.delegatesVotesCount(delegate1, delegate1), 50);
        assertEq(token.delegatesVotesCount(delegate1, delegate2), 0);
        assertTrue(token.containsDelegate(delegate1, delegate1));

        vm.prank(delegate1);
        token.incrementDelegation(delegate2, 50);

        assertEq(token.delegates(delegate1).length, 2);
        assertEq(token.delegates(delegate1)[0], delegate1);
        assertEq(token.delegates(delegate1)[1], delegate2);
        assertEq(token.delegatesVotesCount(delegate1, delegate1), 50);
        assertEq(token.delegatesVotesCount(delegate1, delegate2), 50);
        assertTrue(token.containsDelegate(delegate1, delegate2));
    }

    /// @notice test delegating different delegatees 8 times by multiple users and amounts
    function testDelegateFuzz(
        address[8] memory from,
        address[8] memory delegates,
        uint224[8] memory amounts
    ) public {
        token.setMaxDelegates(8);

        unchecked {
            uint224 sum;
            for (uint256 i = 0; i < 8; i++) {
                vm.assume(
                    sum + amounts[i] >= sum &&
                        from[i] != address(0) &&
                        delegates[i] != address(0)
                );
                sum += amounts[i];

                token.mint(from[i], amounts[i]);

                uint256 userDelegatedBefore = token.userDelegatedVotes(from[i]);
                uint256 delegateVotesBefore = token.delegatesVotesCount(
                    from[i],
                    delegates[i]
                );
                uint256 votesBefore = token.getVotes(delegates[i]);

                vm.prank(from[i]);
                token.incrementDelegation(delegates[i], amounts[i]);
                require(
                    token.delegatesVotesCount(from[i], delegates[i]) ==
                        delegateVotesBefore + amounts[i]
                );
                require(
                    token.userDelegatedVotes(from[i]) ==
                        userDelegatedBefore + amounts[i]
                );
                require(
                    token.getVotes(delegates[i]) == votesBefore + amounts[i]
                );
            }
        }
    }

    function testDelegateToAddressZeroFails() public {
        token.mint(address(this), 100e18);
        token.setMaxDelegates(2);

        vm.expectRevert("ERC20MultiVotes: delegation error");
        token.incrementDelegation(address(0), 50e18);
    }

    function testDelegateOverVotesFails() public {
        token.mint(address(this), 100e18);
        token.setMaxDelegates(2);

        token.incrementDelegation(delegate1, 50e18);
        vm.expectRevert("ERC20MultiVotes: delegation error");
        token.incrementDelegation(delegate2, 51e18);
    }

    function testDelegateOverMaxDelegatesFails() public {
        token.mint(address(this), 100e18);
        token.setMaxDelegates(2);

        token.incrementDelegation(delegate1, 50e18);
        token.incrementDelegation(delegate2, 1e18);
        vm.expectRevert("ERC20MultiVotes: delegation error");
        token.incrementDelegation(address(this), 1e18);
    }

    function testDelegateOverMaxDelegatesApproved() public {
        token.mint(address(this), 100e18);
        token.setMaxDelegates(2);

        token.setContractExceedMaxDelegates(address(this), true);
        token.incrementDelegation(delegate1, 50e18);
        token.incrementDelegation(delegate2, 1e18);
        token.incrementDelegation(address(this), 1e18);

        require(token.delegateCount(address(this)) == 3);
        require(token.delegateCount(address(this)) > token.maxDelegates());
        require(token.userDelegatedVotes(address(this)) == 52e18);
    }

    /// @notice test undelegate twice, 2 tokens each after delegating by 4.
    function testUndelegate() public {
        token.mint(address(this), 100e18);
        token.setMaxDelegates(2);

        token.incrementDelegation(delegate1, 4e18);

        token.undelegate(delegate1, 2e18);
        require(token.delegatesVotesCount(address(this), delegate1) == 2e18);
        require(token.userDelegatedVotes(address(this)) == 2e18);
        require(token.getVotes(delegate1) == 2e18);
        require(token.freeVotes(address(this)) == 98e18);

        token.undelegate(delegate1, 2e18);
        require(token.delegatesVotesCount(address(this), delegate1) == 0);
        require(token.userDelegatedVotes(address(this)) == 0);
        require(token.getVotes(delegate1) == 0);
        require(token.freeVotes(address(this)) == 100e18);
    }

    function testDecrementOverWeightFails() public {
        token.mint(address(this), 100e18);
        token.setMaxDelegates(2);

        token.incrementDelegation(delegate1, 50e18);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 17));
        token.undelegate(delegate1, 51e18);
    }

    function testBackwardCompatibleDelegate(
        address oldDelegatee,
        uint112 beforeDelegateAmount,
        address newDelegatee,
        uint112 mintAmount
    ) public {
        vm.assume(mintAmount >= beforeDelegateAmount);
        token.mint(address(this), mintAmount);
        token.setMaxDelegates(2);

        if (oldDelegatee == address(0)) {
            vm.expectRevert("ERC20MultiVotes: delegation error");
        }

        token.incrementDelegation(oldDelegatee, beforeDelegateAmount);

        token.delegate(newDelegatee);

        uint256 expected = newDelegatee == address(0) ? 0 : mintAmount;
        uint256 expectedFree = newDelegatee == address(0) ? mintAmount : 0;

        require(
            oldDelegatee == newDelegatee ||
                token.delegatesVotesCount(address(this), oldDelegatee) == 0
        );
        require(
            token.delegatesVotesCount(address(this), newDelegatee) == expected
        );
        require(token.userDelegatedVotes(address(this)) == expected);
        require(token.getVotes(newDelegatee) == expected);
        require(token.freeVotes(address(this)) == expectedFree);
    }

    function testBackwardCompatibleDelegateBySig(
        uint128 delegatorPk,
        address oldDelegatee,
        uint112 beforeDelegateAmount,
        address newDelegatee,
        uint112 mintAmount
    ) public {
        vm.assume(delegatorPk != 0);
        address owner = vm.addr(delegatorPk);

        vm.assume(mintAmount >= beforeDelegateAmount);
        token.mint(owner, mintAmount);
        token.setMaxDelegates(2);

        if (oldDelegatee == address(0)) {
            vm.expectRevert("ERC20MultiVotes: delegation error");
        }

        vm.prank(owner);
        token.incrementDelegation(oldDelegatee, beforeDelegateAmount);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            delegatorPk,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    token.DOMAIN_SEPARATOR(),
                    keccak256(
                        abi.encode(
                            token.DELEGATION_TYPEHASH(),
                            newDelegatee,
                            0,
                            block.timestamp
                        )
                    )
                )
            )
        );

        uint256 expected = newDelegatee == address(0) ? 0 : mintAmount;
        uint256 expectedFree = newDelegatee == address(0) ? mintAmount : 0;

        token.delegateBySig(newDelegatee, 0, block.timestamp, v, r, s);
        require(
            oldDelegatee == newDelegatee ||
                token.delegatesVotesCount(owner, oldDelegatee) == 0
        );
        require(token.delegatesVotesCount(owner, newDelegatee) == expected);
        require(token.userDelegatedVotes(owner) == expected);
        require(token.getVotes(newDelegatee) == expected);
        require(token.freeVotes(owner) == expectedFree);
    }

    /*///////////////////////////////////////////////////////////////
                            TEST PAST VOTES
    //////////////////////////////////////////////////////////////*/

    function testPastVotes() public {
        token.mint(address(this), 100e18);
        token.setMaxDelegates(2);

        token.incrementDelegation(delegate1, 4e18);

        uint256 block1 = block.number;
        require(token.numCheckpoints(delegate1) == 1);
        ERC20MultiVotes.Checkpoint memory checkpoint1 = token.checkpoints(
            delegate1,
            0
        );
        require(checkpoint1.fromBlock == block1);
        require(checkpoint1.votes == 4e18);

        // Same block increase voting power
        token.incrementDelegation(delegate1, 4e18);

        require(token.numCheckpoints(delegate1) == 1);
        checkpoint1 = token.checkpoints(delegate1, 0);
        require(checkpoint1.fromBlock == block1);
        require(checkpoint1.votes == 8e18);

        vm.roll(block.number + 1);
        uint256 block2 = block.number;
        require(block2 == block1 + 1);

        // Next block decrease voting power
        token.undelegate(delegate1, 2e18);

        require(token.numCheckpoints(delegate1) == 2); // new checkpint

        // checkpoint 1 stays same
        checkpoint1 = token.checkpoints(delegate1, 0);
        require(checkpoint1.fromBlock == block1);
        require(checkpoint1.votes == 8e18);

        // new checkpoint 2
        ERC20MultiVotes.Checkpoint memory checkpoint2 = token.checkpoints(
            delegate1,
            1
        );
        require(checkpoint2.fromBlock == block2);
        require(checkpoint2.votes == 6e18);

        vm.roll(block.number + 9);
        uint256 block3 = block.number;
        require(block3 == block2 + 9);

        // 10 blocks later increase voting power
        token.incrementDelegation(delegate1, 4e18);

        require(token.numCheckpoints(delegate1) == 3); // new checkpoint

        // checkpoint 1 stays same
        checkpoint1 = token.checkpoints(delegate1, 0);
        require(checkpoint1.fromBlock == block1);
        require(checkpoint1.votes == 8e18);

        // checkpoint 2 stays same
        checkpoint2 = token.checkpoints(delegate1, 1);
        require(checkpoint2.fromBlock == block2);
        require(checkpoint2.votes == 6e18);

        // new checkpoint 3
        ERC20MultiVotes.Checkpoint memory checkpoint3 = token.checkpoints(
            delegate1,
            2
        );
        require(checkpoint3.fromBlock == block3);
        require(checkpoint3.votes == 10e18);

        // finally, test getPastVotes between checkpoints
        require(token.getPastVotes(delegate1, block1) == 8e18);
        require(token.getPastVotes(delegate1, block2) == 6e18);
        require(token.getPastVotes(delegate1, block2 + 4) == 6e18);
        require(token.getPastVotes(delegate1, block3 - 1) == 6e18);

        vm.expectRevert("ERC20MultiVotes: not a past block");
        token.getPastVotes(delegate1, block3); // revert same block

        vm.roll(block.number + 1);
        require(token.getPastVotes(delegate1, block3) == 10e18);
    }

    /*///////////////////////////////////////////////////////////////
                            TEST ERC20 LOGIC
    //////////////////////////////////////////////////////////////*/

    function testDecrementUntilFreeWhenFree() public {
        token.mint(address(this), 100e18);
        token.setMaxDelegates(2);

        token.incrementDelegation(delegate1, 10e18);
        token.incrementDelegation(delegate2, 20e18);
        require(token.freeVotes(address(this)) == 70e18);

        token.mockBurn(address(this), 50e18);
        require(token.freeVotes(address(this)) == 20e18);

        require(token.delegatesVotesCount(address(this), delegate1) == 10e18);
        require(token.userDelegatedVotes(address(this)) == 30e18);
        require(token.getVotes(delegate1) == 10e18);
        require(token.delegatesVotesCount(address(this), delegate2) == 20e18);
        require(token.getVotes(delegate2) == 20e18);
    }

    function testDecrementUntilFreeSingle() public {
        token.mint(address(this), 100e18);
        token.setMaxDelegates(2);

        token.incrementDelegation(delegate1, 10e18);
        token.incrementDelegation(delegate2, 20e18);
        require(token.freeVotes(address(this)) == 70e18);

        token.transfer(address(1), 80e18);
        require(token.freeVotes(address(this)) == 0);

        require(token.delegatesVotesCount(address(this), delegate1) == 0);
        require(token.userDelegatedVotes(address(this)) == 20e18);
        require(token.getVotes(delegate1) == 0);
        require(token.delegatesVotesCount(address(this), delegate2) == 20e18);
        require(token.getVotes(delegate2) == 20e18);
    }

    function testDecrementUntilFreeDouble() public {
        token.mint(address(this), 100e18);
        token.setMaxDelegates(2);

        token.incrementDelegation(delegate1, 10e18);
        token.incrementDelegation(delegate2, 20e18);
        require(token.freeVotes(address(this)) == 70e18);

        token.approve(address(1), 100e18);
        vm.prank(address(1));
        token.transferFrom(address(this), address(1), 90e18);

        require(token.freeVotes(address(this)) == 10e18);

        require(token.delegatesVotesCount(address(this), delegate1) == 0);
        require(token.userDelegatedVotes(address(this)) == 0);
        require(token.getVotes(delegate1) == 0);
        require(token.delegatesVotesCount(address(this), delegate2) == 0);
        require(token.getVotes(delegate2) == 0);
    }
}
