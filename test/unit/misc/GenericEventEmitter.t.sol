// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ECGTest} from "@test/ECGTest.sol";
import {GenericEventEmitter} from "@src/misc/GenericEventEmitter.sol";

/// @title Test suite for the GenericEventEmitter contract
contract UnitTestGenericEventEmitter is ECGTest {
    GenericEventEmitter public eventEmitter;
    address alice = address(0xa11ce);
    address bob = address(0xb0bb0b);

    struct TestTypeData {
        uint256 someValue;
        address someAddress;
    }

    function setUp() public {
        eventEmitter = new GenericEventEmitter();
    }

    /// @notice generic event
    event GenericEvent(
        bytes32 indexed eventType,
        uint256 timestamp,
        address origin,
        bytes data
    );

    function testEmitEvent() public {
        bytes32 eventType = keccak256("TestType");
        TestTypeData memory testData = TestTypeData({
            someValue: 42,
            someAddress: alice
        });

        bytes memory data = abi.encode(testData);
        vm.expectEmit(true, false, false, true, address(eventEmitter));
        emit GenericEvent(keccak256("TestType"), block.timestamp, tx.origin, data);

        vm.prank(bob);
        eventEmitter.log(eventType, data);
    }

    function testEmitEventWithString() public {
        bytes32 eventType = keccak256("TestTypeWithString");
        string memory testData = '{"someValue":42,"sponsor": "this_is_alice","sponsored": "this_is_bob"}';

        vm.expectEmit(true, false, false, true, address(eventEmitter));
        emit GenericEvent(keccak256("TestTypeWithString"), block.timestamp, tx.origin, bytes(testData));

        vm.prank(bob);
        eventEmitter.log(eventType, bytes(testData));
    }
}
