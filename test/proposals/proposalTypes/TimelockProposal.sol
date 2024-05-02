pragma solidity 0.8.13;

import {console} from "@forge-std/console.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {MultiStepProposal} from "@test/proposals/proposalTypes/MultiStepProposal.sol";

abstract contract TimelockProposal is MultiStepProposal {
    /// @notice simulate timelock proposal
    /// @param timelockAddress to execute the proposal against
    /// @param proposerAddress account to propose the proposal to the timelock
    /// @param executorAddress account to execute the proposal on the timelock
    function _simulateTimelockSteps(
        address timelockAddress,
        address proposerAddress,
        address executorAddress
    )
        internal
        returns (
            bytes memory scheduleBatchCalldata,
            bytes memory executeBatchCalldata
        )
    {
        TimelockController timelock = TimelockController(
            payable(timelockAddress)
        );
        uint256 delay = timelock.getMinDelay();
        bytes32 salt = keccak256(bytes(""));

        bytes32 predecessor = bytes32(0);

        uint256 proposalLength = steps.length;
        address[] memory targets = new address[](proposalLength);
        uint256[] memory values = new uint256[](proposalLength);
        bytes[] memory payloads = new bytes[](proposalLength);

        /// target cannot be address 0 as that call will fail
        /// value can be 0
        /// arguments can be 0 as long as eth is sent
        for (uint256 i = 0; i < proposalLength; i++) {
            require(
                steps[i].target != address(0),
                "Invalid target for timelock"
            );
            /// if there are no args and no eth, the action is not valid
            require(
                (steps[i].arguments.length == 0 && steps[i].value > 0) ||
                    steps[i].arguments.length > 0,
                "Invalid arguments for timelock"
            );

            targets[i] = steps[i].target;
            values[i] = steps[i].value;
            payloads[i] = steps[i].arguments;
            salt = keccak256(abi.encode(salt, steps[i].description));
        }

        if (DEBUG) {
            console.log("Timelock proposal");
            console.log("salt: ");
            emit log_bytes32(salt);
        }

        bytes32 proposalId = timelock.hashOperationBatch(
            targets,
            values,
            payloads,
            predecessor,
            salt
        );

        if (DEBUG) {
            console.log("proposal id: ");
            emit log_bytes32(proposalId);
        }

        scheduleBatchCalldata = abi.encodeWithSignature(
            "scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)",
            targets,
            values,
            payloads,
            predecessor,
            salt,
            delay
        );
        executeBatchCalldata = abi.encodeWithSignature(
            "executeBatch(address[],uint256[],bytes[],bytes32,bytes32)",
            targets,
            values,
            payloads,
            predecessor,
            salt
        );

        if (
            !timelock.isOperationPending(proposalId) &&
            !timelock.isOperation(proposalId)
        ) {
            vm.prank(proposerAddress);
            (bool success, bytes memory result) = timelockAddress.call(
                scheduleBatchCalldata
            );
            if (!success) {
                console.log("scheduleBatch reverted: ");
                _getRevertMsg(result);
            }

            if (DEBUG) {
                console.log("schedule batch calldata: ");
                emit log_bytes(scheduleBatchCalldata);
            }
        } else if (DEBUG) {
            console.log("proposal already scheduled");
        }

        vm.warp(block.timestamp + delay + 1);

        if (!timelock.isOperationDone(proposalId)) {
            vm.prank(executorAddress);
            (bool success, bytes memory result) = timelockAddress.call(
                executeBatchCalldata
            );
            if (!success) {
                console.log("executeBatch reverted: ");
                _getRevertMsg(result);
            }

            if (DEBUG) {
                console.log("execute batch calldata: ");
                emit log_bytes(executeBatchCalldata);
            }
        } else if (DEBUG) {
            console.log("proposal already executed");
        }
    }
}
