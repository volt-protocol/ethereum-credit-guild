// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import {CoreRef} from "@src/core/CoreRef.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {ERC20Gauges} from "@src/tokens/ERC20Gauges.sol";
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
    have a non-zero debt ceiling, and CREDIT will be available to borrow under these terms.

    When a loan is called and there is bad debt, a loss is notified in a gauge on this
    contract (`notifyPnL`). When a loss is notified, all the GUILD token weight voting
    for this gauge becomes non-transferable and can be permissionlessly slashed. Until the
    loss is realized (`applyGaugeLoss`), a user cannot transfer their locked tokens or
    decrease the weight they assign to the gauge that suffered a loss.
    Even when a loss occur, users can still transfer tokens with which they vote for gauges
    that did not suffer a loss.
*/
// TODO: figure out a way to do pro-rata distribution of profits to GUILD holders that vote in gauges that generate profits.
contract GuildToken is CoreRef, ERC20Burnable, ERC20Gauges, ERC20MultiVotes {

    /// @notice reference to CREDIT token.
    address public credit;

    /// @notice total accumulative profit & loss of GUILD holders across all gauges
    int256 public totalPnL;

    /// @notice total accumulative profit & loss of a given gauge
    mapping(address=>int256) public gaugePnL;

    /// @notice multiplier for CREDIT value in the system.
    /// e.g. a value of 0.7e18 would mean that CREDIT has been discounted by 30% so far in the system,
    /// and that all lending terms will allow 1/0.7=1.42 times more CREDIT to be borrowed per collateral
    /// tokens, and all active debts are also affected by this multiplier during the update.
    /// The CREDIT multiplier can only go down (CREDIT can only lose value over time, when bad debt
    /// is created in the system). To make CREDIT a valuable asset to hold, profits generated by the system
    /// shall be redistributed to holders through a savings rate or another mechanism.
    uint256 public creditMultiplier = 1e18;

    constructor(
        address _core,
        address _credit,
        uint32 _gaugeCycleLength,
        uint32 _incrementFreezeWindow
    )
        CoreRef(_core)
        ERC20("Ethereum Credit Guild - GUILD", "GUILD")
        ERC20Permit("Ethereum Credit Guild - GUILD")
        ERC20Gauges(_gaugeCycleLength, _incrementFreezeWindow)
    {
        credit = _credit;
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
        address gauge
    ) external onlyCoreRole(CoreRoles.GAUGE_ADD) returns (uint112) {
        return _addGauge(gauge);
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
    event GaugePnL(address indexed gauge, uint256 indexed when, int256 pnl);
    /// @notice emitted when a loss in a gauge is notified.
    event GaugeLoss(address indexed gauge, uint256 indexed when);
    /// @notice emitted when a loss in a gauge is applied (for each user).
    event GaugeLossApply(
        address indexed gauge,
        address indexed who,
        uint256 weight,
        uint256 when
    );

    /// @notice emitted when CREDIT multiplier is updated.
    event CreditMultiplierUpdate(uint256 indexed when, uint256 newValue);

    /// @notice last block.timestamp when a loss occurred in a given gauge
    mapping(address => uint256) public lastGaugeLoss;

    /// @notice last block.timestamp when a user apply a loss that occurred in a given gauge
    mapping(address => mapping(address => uint256)) public lastGaugeLossApplied;

    /// @notice notify profit and loss in a given gauge
    function notifyPnL(
        address gauge,
        int256 amount
    ) external onlyCoreRole(CoreRoles.GAUGE_PNL_NOTIFIER) {
        // handling loss
        if (amount < 0) {
            lastGaugeLoss[gauge] = block.timestamp;
            emit GaugeLoss(gauge, block.timestamp);

            // update the CREDIT multiplier
            uint256 creditTotalSupply = ERC20(credit).totalSupply();
            uint256 newCreditMultiplier = creditMultiplier * (creditTotalSupply - uint256(-amount)) / creditTotalSupply;
            creditMultiplier = newCreditMultiplier;
            emit CreditMultiplierUpdate(newCreditMultiplier, block.timestamp);
        }
        
        // update storage
        totalPnL += amount;
        gaugePnL[gauge] += amount;
        emit GaugePnL(gauge, block.timestamp, amount);
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
        uint112 _userGaugeWeight = getUserGaugeWeight[who][gauge];

        // remove gauge weight allocation
        lastGaugeLossApplied[gauge][who] = block.timestamp;
        uint32 currentCycle = _getGaugeCycleEnd();
        _decrementGaugeWeight(who, gauge, _userGaugeWeight, currentCycle);
        _decrementUserAndGlobalWeights(who, _userGaugeWeight, currentCycle);

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

    /// @dev prevent outbound token transfers (_decrementWeightUntilFree) and gauge weight decrease
    /// (decrementGauge, decrementGauges) for users who have an unrealized loss in a gauge.
    function _decrementGaugeWeight(
        address user,
        address gauge,
        uint112 weight,
        uint32 cycle
    ) internal override {
        uint256 _lastGaugeLoss = lastGaugeLoss[gauge];
        uint256 _lastGaugeLossApplied = lastGaugeLossApplied[gauge][user];
        require(
            _lastGaugeLossApplied >= _lastGaugeLoss,
            "GuildToken: pending loss"
        );

        super._decrementGaugeWeight(user, gauge, weight, cycle);
    }

    /// @dev prevent weight increment for gauge if user has an unapplied loss.
    function _incrementGaugeWeight(
        address user,
        address gauge,
        uint112 weight,
        uint32 cycle
    ) internal override {
        uint256 _lastGaugeLoss = lastGaugeLoss[gauge];
        uint256 _lastGaugeLossApplied = lastGaugeLossApplied[gauge][user];
        require(
            _lastGaugeLossApplied >= _lastGaugeLoss,
            "GuildToken: pending loss"
        );

        super._incrementGaugeWeight(user, gauge, weight, cycle);
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

    function _burn(address from, uint256 amount)
        internal
        virtual
        override(ERC20, ERC20Gauges, ERC20MultiVotes)
    {
        _decrementWeightUntilFree(from, amount);
        _decrementVotesUntilFree(from, amount);
        ERC20._burn(from, amount);
    }

    function transfer(address to, uint256 amount)
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
