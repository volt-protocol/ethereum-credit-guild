//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {GovernorProposal} from "@test/proposals/proposalTypes/GovernorProposal.sol";
import {AuctionHouse} from "@src/loan/AuctionHouse.sol";

contract Arbitrum_6_Short_Auction_House is GovernorProposal {
    function name() public view virtual returns (string memory) {
        return "Arbitrum_6_Short_Auction_House";
    }

    constructor() {
        require(
            block.chainid == 42161,
            "Arbitrum_6_Short_Auction_House: wrong chain id"
        );
    }

    /// --------------------------------------------------------------
    /// --------------------------------------------------------------
    /// -------------------- DEPLOYMENT CONSTANTS --------------------
    /// --------------------------------------------------------------
    /// --------------------------------------------------------------

    uint256 public constant MID_POINT = 0.5 * 3600; // 30 minutes mid point
    uint256 public constant AUCTION_DURATION = 6 * 3600; // 6 hours auction
    uint256 public constant STARTING_POINT = 0; // 0% collateral offered at first
    string public constant AUCTION_HOUSE_NAME = "AUCTION_HOUSE_30MIN_6H";

    function deploy() public virtual {
        // Auction House & LendingTerm Implementation
        AuctionHouse ah = new AuctionHouse(
            getAddr("CORE"),
            MID_POINT,
            AUCTION_DURATION,
            STARTING_POINT
        );
        setAddr(AUCTION_HOUSE_NAME, address(ah));
    }

    function afterDeploy(address deployer) public pure virtual {}

    function run(address /* deployer*/) public virtual {
        _addStep(
            getAddr("LENDING_TERM_FACTORY"),
            abi.encodeWithSignature(
                "allowAuctionHouse(address,bool)",
                getAddr(AUCTION_HOUSE_NAME),
                true
            ),
            string.concat("Allow auction house ", AUCTION_HOUSE_NAME)
        );

        // Propose to the DAO
        address governor = getAddr("DAO_GOVERNOR_GUILD");
        address proposer = getAddr("TEAM_MULTISIG");
        address voter = getAddr("TEAM_MULTISIG");
        DEBUG = true;
        _simulateGovernorSteps(name(), governor, proposer, voter);
    }

    function teardown(address deployer) public pure virtual {}

    function validate(address deployer) public pure virtual {}
}
