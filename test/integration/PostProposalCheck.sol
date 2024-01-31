// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ECGTest} from "@test/ECGTest.sol";

import {TestProposals} from "@test/proposals/TestProposals.sol";

contract PostProposalCheck is ECGTest {
    TestProposals public proposals;

    uint256 preProposalsSnapshot;
    uint256 postProposalsSnapshot;

    function setUp() public virtual {
        preProposalsSnapshot = vm.snapshot();

        // Run all pending proposals before doing e2e tests
        proposals = new TestProposals();
        proposals.setUp();
        proposals.setDebug(false);
        proposals.testProposals();

        postProposalsSnapshot = vm.snapshot();
    }
}
