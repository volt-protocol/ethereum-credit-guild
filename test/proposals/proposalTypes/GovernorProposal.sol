pragma solidity 0.8.13;

import {console} from "@forge-std/console.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";

import {MultiStepProposal} from "@test/proposals/proposalTypes/MultiStepProposal.sol";

abstract contract GovernorProposal is MultiStepProposal {
    /// @notice simulate governor proposal
    /// @param _governor address of Governor to propose in
    /// @param proposer account to propose/queue/execute the proposal on the governor
    /// @param voter account that will castVote and has enough tokens to meet quorum
    function _simulateGovernorSteps(
        address _governor,
        address proposer,
        address voter
    ) internal {
        address payable governorAddress = payable(_governor);
        GovernorTimelockControl governor = GovernorTimelockControl(governorAddress);
        uint256 votingDelay = governor.votingDelay();
        uint256 votingPeriod = governor.votingPeriod();

        address[] memory targets = new address[](steps.length);
        uint256[] memory values = new uint256[](steps.length);
        bytes[] memory payloads = new bytes[](steps.length);
        string memory description = "";

        for (uint256 i = 0; i < steps.length; i++) {
            targets[i] = steps[i].target;
            values[i] = steps[i].value;
            payloads[i] = steps[i].arguments;
            description = string.concat(description, "- ", steps[i].description, "\n");
        }

        description = string.concat(description, "#proposer=", Strings.toHexString(proposer), "\n");

        uint256 proposalId = governor.hashProposal(targets, values, payloads, keccak256(bytes(description)));

        if (DEBUG) {
            console.log("Governor proposal");
            console.log("proposal id: ");
            emit log_bytes32(bytes32(proposalId));
            console.log("description:");
            console.log(description);
        }

        try governor.state(proposalId) returns (IGovernor.ProposalState/* state*/) {
            // proposal already exists
            if (DEBUG) {
                console.log("proposal exists");
            }
        } catch {
            bytes memory proposeCalldata = abi.encodeWithSignature(
                "propose(address[],uint256[],bytes[],string)",
                targets,
                values,
                payloads,
                description
            );

            // proposal not created yet
            vm.prank(proposer);
            (bool success, bytes memory result) = governorAddress.call(
                proposeCalldata
            );
            if (!success) {
                console.log("propose reverted: ");
                _getRevertMsg(result);
            }

            if (DEBUG) {
                console.log("propose calldata: ");
                emit log_bytes(proposeCalldata);
            }
        }

        if (governor.state(proposalId) == IGovernor.ProposalState.Pending) {
            if (DEBUG) {
                console.log("proposal pending, roll votingDelay blocks");
            }
            vm.roll(block.number + votingDelay + 1);
        }

        if (governor.state(proposalId) == IGovernor.ProposalState.Active) {
            if (DEBUG) {
                console.log("proposal active, castVote & roll votingPeriod blocks");
            }
            vm.prank(voter);
            governor.castVote(proposalId, 1);
            vm.roll(block.number + votingPeriod + 1);
        }

        if (governor.state(proposalId) == IGovernor.ProposalState.Succeeded) {
            if (DEBUG) {
                console.log("proposal succeded, queue");
            }

            bytes memory queueCalldata = abi.encodeWithSignature(
                "queue(address[],uint256[],bytes[],bytes32)",
                targets,
                values,
                payloads,
                keccak256(bytes(description))
            );

            vm.prank(proposer);
            (bool success, bytes memory result) = governorAddress.call(
                queueCalldata
            );
            if (!success) {
                console.log("queue reverted: ");
                _getRevertMsg(result);
            }

            if (DEBUG) {
                console.log("queue calldata: ");
                emit log_bytes(queueCalldata);
            }
        }

        if (governor.state(proposalId) == IGovernor.ProposalState.Queued) {
            if (DEBUG) {
                console.log("proposal queued, warp & execute");
            }

            bytes memory executeCalldata = abi.encodeWithSignature(
                "execute(address[],uint256[],bytes[],bytes32)",
                targets,
                values,
                payloads,
                keccak256(bytes(description))
            );

            uint256 proposalEta = governor.proposalEta(proposalId);
            vm.warp(proposalEta);

            vm.prank(proposer);
            (bool success, bytes memory result) = governorAddress.call(
                executeCalldata
            );
            if (!success) {
                console.log("execute reverted: ");
                _getRevertMsg(result);
            }

            if (DEBUG) {
                console.log("execute calldata: ");
                emit log_bytes(executeCalldata);
            }
        }
    }
}
