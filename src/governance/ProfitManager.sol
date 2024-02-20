// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {CoreRef} from "@src/core/CoreRef.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";

/** 
@title ProfitManager
@author eswak
@notice This contract manages profits generated in the system and how it is distributed
    between the various stakeholders.

    This contract also manages a surplus buffer, which acts as first-loss capital in case of
    bad debt. When bad debt is created beyond the surplus buffer, this contract decrements
    the `creditMultiplier` value held in its storage, which has the effect of reducing the
    value of CREDIT everywhere in the system.

    When a loan generates profit (interests), the profit is traced back to users voting for
    this lending term (gauge), which subsequently allows pro-rata distribution of profits to
    GUILD holders that vote for the most productive gauges.

    Seniority stack of the debt, in case of losses :
    - per term surplus buffer (donated to global surplus buffer when loss is reported)
    - global surplus buffer
    - finally, credit holders (by updating down the creditMultiplier)
*/
contract ProfitManager is CoreRef {
    /// @notice reference to GUILD token.
    address public guild;

    /// @notice reference to CREDIT token.
    address public credit;

    /// @notice profit index of a given gauge
    mapping(address => uint256) public gaugeProfitIndex;

    /// @notice profit index of a given user in a given gauge
    mapping(address => mapping(address => uint256)) public userGaugeProfitIndex;

    /// @dev internal structure used to optimize storage read, public functions use
    /// uint256 numbers with 18 decimals.
    struct ProfitSharingConfig {
        uint32 surplusBufferSplit; // percentage, with 9 decimals (!) that go to surplus buffer
        uint32 guildSplit; // percentage, with 9 decimals (!) that go to GUILD holders
        uint32 otherSplit; // percentage, with 9 decimals (!) that go to other address if != address(0)
        address otherRecipient; // address receiving `otherSplit`
    }

    /// @notice configuration of profit sharing.
    /// `surplusBufferSplit`, `guildSplit`, and `otherSplit` are expressed as percentages with 9 decimals,
    /// so a value of 1e9 would direct 100% of profits. The sum should be <= 1e9.
    /// The rest (if the sum of `guildSplit` + `otherSplit` is < 1e9) is distributed to lenders of the
    /// system, CREDIT holders, through the rebasing mechanism (`CreditToken.distribute()`).
    /// If `otherRecipient` is set to address(0), `otherSplit` must equal 0.
    /// The share of profit to `otherRecipient` is sent through a regular ERC20.transfer().
    /// This structure is optimized for storage packing, all external interfaces reference
    /// percentages encoded as uint256 with 18 decimals.
    ProfitSharingConfig internal profitSharingConfig;

    /// @notice amount of first-loss capital in the system.
    /// This is a number of CREDIT token held on this contract that can be used to absorb losses in
    /// cases where a loss is reported through `notifyPnL`. The surplus buffer is depleted first, and
    /// if the loss is greater than the surplus buffer, the `creditMultiplier` is updated down.
    uint256 public surplusBuffer;

    /// @notice amount of first-loss capital for a given term.
    /// This is a number of CREDIT token held on this contract that can be used to absorb losses in
    /// cases where a loss is reported through `notifyPnL` in a given term.
    /// When a loss is reported in a given term, its termSuplusBuffer is donated to the general
    /// surplusBuffer before calculating the loss.
    mapping(address => uint256) public termSurplusBuffer;

    /// @notice multiplier for CREDIT value in the system.
    /// e.g. a value of 0.7e18 would mean that CREDIT has been discounted by 30% so far in the system,
    /// and that all lending terms will allow 1/0.7=1.42 times more CREDIT to be borrowed per collateral
    /// tokens, and all active debts are also affected by this multiplier during the update (e.g. if an
    /// address owed 1000 CREDIT in an active loan, they now owe 1428 CREDIT).
    /// The CREDIT multiplier can only go down (CREDIT can only lose value over time, when bad debt
    /// is created in the system). To make CREDIT a valuable asset to hold, profits generated by the system
    /// shall be redistributed to holders through a savings rate or another mechanism.
    uint256 public creditMultiplier = 1e18;

    /// @notice minimum size of CREDIT loans.
    /// this parameter is here to ensure that the gas costs of liquidation do not
    /// outsize minimum overcollateralization (which could result in bad debt
    /// on otherwise sound loans).
    /// This value is adjusted up when the creditMultiplier goes down.
    uint256 internal _minBorrow = 100e18;

    /// @notice tolerance on new borrows regarding gauge weights.
    /// For a total supply or 100 credit, and 2 gauges each at 50% weight,
    /// the ideal borrow amount for each gauge is 50 credit. To facilitate
    /// growth of the protocol, a tolerance is allowed compared to the ideal
    /// gauge weights.
    /// This tolerance is expressed as a percentage with 18 decimals.
    /// A tolerance of 1e18 (100% - or 0% deviation compared to ideal weights)
    /// can result in a deadlock situation where no new borrows are allowed.
    uint256 public gaugeWeightTolerance = 1.2e18; // 120%

    /// @notice total amount of CREDIT issued in the lending terms of this market.
    /// Should be equal to the sum of all LendingTerm.issuance().
    uint256 public totalIssuance;

    /// @notice maximum total amount of CREDIT allowed to be issued in this market.
    /// This value is adjusted up when the creditMultiplier goes down.
    /// This is set to a very large value by default to not restrict usage by default.
    uint256 public _maxTotalIssuance = 1e30;

    constructor(address _core) CoreRef(_core) {
        emit MinBorrowUpdate(block.timestamp, 100e18);
    }

    /// @notice emitted when a profit or loss in a gauge is notified.
    event GaugePnL(address indexed gauge, uint256 indexed when, int256 pnl);

    /// @notice emitted when surplus buffer is updated.
    event SurplusBufferUpdate(uint256 indexed when, uint256 newValue);

    /// @notice emitted when surplus buffer of a given term is updated.
    event TermSurplusBufferUpdate(
        uint256 indexed when,
        address indexed term,
        uint256 newValue
    );

    /// @notice emitted when CREDIT multiplier is updated.
    event CreditMultiplierUpdate(uint256 indexed when, uint256 newValue);

    /// @notice emitted when GUILD profit sharing is updated.
    event ProfitSharingConfigUpdate(
        uint256 indexed when,
        uint256 surplusBufferSplit,
        uint256 creditSplit,
        uint256 guildSplit,
        uint256 otherSplit,
        address otherRecipient
    );

    /// @notice emitted when a GUILD member claims their CREDIT rewards.
    event ClaimRewards(
        uint256 indexed when,
        address indexed user,
        address indexed gauge,
        uint256 amount
    );

    /// @notice emitted when minBorrow is updated
    event MinBorrowUpdate(uint256 indexed when, uint256 newValue);

    /// @notice emitted when maxTotalIssuance is updated
    event MaxTotalIssuanceUpdate(uint256 indexed when, uint256 newValue);

    /// @notice emitted when gaugeWeightTolerance is updated
    event GaugeWeightToleranceUpdate(uint256 indexed when, uint256 newValue);

    /// @notice get the minimum borrow amount
    function minBorrow() external view returns (uint256) {
        return (_minBorrow * 1e18) / creditMultiplier;
    }

    /// @notice get the maximum total issuance
    function maxTotalIssuance() external view returns (uint256) {
        return (_maxTotalIssuance * 1e18) / creditMultiplier;
    }

    /// @notice initialize references to GUILD & CREDIT tokens.
    function initializeReferences(
        address _credit,
        address _guild
    ) external onlyCoreRole(CoreRoles.GOVERNOR) {
        assert(credit == address(0) && guild == address(0));
        credit = _credit;
        guild = _guild;
    }

    /// @notice set the minimum borrow amount
    function setMinBorrow(
        uint256 newValue
    ) external onlyCoreRole(CoreRoles.GOVERNOR) {
        _minBorrow = newValue;
        emit MinBorrowUpdate(block.timestamp, newValue);
    }

    /// @notice set the maximum total issuance
    function setMaxTotalIssuance(
        uint256 newValue
    ) external onlyCoreRole(CoreRoles.GOVERNOR) {
        _maxTotalIssuance = newValue;
        emit MaxTotalIssuanceUpdate(block.timestamp, newValue);
    }

    /// @notice set the gauge weight tolerance
    function setGaugeWeightTolerance(
        uint256 newValue
    ) external onlyCoreRole(CoreRoles.GOVERNOR) {
        require(newValue >= 1e18, "ProfitManager: invalid tolerance");
        gaugeWeightTolerance = newValue;
        emit GaugeWeightToleranceUpdate(block.timestamp, newValue);
    }

    /// @notice set the profit sharing config.
    function setProfitSharingConfig(
        uint256 surplusBufferSplit,
        uint256 creditSplit,
        uint256 guildSplit,
        uint256 otherSplit,
        address otherRecipient
    ) external onlyCoreRole(CoreRoles.GOVERNOR) {
        if (otherRecipient == address(0)) {
            require(otherSplit == 0, "GuildToken: invalid config");
        } else {
            require(otherSplit != 0, "GuildToken: invalid config");
        }
        require(
            surplusBufferSplit + otherSplit + guildSplit + creditSplit == 1e18,
            "GuildToken: invalid config"
        );

        profitSharingConfig = ProfitSharingConfig({
            surplusBufferSplit: uint32(surplusBufferSplit / 1e9),
            guildSplit: uint32(guildSplit / 1e9),
            otherSplit: uint32(otherSplit / 1e9),
            otherRecipient: otherRecipient
        });

        emit ProfitSharingConfigUpdate(
            block.timestamp,
            surplusBufferSplit,
            creditSplit,
            guildSplit,
            otherSplit,
            otherRecipient
        );
    }

    /// @notice get the profit sharing config.
    function getProfitSharingConfig()
        external
        view
        returns (
            uint256 surplusBufferSplit,
            uint256 creditSplit,
            uint256 guildSplit,
            uint256 otherSplit,
            address otherRecipient
        )
    {
        surplusBufferSplit =
            uint256(profitSharingConfig.surplusBufferSplit) *
            1e9;
        guildSplit = uint256(profitSharingConfig.guildSplit) * 1e9;
        otherSplit = uint256(profitSharingConfig.otherSplit) * 1e9;
        creditSplit = 1e18 - surplusBufferSplit - guildSplit - otherSplit;
        otherRecipient = profitSharingConfig.otherRecipient;
    }

    /// @notice donate to surplus buffer
    function donateToSurplusBuffer(uint256 amount) external {
        uint256 newSurplusBuffer = surplusBuffer + amount;
        surplusBuffer = newSurplusBuffer;
        CreditToken(credit).transferFrom(msg.sender, address(this), amount);
        emit SurplusBufferUpdate(block.timestamp, newSurplusBuffer);
    }

    /// @notice donate to surplus buffer of a given term
    function donateToTermSurplusBuffer(address term, uint256 amount) external {
        CreditToken(credit).transferFrom(msg.sender, address(this), amount);
        uint256 newSurplusBuffer = termSurplusBuffer[term] + amount;
        termSurplusBuffer[term] = newSurplusBuffer;
        emit TermSurplusBufferUpdate(block.timestamp, term, newSurplusBuffer);
    }

    /// @notice withdraw from surplus buffer
    function withdrawFromSurplusBuffer(
        address to,
        uint256 amount
    ) external onlyCoreRole(CoreRoles.GUILD_SURPLUS_BUFFER_WITHDRAW) {
        uint256 newSurplusBuffer = surplusBuffer - amount; // this would revert due to underflow if withdrawing > surplusBuffer
        surplusBuffer = newSurplusBuffer;
        CreditToken(credit).transfer(to, amount);
        emit SurplusBufferUpdate(block.timestamp, newSurplusBuffer);
    }

    /// @notice withdraw from surplus buffer of a given term
    function withdrawFromTermSurplusBuffer(
        address term,
        address to,
        uint256 amount
    ) external onlyCoreRole(CoreRoles.GUILD_SURPLUS_BUFFER_WITHDRAW) {
        uint256 newSurplusBuffer = termSurplusBuffer[term] - amount; // this would revert due to underflow if withdrawing > termSurplusBuffer
        termSurplusBuffer[term] = newSurplusBuffer;
        CreditToken(credit).transfer(to, amount);
        emit TermSurplusBufferUpdate(block.timestamp, term, newSurplusBuffer);
    }

    /// @notice notify profit and loss in a given gauge
    /// if `amount` is > 0, the same number of CREDIT tokens are expected to be transferred to this contract
    /// before `notifyPnL` is called.
    function notifyPnL(
        address gauge,
        int256 amount,
        int256 issuanceDelta
    ) external onlyCoreRole(CoreRoles.GAUGE_PNL_NOTIFIER) {
        uint256 _surplusBuffer = surplusBuffer;
        uint256 _termSurplusBuffer = termSurplusBuffer[gauge];
        address _credit = credit;

        // underflow should not be possible because the issuance() in the
        // lending terms are all unsigned integers and they all notify on
        // increment/decrement.
        totalIssuance = uint256(int256(totalIssuance) + issuanceDelta);

        // check the maximum total issuance if the issuance is changing
        if (issuanceDelta > 0) {
            uint256 __maxTotalIssuance = (_maxTotalIssuance * 1e18) /
                creditMultiplier;
            require(
                totalIssuance <= __maxTotalIssuance,
                "ProfitManager: global debt ceiling reached"
            );
        }

        // handling loss
        if (amount < 0) {
            uint256 loss = uint256(-amount);

            // save gauge loss
            GuildToken(guild).notifyGaugeLoss(gauge);

            // deplete the term surplus buffer, if any, and
            // donate its content to the general surplus buffer
            if (_termSurplusBuffer != 0) {
                termSurplusBuffer[gauge] = 0;
                emit TermSurplusBufferUpdate(block.timestamp, gauge, 0);
                _surplusBuffer += _termSurplusBuffer;
            }

            if (loss < _surplusBuffer) {
                // deplete the surplus buffer
                surplusBuffer = _surplusBuffer - loss;
                emit SurplusBufferUpdate(
                    block.timestamp,
                    _surplusBuffer - loss
                );
                CreditToken(_credit).burn(loss);
            } else {
                // empty the surplus buffer
                loss -= _surplusBuffer;
                surplusBuffer = 0;
                CreditToken(_credit).burn(_surplusBuffer);
                emit SurplusBufferUpdate(block.timestamp, 0);

                // update the CREDIT multiplier
                uint256 creditTotalSupply = CreditToken(_credit)
                    .targetTotalSupply();
                uint256 newCreditMultiplier = 0;
                if (loss < creditTotalSupply) {
                    // a loss greater than the total supply could occur due to outstanding loan
                    // debts being rounded up through the formula in lending terms :
                    // principal = borrowed * openCreditMultiplier / currentCreditMultiplier
                    // In this case, the creditMultiplier is set to 0.
                    newCreditMultiplier =
                        (creditMultiplier * (creditTotalSupply - loss)) /
                        creditTotalSupply;
                }
                creditMultiplier = newCreditMultiplier;
                emit CreditMultiplierUpdate(
                    block.timestamp,
                    newCreditMultiplier
                );
            }
        }
        // handling profit
        else if (amount > 0) {
            ProfitSharingConfig
                memory _profitSharingConfig = profitSharingConfig;

            uint256 amountForSurplusBuffer = (uint256(amount) *
                uint256(_profitSharingConfig.surplusBufferSplit)) / 1e9;

            uint256 amountForGuild = (uint256(amount) *
                uint256(_profitSharingConfig.guildSplit)) / 1e9;

            uint256 amountForOther = (uint256(amount) *
                uint256(_profitSharingConfig.otherSplit)) / 1e9;

            // distribute to surplus buffer
            if (amountForSurplusBuffer != 0) {
                surplusBuffer = _surplusBuffer + amountForSurplusBuffer;
                emit SurplusBufferUpdate(
                    block.timestamp,
                    _surplusBuffer + amountForSurplusBuffer
                );
            }

            // distribute to other
            if (amountForOther != 0) {
                CreditToken(_credit).transfer(
                    _profitSharingConfig.otherRecipient,
                    amountForOther
                );
            }

            // distribute to lenders
            {
                uint256 amountForCredit = uint256(amount) -
                    amountForSurplusBuffer -
                    amountForGuild -
                    amountForOther;
                if (amountForCredit != 0) {
                    CreditToken(_credit).distribute(amountForCredit);
                }
            }

            // distribute to the guild
            if (amountForGuild != 0) {
                // update the gauge profit index
                // if the gauge has 0 weight, does not update the profit index, this is unnecessary
                // because the profit index is used to reattribute profit to users voting for the gauge,
                // and if the weigth is 0, there are no users voting for the gauge.
                uint256 _gaugeWeight = uint256(
                    GuildToken(guild).getGaugeWeight(gauge)
                );
                if (_gaugeWeight != 0) {
                    uint256 _gaugeProfitIndex = gaugeProfitIndex[gauge];
                    if (_gaugeProfitIndex == 0) {
                        _gaugeProfitIndex = 1e18;
                    }
                    gaugeProfitIndex[gauge] =
                        _gaugeProfitIndex +
                        (amountForGuild * 1e18) /
                        _gaugeWeight;
                }
            }
        }

        emit GaugePnL(gauge, block.timestamp, amount);
    }

    /// @notice claim a user's rewards for a given gauge.
    /// @dev This should be called every time the user's weight changes in the gauge.
    function claimGaugeRewards(
        address user,
        address gauge
    ) public returns (uint256 creditEarned) {
        uint256 _userGaugeWeight = uint256(
            GuildToken(guild).getUserGaugeWeight(user, gauge)
        );
        uint256 _userGaugeProfitIndex = userGaugeProfitIndex[user][gauge];
        if (_userGaugeProfitIndex == 0) {
            _userGaugeProfitIndex = 1e18;
        }
        uint256 _gaugeProfitIndex = gaugeProfitIndex[gauge];
        if (_gaugeProfitIndex == 0) {
            _gaugeProfitIndex = 1e18;
        }
        userGaugeProfitIndex[user][gauge] = _gaugeProfitIndex;
        if (_userGaugeWeight == 0) {
            return 0;
        }
        uint256 deltaIndex = _gaugeProfitIndex - _userGaugeProfitIndex;
        if (deltaIndex != 0) {
            creditEarned = (_userGaugeWeight * deltaIndex) / 1e18;
            emit ClaimRewards(block.timestamp, user, gauge, creditEarned);
            CreditToken(credit).transfer(user, creditEarned);
        }
    }

    /// @notice claim a user's rewards across all their active gauges.
    function claimRewards(
        address user
    ) external returns (uint256 creditEarned) {
        address[] memory gauges = GuildToken(guild).userGauges(user);
        for (uint256 i = 0; i < gauges.length; ) {
            creditEarned += claimGaugeRewards(user, gauges[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice read & return pending undistributed rewards for a given user
    function getPendingRewards(
        address user
    )
        external
        view
        returns (
            address[] memory gauges,
            uint256[] memory creditEarned,
            uint256 totalCreditEarned
        )
    {
        address _guild = guild;
        gauges = GuildToken(_guild).userGauges(user);
        creditEarned = new uint256[](gauges.length);

        for (uint256 i = 0; i < gauges.length; ) {
            address gauge = gauges[i];
            uint256 _gaugeProfitIndex = gaugeProfitIndex[gauge];
            uint256 _userGaugeProfitIndex = userGaugeProfitIndex[user][gauge];

            if (_gaugeProfitIndex == 0) {
                _gaugeProfitIndex = 1e18;
            }

            // this should never fail, because when the user increment weight
            // a call to claimGaugeRewards() is made that initializes this value
            assert(_userGaugeProfitIndex != 0);

            uint256 deltaIndex = _gaugeProfitIndex - _userGaugeProfitIndex;
            if (deltaIndex != 0) {
                uint256 _userGaugeWeight = uint256(
                    GuildToken(_guild).getUserGaugeWeight(user, gauge)
                );
                creditEarned[i] = (_userGaugeWeight * deltaIndex) / 1e18;
                totalCreditEarned += creditEarned[i];
            }

            unchecked {
                ++i;
            }
        }
    }
}
