// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ECGTest} from "@test/ECGTest.sol";

import {TestProposals} from "@test/proposals/TestProposals.sol";

contract PostProposalCheck is ECGTest {
    function setUp() public virtual {
        // Run all pending proposals before doing e2e tests
        TestProposals proposals = new TestProposals();
        proposals.setUp();
        proposals.setDebug(false);
        proposals.testProposals();
    }
}
