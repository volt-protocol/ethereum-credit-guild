pragma solidity 0.8.13;

import {console} from "@forge-std/console.sol";

import {Test} from "@forge-std/Test.sol";
import {Proposal} from "@test/proposals/proposalTypes/Proposal.sol";
import {AddressLib} from "@test/proposals/AddressLib.sol";

import {GIP_0} from "@test/proposals/gips/GIP_0.sol";

/*
How to use:
forge test --fork-url $ETH_RPC_URL --match-contract TestProposals -vvv

Or, from another Solidity file (for post-proposal integration testing):
    TestProposals proposals = new TestProposals();
    proposals.setUp();
    proposals.setDebug(false); // don't console.log
    proposals.testProposals();
*/

contract TestProposals is Test {
    Proposal[] public proposals;
    uint256 public nProposals;
    bool public DEBUG;
    bool public DO_DEPLOY;
    bool public DO_AFTER_DEPLOY;
    bool public DO_RUN;
    bool public DO_TEARDOWN;
    bool public DO_VALIDATE;

    function setUp() public {
        DEBUG = vm.envOr("DEBUG", true);
        DO_DEPLOY = vm.envOr("DO_DEPLOY", true);
        DO_AFTER_DEPLOY = vm.envOr("DO_AFTER_DEPLOY", true);
        DO_RUN = vm.envOr("DO_RUN", true);
        DO_TEARDOWN = vm.envOr("DO_TEARDOWN", true);
        DO_VALIDATE = vm.envOr("DO_VALIDATE", true);

        proposals.push(Proposal(address(new GIP_0())));
        nProposals = proposals.length;

        vm.label(address(this), "TestProposals");
        vm.label(address(proposals[0]), "GIP_0");
    }

    function setDebug(bool value) public {
        DEBUG = value;
        for (uint256 i = 0; i < proposals.length; i++) {
            proposals[i].setDebug(value);
        }
    }

    function testProposals()
        public
        returns (uint256[] memory postProposalVmSnapshots)
    {
        if (DEBUG) {
            console.log(
                "TestProposals: running",
                proposals.length,
                "proposals."
            );
        }
        postProposalVmSnapshots = new uint256[](proposals.length);
        for (uint256 i = 0; i < proposals.length; i++) {
            string memory name = proposals[i].name();

            // Deploy step
            if (DO_DEPLOY) {
                if (DEBUG) console.log("Proposal", name, "deploy()");
                proposals[i].deploy();
            }

            // After-deploy step
            if (DO_AFTER_DEPLOY) {
                if (DEBUG) console.log("Proposal", name, "afterDeploy()");
                proposals[i].afterDeploy(address(proposals[i]));
            }

            // Run step
            if (DO_RUN) {
                if (DEBUG) console.log("Proposal", name, "run()");
                proposals[i].run(address(proposals[i]));
            }

            // Teardown step
            if (DO_TEARDOWN) {
                if (DEBUG) console.log("Proposal", name, "teardown()");
                proposals[i].teardown(address(proposals[i]));
            }

            // Validate step
            if (DO_VALIDATE) {
                if (DEBUG) console.log("Proposal", name, "validate()");
                proposals[i].validate(address(proposals[i]));
            }

            if (DEBUG) console.log("Proposal", name, "done.");

            postProposalVmSnapshots[i] = vm.snapshot();
        }

        return postProposalVmSnapshots;
    }
}
