// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

/// @notice very simple contract that have some functions that are reverting and other that are not
/// used to test external calls
contract MockExternalContract {
    uint256 public AmountSaved;

    function ThisFunctionWillRevert(uint256 /*amount*/) public pure {
        revert("I told you I would revert");
    }

    function ThisFunctionWillRevertWithoutMsg(uint256 /*amount*/) public pure {
        revert();
    }

    function ThisFunctionIsOk(uint256 amount) public {
        AmountSaved = amount;
    }
}
