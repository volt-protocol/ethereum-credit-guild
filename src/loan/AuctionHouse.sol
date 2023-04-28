// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CoreRef} from "@src/core/CoreRef.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {RateLimitedCreditMinter} from "@src/rate-limits/RateLimitedCreditMinter.sol";

// TODO: this contract is a mock, implement the features properly
contract AuctionHouse is CoreRef {

    /// @notice reference to the GUILD token
    address public guildToken;

    /// @notice reference to the credit minter contract
    address public creditMinter;

    /// @notice reference to the CREDIT token
    address public creditToken;

    struct Auction {
        uint256 startTime;
        uint256 endTime;
        address caller;
        address borrower;
        address collateralToken;
        uint256 collateralAmount;
        uint256 debtAmount;
        uint256 ltvBuffer;
        uint256 callFee;
    }

    /// @notice the list of all auctions that existed or are still active
    mapping(bytes32=>Auction) public auctions;

    constructor(
        address _core,
        address _guildToken,
        address _creditMinter,
        address _creditToken
    ) CoreRef(_core) {
        guildToken = _guildToken;
        creditMinter = _creditMinter;
        creditToken = _creditToken;
    }

    function startAuction(
        bytes32 loanId,
        address caller,
        address borrower,
        address collateralToken,
        uint256 collateralAmount,
        uint256 debtAmount,
        uint256 ltvBuffer,
        uint256 callFee
    ) external whenNotPaused {
        // TODO: check that caller is a lending term (guild.isGauge(msg.sender))
        // TODO: other checks

        // pull collateral
        ERC20(collateralToken).transferFrom(msg.sender, address(this), collateralAmount);

        // save auction in state
        auctions[loanId] = Auction({
            startTime: block.timestamp,
            endTime: 0,
            caller: caller,
            borrower: borrower,
            collateralToken: collateralToken,
            collateralAmount: collateralAmount,
            debtAmount: debtAmount,
            ltvBuffer: ltvBuffer,
            callFee: callFee
        });
    }

    function bid(bytes32 loanId) external whenNotPaused {
        // TODO
    }
}
