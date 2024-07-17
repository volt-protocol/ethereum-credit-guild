//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {RewardSweeper} from "@src/governance/RewardSweeper.sol";
import {GovernorProposal} from "@test/proposals/proposalTypes/GovernorProposal.sol";
import {LendingTermFactory} from "@src/governance/LendingTermFactory.sol";
import {LendingTermAdjustable} from "@src/loan/LendingTermAdjustable.sol";
import {LendingTermOnboarding} from "@src/governance/LendingTermOnboarding.sol";
import {LendingTermParamManager} from "@src/governance/LendingTermParamManager.sol";

contract Arbitrum_12_AdjustableLendingTerm is GovernorProposal {
    function name() public view virtual returns (string memory) {
        return "Enable adjustable lending term & reward sweeper";
    }

    constructor() {
        require(
            block.chainid == 42161,
            "Arbitrum_12_AdjustableLendingTerm: wrong chain id"
        );
    }

    function deploy() public virtual {
        // LendingTermAdjustable
        LendingTermAdjustable termV2 = new LendingTermAdjustable();
        setAddr("LENDING_TERM_V2", address(termV2));

        // LendingTermParamManager
        LendingTermOnboarding onboarder = LendingTermOnboarding(payable(getAddr("ONBOARD_GOVERNOR_GUILD")));
        LendingTermParamManager paramMgr = new LendingTermParamManager(
            getAddr("CORE"), // _core
            getAddr("ONBOARD_TIMELOCK"), // _timelock
            getAddr("ERC20_GUILD"), // _guildToken
            onboarder.votingDelay(), // initialVotingDelay
            onboarder.votingPeriod(), // initialVotingPeriod
            onboarder.proposalThreshold(), // initialProposalThreshold
            onboarder.quorum(0) // initialQuorum
        );
        setAddr("TERM_PARAM_GOVERNOR_GUILD", address(paramMgr));

        // RewardSweeper
        RewardSweeper sweeper = new RewardSweeper(
            getAddr("CORE"),
            getAddr("ERC20_GUILD"),
            getAddr("TEAM_MULTISIG")
        );
        setAddr("REWARD_SWEEPER", address(sweeper));
    }

    function afterDeploy(address/* deployer*/) public pure virtual {}

    function run(address /* deployer*/) public virtual {
        _addStep(
            getAddr("LENDING_TERM_FACTORY"),
            abi.encodeWithSignature(
                "allowImplementation(address,bool)",
                getAddr("LENDING_TERM_V2"),
                true
            ),
            "Enable new LENDING_TERM_V2 implementation in factory (adjustable interest rate, borrow ratio, and hardCap)"
        );
        _addStep(
            getAddr("CORE"),
            abi.encodeWithSignature(
                "grantRole(bytes32,address)",
                CoreRoles.TIMELOCK_PROPOSER,
                getAddr("TERM_PARAM_GOVERNOR_GUILD")
            ),
            "Grant TIMELOCK_PROPOSER role to TERM_PARAM_GOVERNOR_GUILD"
        );
        _addStep(
            getAddr("CORE"),
            abi.encodeWithSignature(
                "grantRole(bytes32,address)",
                CoreRoles.TIMELOCK_CANCELLER,
                getAddr("TERM_PARAM_GOVERNOR_GUILD")
            ),
            "Grant TIMELOCK_CANCELLER role to TERM_PARAM_GOVERNOR_GUILD"
        );
        _addStep(
            getAddr("CORE"),
            abi.encodeWithSignature(
                "grantRole(bytes32,address)",
                CoreRoles.GOVERNOR,
                getAddr("REWARD_SWEEPER")
            ),
            "Grant GOVERNOR role to REWARD_SWEEPER"
        );

        // Propose to the DAO
        address governor = getAddr("DAO_GOVERNOR_GUILD");
        address proposer = getAddr("TEAM_MULTISIG");
        address voter = getAddr("TEAM_MULTISIG");
        DEBUG = true;
        _simulateGovernorSteps(name(), governor, proposer, voter);
    }

    function teardown(address deployer) public pure virtual {}

    function validate(address/* deployer*/) public virtual {
        // create a term with the new implementation in the factory
        uint256 marketId = 999999998; // test ETH market
        address term = LendingTermFactory(getAddr("LENDING_TERM_FACTORY")).createTerm(
            marketId, // test ETH market,
            getAddr("LENDING_TERM_V2"), // new implementation
            getAddr("AUCTION_HOUSE_12H"), // auctionHouse
            abi.encode(
                LendingTerm.LendingTermParams({
                    collateralToken: getAddr("ERC20_WETH"),
                    maxDebtPerCollateralToken: 0.9e18,
                    interestRate: 0.05e18,
                    maxDelayBetweenPartialRepay: 0,
                    minPartialRepayPercent: 0,
                    openingFee: 0,
                    hardCap: 1e18
                })
            )
        );

        // dirty onboard of new term
        vm.prank(getAddr("DAO_TIMELOCK"));
        GuildToken(getAddr("ERC20_GUILD")).addGauge(marketId, term);

        // set interest rate
        address msig = getAddr("TEAM_MULTISIG");
        assertEq(LendingTerm(term).getParameters().interestRate, 0.05e18);
        LendingTermParamManager paramMgr = LendingTermParamManager(payable(getAddr("TERM_PARAM_GOVERNOR_GUILD")));
        uint256 interestRate = 0.15e18;
        uint256 blockNumber = block.number;
        vm.prank(msig);
        uint256 proposalId = paramMgr.proposeSetInterestRate(term, interestRate);
        vm.roll(block.number + paramMgr.votingDelay() + 1);
        vm.prank(msig);
        paramMgr.castVote(proposalId, 1);
        vm.roll(block.number + paramMgr.votingPeriod() + 1);
        address[] memory targets = new address[](1);
        targets[0] = term;
        uint256[] memory values = new uint256[](1); // [0]
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature(
            "setInterestRate(uint256)",
            interestRate
        );
        string memory description = string.concat(
            "Update interest rate\n\n[",
            Strings.toString(blockNumber),
            "]",
            " set interestRate of term ",
            Strings.toHexString(term),
            " to ",
            Strings.toString(interestRate)
        );
        paramMgr.queue(targets, values, calldatas, keccak256(bytes(description)));
        vm.warp(paramMgr.proposalEta(proposalId) + 1);
        paramMgr.execute(targets, values, calldatas, keccak256(bytes(description)));
        assertEq(LendingTerm(term).getParameters().interestRate, interestRate);

        // airdrop tokens to a term
        address token = 0x912CE59144191C1204E64559FE8253a0e49E6548;
        address tokenHolder = 0xF3FC178157fb3c87548bAA86F9d24BA38E649B58;
        RewardSweeper sweeper = RewardSweeper(getAddr("REWARD_SWEEPER"));
        vm.prank(tokenHolder);
        ERC20(token).transfer(term, 123456);
        assertEq(ERC20(token).balanceOf(term), 123456);
        assertEq(ERC20(token).balanceOf(msig), 0);
        vm.prank(msig);
        sweeper.sweep(term, token);
        assertEq(ERC20(token).balanceOf(term), 0);
        assertEq(ERC20(token).balanceOf(msig), 123456);
    }
}
