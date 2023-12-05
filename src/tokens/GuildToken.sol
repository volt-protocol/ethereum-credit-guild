// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {CoreRef} from "@src/core/CoreRef.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {ERC20Gauges} from "@src/tokens/ERC20Gauges.sol";
import {ProfitManager} from "@src/governance/ProfitManager.sol";
import {ERC20MultiVotes} from "@src/tokens/ERC20MultiVotes.sol";

/** 
@title  GUILD ERC20 Token
@author eswak
@notice This is the governance token of the Ethereum Credit Guild.
    On deploy, this token is non-transferrable.
    During the non-transferrable period, GUILD can still be minted & burnt, only
    `transfer` and `transferFrom` are reverting.

    The gauge system is used to define debt ceilings on a set of lending terms.
    Lending terms can be whitelisted by adding a gauge for their address, if GUILD
    holders vote for these lending terms in the gauge system, the lending terms will
    have a non-zero debt ceiling, and borrowing will be available under these terms.

    When a lending term creates bad debt, a loss is notified in a gauge on this
    contract (`notifyGaugeLoss`). When a loss is notified, all the GUILD token weight voting
    for this gauge becomes non-transferable and can be permissionlessly slashed. Until the
    loss is realized (`applyGaugeLoss`), a user cannot transfer their locked tokens or
    decrease the weight they assign to the gauge that suffered a loss.
    Even when a loss occur, users can still transfer tokens with which they vote for gauges
    that did not suffer a loss.
*/
contract GuildToken is CoreRef, ERC20Burnable, ERC20Gauges, ERC20MultiVotes {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice reference to ProfitManager
    address public profitManager;

    constructor(
        address _core,
        address _profitManager
    )
        CoreRef(_core)
        ERC20("Ethereum Credit Guild - GUILD", "GUILD")
        ERC20Permit("Ethereum Credit Guild - GUILD")
    {
        profitManager = _profitManager;
    }

    /*///////////////////////////////////////////////////////////////
                        VOTING MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Set `maxDelegates`, the maximum number of addresses any account can delegate voting power to.
    function setMaxDelegates(
        uint256 newMax
    ) external onlyCoreRole(CoreRoles.GUILD_GOVERNANCE_PARAMETERS) {
        _setMaxDelegates(newMax);
    }

    /// @notice Allow or disallow an address to delegate voting power to more addresses than `maxDelegates`.
    function setContractExceedMaxDelegates(
        address account,
        bool canExceedMax
    ) external onlyCoreRole(CoreRoles.GUILD_GOVERNANCE_PARAMETERS) {
        _setContractExceedMaxDelegates(account, canExceedMax);
    }

    /*///////////////////////////////////////////////////////////////
                        GAUGE MANAGEMENT
    //////////////////////////////////////////////////////////////*/
    function addGauge(
        uint256 _type,
        address gauge
    ) external onlyCoreRole(CoreRoles.GAUGE_ADD) returns (uint256) {
        return _addGauge(_type, gauge);
    }

    function removeGauge(
        address gauge
    ) external onlyCoreRole(CoreRoles.GAUGE_REMOVE) {
        _removeGauge(gauge);
    }

    function setMaxGauges(
        uint256 max
    ) external onlyCoreRole(CoreRoles.GAUGE_PARAMETERS) {
        _setMaxGauges(max);
    }

    function setCanExceedMaxGauges(
        address who,
        bool can
    ) external onlyCoreRole(CoreRoles.GAUGE_PARAMETERS) {
        _setCanExceedMaxGauges(who, can);
    }

    /*///////////////////////////////////////////////////////////////
                        LOSS MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice emitted when a loss in a gauge is notified.
    event GaugeLoss(address indexed gauge, uint256 indexed when);
    /// @notice emitted when a loss in a gauge is applied (for each user).
    event GaugeLossApply(
        address indexed gauge,
        address indexed who,
        uint256 weight,
        uint256 when
    );

    /// @notice last block.timestamp when a loss occurred in a given gauge
    mapping(address => uint256) public lastGaugeLoss;

    /// @notice last block.timestamp when a user apply a loss that occurred in a given gauge
    mapping(address => mapping(address => uint256)) public lastGaugeLossApplied;

    /// @notice notify loss in a given gauge
    function notifyGaugeLoss(address gauge) external {
        require(msg.sender == profitManager, "UNAUTHORIZED");

        // save gauge loss
        lastGaugeLoss[gauge] = block.timestamp;
        emit GaugeLoss(gauge, block.timestamp);
    }

    /// @notice apply a loss that occurred in a given gauge
    /// anyone can apply the loss on behalf of anyone else
    function applyGaugeLoss(address gauge, address who) external {
        // check preconditions
        uint256 _lastGaugeLoss = lastGaugeLoss[gauge];
        uint256 _lastGaugeLossApplied = lastGaugeLossApplied[gauge][who];
        require(
            _lastGaugeLoss != 0 && _lastGaugeLossApplied < _lastGaugeLoss,
            "GuildToken: no loss to apply"
        );

        // read user weight allocated to the lossy gauge
        uint256 _userGaugeWeight = getUserGaugeWeight[who][gauge];

        // remove gauge weight allocation
        lastGaugeLossApplied[gauge][who] = block.timestamp;
        _decrementGaugeWeight(who, gauge, _userGaugeWeight);
        if (!_deprecatedGauges.contains(gauge)) {
            totalTypeWeight[gaugeType[gauge]] -= _userGaugeWeight;
            totalWeight -= _userGaugeWeight;
        }

        // apply loss
        _burn(who, uint256(_userGaugeWeight));
        emit GaugeLossApply(
            gauge,
            who,
            uint256(_userGaugeWeight),
            block.timestamp
        );
    }

    /*///////////////////////////////////////////////////////////////
                        TRANSFERABILITY
    //////////////////////////////////////////////////////////////*/

    /// @notice at deployment, tokens are not transferable (can only mint/burn).
    /// Governance can enable transfers with `enableTransfers()`.
    bool public transferable; // default = false

    /// @notice emitted when transfers are enabled.
    event TransfersEnabled(uint256 block, uint256 timestamp);

    /// @notice permanently enable token transfers.
    function enableTransfer() external onlyCoreRole(CoreRoles.GOVERNOR) {
        transferable = true;
        emit TransfersEnabled(block.number, block.timestamp);
    }

    /// @dev prevent transfers if they are not globally enabled.
    /// mint and burn (transfers to and from address 0) are accepted.
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 /* amount*/
    ) internal view override {
        require(
            transferable || from == address(0) || to == address(0),
            "GuildToken: transfers disabled"
        );
    }

    /// @notice emitted when reference to ProfitManager is updated
    event ProfitManagerUpdated(uint256 timestamp, address newValue);

    /// @notice set reference to ProfitManager
    function setProfitManager(address _newProfitManager) external onlyCoreRole(CoreRoles.GOVERNOR) {
        profitManager = _newProfitManager;
        emit ProfitManagerUpdated(block.timestamp, _newProfitManager);
    }

    /// @dev prevent outbound token transfers (_decrementWeightUntilFree) and gauge weight decrease
    /// (decrementGauge, decrementGauges) for users who have an unrealized loss in a gauge, or if the
    /// gauge is currently using its allocated debt ceiling. To decrement gauge weight, guild holders
    /// might have to call loans if the debt ceiling is used.
    /// Also update the user profit index and claim rewards.
    function _decrementGaugeWeight(
        address user,
        address gauge,
        uint256 weight
    ) internal override {
        uint256 _lastGaugeLoss = lastGaugeLoss[gauge];
        uint256 _lastGaugeLossApplied = lastGaugeLossApplied[gauge][user];
        require(
            _lastGaugeLossApplied >= _lastGaugeLoss,
            "GuildToken: pending loss"
        );

        // update the user profit index and claim rewards
        ProfitManager(profitManager).claimGaugeRewards(user, gauge);

        // check if gauge is currently using its allocated debt ceiling.
        // To decrement gauge weight, guild holders might have to call loans if the debt ceiling is used.
        uint256 issuance = LendingTerm(gauge).issuance();
        if (issuance != 0) {
            uint256 debtCeilingAfterDecrement = LendingTerm(gauge).debtCeiling(-int256(weight));
            require(
                issuance <= debtCeilingAfterDecrement,
                "GuildToken: debt ceiling used"
            );
        }

        super._decrementGaugeWeight(user, gauge, weight);
    }

    /// @dev prevent weight increment for gauge if user has an unapplied loss.
    /// If the user has 0 weight (i.e. no loss to realize), allow incrementing
    /// gauge weight & update lastGaugeLossApplied to current time.
    /// Also update the user profit index an claim rewards.
    /// @dev note that users voting for a gauge that is not a proper lending term could result in this
    /// share of the user's tokens to be frozen, due to being unable to decrement weight.
    function _incrementGaugeWeight(
        address user,
        address gauge,
        uint256 weight
    ) internal override {
        uint256 _lastGaugeLoss = lastGaugeLoss[gauge];
        uint256 _lastGaugeLossApplied = lastGaugeLossApplied[gauge][user];
        if (getUserGaugeWeight[user][gauge] == 0) {
            lastGaugeLossApplied[gauge][user] = block.timestamp;
        } else {
            require(
                _lastGaugeLossApplied >= _lastGaugeLoss,
                "GuildToken: pending loss"
            );
        }

        ProfitManager(profitManager).claimGaugeRewards(user, gauge);

        super._incrementGaugeWeight(user, gauge, weight);
    }

    /*///////////////////////////////////////////////////////////////
                        MINT / BURN
    //////////////////////////////////////////////////////////////*/

    /// @notice mint new tokens to the target address
    function mint(
        address to,
        uint256 amount
    ) external onlyCoreRole(CoreRoles.GUILD_MINTER) {
        _mint(to, amount);
    }

    /*///////////////////////////////////////////////////////////////
                        Inheritance reconciliation
    //////////////////////////////////////////////////////////////*/

    function _burn(
        address from,
        uint256 amount
    ) internal virtual override(ERC20, ERC20Gauges, ERC20MultiVotes) {
        _decrementWeightUntilFree(from, amount);
        _decrementVotesUntilFree(from, amount);
        ERC20._burn(from, amount);
    }

    function transfer(
        address to,
        uint256 amount
    )
        public
        virtual
        override(ERC20, ERC20Gauges, ERC20MultiVotes)
        returns (bool)
    {
        _decrementWeightUntilFree(msg.sender, amount);
        _decrementVotesUntilFree(msg.sender, amount);
        return ERC20.transfer(to, amount);
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    )
        public
        virtual
        override(ERC20, ERC20Gauges, ERC20MultiVotes)
        returns (bool)
    {
        _decrementWeightUntilFree(from, amount);
        _decrementVotesUntilFree(from, amount);
        return ERC20.transferFrom(from, to, amount);
    }
}
