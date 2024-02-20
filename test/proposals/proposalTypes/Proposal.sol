pragma solidity 0.8.13;

import {ECGTest} from "@test/ECGTest.sol";
import {IProposal} from "@test/proposals/proposalTypes/IProposal.sol";

abstract contract Proposal is IProposal, ECGTest {
    bool public DEBUG = true;
    uint256 public EXPECT_PCV_CHANGE = 0.003e18;
    bool public SKIP_PSM_ORACLE_TEST = false;

    function setDebug(bool value) external {
        DEBUG = value;
    }
}
