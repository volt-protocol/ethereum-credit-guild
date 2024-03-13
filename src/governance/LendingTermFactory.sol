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
        bytes params
    );

    constructor(address _core, address _guildToken) CoreRef(_core) {
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
        bytes calldata lendingTermParams
    ) external returns (address) {
        require(
            implementations[implementation],
            "LendingTermFactory: invalid implementation"
        );
        require(
            auctionHouses[auctionHouse],
            "LendingTermFactory: invalid auctionHouse"
        );

        // check that references for this market has been set
        MarketReferences storage references = marketReferences[gaugeType];
        require(
            references.profitManager != address(0),
            "LendingTermFactory: unknown market"
        );

        bytes32 salt = keccak256(
            abi.encodePacked(implementation, auctionHouse, lendingTermParams)
        );
        address term = Clones.cloneDeterministic(implementation, salt);
        LendingTerm(term).initialize(
            address(core()),
            LendingTerm.LendingTermReferences({
                profitManager: references.profitManager,
                guildToken: guildToken,
                auctionHouse: auctionHouse,
                creditMinter: references.creditMinter,
                creditToken: references.creditToken
            }),
            lendingTermParams
        );
        gaugeTypes[term] = gaugeType;
        termImplementations[term] = implementation;
        emit TermCreated(block.timestamp, gaugeType, term, lendingTermParams);
        return term;
    }
}
