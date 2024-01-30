// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CoreRef} from "@src/core/CoreRef.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";

/// @notice LendingTerm factory.
contract LendingTermFactory is CoreRef {

    /// @notice mapping of allowed LendingTerm implementations
    mapping(address => bool) public implementations;

    /// @notice mapping of allowed AuctionHouses
    mapping(address => bool) public auctionHouses;

    /// @notice immutable reference to the guild token
    address public immutable guildToken;

    /// @notice gaugeType of created terms
    /// note that gaugeType 0 is not valid, so this mapping can be used
    /// to check that a term has been created by this factory.
    mapping(address => uint256) public gaugeTypes;

    /// @notice implementations of created terms
    mapping(address => address) public termImplementations;

    /// @notice mapping of references per market (key = gaugeType = market id)
    mapping(uint256 => MarketReferences) public marketReferences;
    struct MarketReferences {
        address profitManager;
        address creditMinter;
        address creditToken;
    }

    /// @notice emitted when a lending term implementation's "allowed" status changes
    event ImplementationAllowChanged(
        uint256 indexed when,
        address indexed implementation,
        bool allowed
    );
    /// @notice emitted when an auctionHouse's "allowed" status changes
    event AuctionHouseAllowChanged(
        uint256 indexed when,
        address indexed auctionHouses,
        bool allowed
    );
    /// @notice emitted when a term is created
    event TermCreated(
        uint256 indexed when,
        uint256 indexed gaugeType,
        address indexed term,
        LendingTerm.LendingTermParams params
    );

    constructor(
        address _core,
        address _guildToken
    )
        CoreRef(_core)
    {
        guildToken = _guildToken;
    }

    /// @notice set market references for a given market id
    function setMarketReferences(
        uint256 gaugeType,
        MarketReferences calldata references
    ) external onlyCoreRole(CoreRoles.GOVERNOR) {
        marketReferences[gaugeType] = references;
    }

    /// @notice Allow or disallow a given implemenation
    function allowImplementation(
        address implementation,
        bool allowed
    ) external onlyCoreRole(CoreRoles.GOVERNOR) {
        implementations[implementation] = allowed;
        emit ImplementationAllowChanged(
            block.timestamp,
            implementation,
            allowed
        );
    }

    /// @notice Allow or disallow a given auctionHouse
    function allowAuctionHouse(
        address auctionHouse,
        bool allowed
    ) external onlyCoreRole(CoreRoles.GOVERNOR) {
        auctionHouses[auctionHouse] = allowed;
        emit AuctionHouseAllowChanged(block.timestamp, auctionHouse, allowed);
    }

    /// @notice Create a new LendingTerm and initialize it.
    function createTerm(
        uint256 gaugeType,
        address implementation,
        address auctionHouse,
        LendingTerm.LendingTermParams calldata params
    ) external returns (address) {
        require(
            implementations[implementation],
            "LendingTermFactory: invalid implementation"
        );
        require(
            auctionHouses[auctionHouse],
            "LendingTermFactory: invalid auctionHouse"
        );
        // must be an ERC20 (maybe, at least it prevents dumb input mistakes)
        (bool success, bytes memory returned) = params.collateralToken.call(
            abi.encodeWithSelector(IERC20.totalSupply.selector)
        );
        require(
            success && returned.length == 32,
            "LendingTermFactory: invalid collateralToken"
        );

        require(
            params.maxDebtPerCollateralToken != 0, // must be able to mint non-zero debt
            "LendingTermFactory: invalid maxDebtPerCollateralToken"
        );

        require(
            params.interestRate < 1e18, // interest rate [0, 100[% APR
            "LendingTermFactory: invalid interestRate"
        );

        require(
            // 31557601 comes from the constant LendingTerm.YEAR() + 1
            params.maxDelayBetweenPartialRepay < 31557601, // periodic payment every [0, 1 year]
            "LendingTermFactory: invalid maxDelayBetweenPartialRepay"
        );

        require(
            params.minPartialRepayPercent < 1e18, // periodic payment sizes [0, 100[%
            "LendingTermFactory: invalid minPartialRepayPercent"
        );

        require(
            params.openingFee <= 0.1e18, // open fee expected [0, 10]%
            "LendingTermFactory: invalid openingFee"
        );

        require(
            params.hardCap != 0, // non-zero hardcap
            "LendingTermFactory: invalid hardCap"
        );

        // if one of the periodic payment parameter is used, both must be used
        if (
            params.minPartialRepayPercent != 0 ||
            params.maxDelayBetweenPartialRepay != 0
        ) {
            require(
                params.minPartialRepayPercent != 0 &&
                    params.maxDelayBetweenPartialRepay != 0,
                "LendingTermFactory: invalid periodic payment params"
            );
        }

        // check that references for this market has been set
        MarketReferences storage references = marketReferences[gaugeType];
        require(
            references.profitManager != address(0),
            "LendingTermFactory: unknown market"
        );

        address term = Clones.clone(implementation);
        LendingTerm(term).initialize(
            address(core()),
            LendingTerm.LendingTermReferences({
                profitManager: references.profitManager,
                guildToken: guildToken,
                auctionHouse: auctionHouse,
                creditMinter: references.creditMinter,
                creditToken: references.creditToken
            }),
            params
        );
        gaugeTypes[term] = gaugeType;
        termImplementations[term] = implementation;
        emit TermCreated(block.timestamp, gaugeType, term, params);
        return term;
    }
}
