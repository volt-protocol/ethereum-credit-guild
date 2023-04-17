// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Gauges} from "@src/tokens/ERC20Gauges.sol";
import {CoreRef} from "@src/core/CoreRef.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";

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
    contract (`notifyGaugeLoss`). When a loss is notified, all the GUILD token weight voting
    for this gauge becomes non-transferable and can be permissionlessly slashed. Until the
    loss is realized (`applyGaugeLoss`), a user cannot transfer their locked tokens or
    decrease the weight they assign to the gauge that suffered a loss.
    Even when a loss occur, users can still transfer tokens with which they vote for gauges
    that did not suffer a loss.
*/
contract GuildToken is CoreRef, ERC20Gauges {
    constructor(
        address _core,
        uint32 _gaugeCycleLength,
        uint32 _incrementFreezeWindow
    )
        CoreRef(_core)
        ERC20("Ethereum Credit Guild - GUILD", "GUILD")
        ERC20Gauges(_gaugeCycleLength, _incrementFreezeWindow)
    {}

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
    event GaugeLossNotification(address indexed gauge, uint256 indexed when);
    /// @notice emitted when a loss in a gauge is applied.
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

    /// @notice notify of a loss in a given gauge
    function notifyGaugeLoss(
        address gauge
    ) external onlyCoreRole(CoreRoles.GAUGE_LOSS_NOTIFIER) {
        lastGaugeLoss[gauge] = block.timestamp;
        emit GaugeLossNotification(gauge, block.timestamp);
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

    /// @dev prevent weight increment for gauge if user has an unapplied loss
    function incrementGauge(
        address gauge,
        uint112 weight
    ) public override returns (uint112) {
        uint256 _lastGaugeLoss = lastGaugeLoss[gauge];
        uint256 _lastGaugeLossApplied = lastGaugeLossApplied[gauge][msg.sender];
        require(
            _lastGaugeLossApplied >= _lastGaugeLoss,
            "GuildToken: pending loss"
        );

        return super.incrementGauge(gauge, weight);
    }

    /// @dev prevent weight increment for gauges if user has an unapplied loss
    function incrementGauges(
        address[] calldata gaugeList,
        uint112[] calldata weights
    ) public override returns (uint112 newUserWeight) {
        for (uint256 i = 0; i < gaugeList.length; ) {
            address gauge = gaugeList[i];
            uint256 _lastGaugeLoss = lastGaugeLoss[gauge];
            uint256 _lastGaugeLossApplied = lastGaugeLossApplied[gauge][
                msg.sender
            ];
            require(
                _lastGaugeLossApplied >= _lastGaugeLoss,
                "GuildToken: pending loss"
            );
            unchecked {
                ++i;
            }
        }

        return super.incrementGauges(gaugeList, weights);
    }

    /// @dev prevent weight decrement for gauge if user has an unapplied loss
    function decrementGauge(
        address gauge,
        uint112 weight
    ) public override returns (uint112) {
        uint256 _lastGaugeLoss = lastGaugeLoss[gauge];
        uint256 _lastGaugeLossApplied = lastGaugeLossApplied[gauge][msg.sender];
        require(
            _lastGaugeLossApplied >= _lastGaugeLoss,
            "GuildToken: pending loss"
        );

        return super.decrementGauge(gauge, weight);
    }

    /// @dev prevent weight decrement for gauges if user has an unapplied loss
    function decrementGauges(
        address[] calldata gaugeList,
        uint112[] calldata weights
    ) public override returns (uint112 newUserWeight) {
        for (uint256 i = 0; i < gaugeList.length; ) {
            address gauge = gaugeList[i];
            uint256 _lastGaugeLoss = lastGaugeLoss[gauge];
            uint256 _lastGaugeLossApplied = lastGaugeLossApplied[gauge][
                msg.sender
            ];
            require(
                _lastGaugeLossApplied >= _lastGaugeLoss,
                "GuildToken: pending loss"
            );
            unchecked {
                ++i;
            }
        }

        return super.decrementGauges(gaugeList, weights);
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

    /// @notice burn a given amount of owned tokens
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
