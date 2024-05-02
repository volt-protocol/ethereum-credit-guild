pragma solidity 0.8.13;

import {Proposal} from "@test/proposals/proposalTypes/Proposal.sol";

abstract contract MultiStepProposal is Proposal {
    struct Step {
        address target;
        uint256 value;
        bytes arguments;
        string description;
    }

    Step[] public steps;

    /// @notice add a step to the proposal
    function _addStep(
        uint256 value,
        address target,
        bytes memory data,
        string memory description
    ) internal {
        steps.push(
            Step({
                value: value,
                target: target,
                arguments: data,
                description: description
            })
        );
    }

    /// @notice add a step to the proposal with a value of 0
    function _addStep(
        address target,
        bytes memory data,
        string memory description
    ) internal {
        _addStep(0, target, data, description);
    }

    /// @notice simulate proposal
    /// @param caller account doing the calls
    function _simulateSteps(address caller) internal virtual {
        vm.startPrank(caller);
        for (uint256 i = 0; i < steps.length; i++) {
            (bool success, bytes memory result) = steps[i].target.call{
                value: steps[i].value
            }(steps[i].arguments);
            if (!success) {
                _getRevertMsg(result);
            }
        }
        vm.stopPrank();
    }

    error CallError(bytes innerError);

    /// @dev Extracts a revert message from failed call return data.
    /// @param _returnData The return data from the failed call.
    function _getRevertMsg(bytes memory _returnData) internal pure {
        // If the _res length is less than 68, then
        // the transaction failed with custom error or silently (without a revert message)
        if (_returnData.length < 68) {
            revert CallError(_returnData);
        }

        assembly {
            // Slice the sighash.
            _returnData := add(_returnData, 0x04)
        }
        revert(abi.decode(_returnData, (string))); // All that remains is the revert string
    }
}
