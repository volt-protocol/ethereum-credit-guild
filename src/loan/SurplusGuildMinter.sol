// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {CoreRef} from "@src/core/CoreRef.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {ProfitManager} from "@src/governance/ProfitManager.sol";
import {RateLimitedMinter} from "@src/rate-limits/RateLimitedMinter.sol";

/// @notice SurplusGuildMinter allows GUILD to be minted from CREDIT collateral.
/// In this contract, CREDIT tokens can be provided as first-loss capital to
/// the surplus buffer, and in exchange, users can participate in the gauge
/// voting system at a reduced capital cost & without exposure to GUILD
/// token's price fluctuations. GUILD minted through this contract can only
/// participate in the gauge system to increase debt ceiling and earn fees
/// from selected lending terms.
contract SurplusGuildMinter is CoreRef {
    /// @notice minimum number of CREDIT to stake
    uint256 public constant MIN_STAKE = 1e18;

    /// @notice reference number of seconds in 1 year
    uint256 public constant YEAR = 31557600;

    /// @notice emitted when a user stakes CREDIT on a target lending term
    event Stake(
        uint256 indexed timestamp,
        address indexed term,
        uint256 amount
    );
    /// @notice emitted when a user unstakes CREDIT on a target lending term
    event Unstake(
        uint256 indexed timestamp,
        address indexed term,
        uint256 amount,
        uint256 reward,
        int256 pnl
    );
    /// @notice emitted when a user is rewarded GUILD from non-zero interest
    /// rate and closing their position without loss.
    event GuildReward(
        uint256 indexed timestamp,
        address indexed user,
        uint256 amount
    );

    /// @notice reference to the ProfitManager
    address public immutable profitManager;

    /// @notice reference to the CREDIT token
    address public immutable credit;

    /// @notice reference to the GUILD token
    address public immutable guild;

    /// @notice reference to the RateLimitedGuildMinter
    address public immutable rlgm;

    /// @notice ratio of GUILD tokens minted per CREDIT tokens staked.
    /// expressed with 18 decimals, e.g. a ratio of 2e18 would provide 2e18
    /// GUILD tokens to a user that stakes 1e18 CREDIT tokens.
    uint256 public ratio;

    /// @notice Negative interest rate of GUILD tokens borrowed, expressed
    /// as a percentage with 18 decimals. e.g. 0.1e18 interest rate for a user
    /// that borrow GUILD for 1 year would mint the user 10% of the GUILD they
    /// provided first-loss capital for 1 year when they unstake.
    uint256 public interestRate;

    /// @notice list of user stakes (stakes[user][term]=stake)
    mapping(address => mapping(address => uint256)) public stakes;

    /// @notice list of user stake timestamps (stakeTimestamp[user][term]=timestamp)
    mapping(address => mapping(address => uint256)) public stakeTimestamp;

    /// @notice list of ratio when users staked (stakeRatio[user][term]=ratio)
    mapping(address => mapping(address => uint256)) public stakeRatio;

    /// @notice list of interest rates when users staked (stakeInterestRate[user][term]=interestRate)
    mapping(address => mapping(address => uint256)) public stakeInterestRate;

    /// @notice list of lastGaugeLoss when users entered gauges (lastGaugeLoss[user][term]=timestamp)
    mapping(address => mapping(address => uint256)) internal lastGaugeLoss;

    /// @notice list of profitIndex when users entered gauges (profitIndex[user][term]=index)
    mapping(address => mapping(address => uint256)) internal profitIndex;

    constructor(
        address _core,
        address _profitManager,
        address _credit,
        address _guild,
        address _rlgm,
        uint256 _ratio,
        uint256 _interestRate
    ) CoreRef(_core) {
        profitManager = _profitManager;
        credit = _credit;
        guild = _guild;
        rlgm = _rlgm;
        ratio = _ratio;
        interestRate = _interestRate;
    }

    /// @notice stake CREDIT tokens to start voting in a gauge.
    function stake(address term, uint256 amount) external whenNotPaused {
        require(amount >= MIN_STAKE, "SurplusGuildMinter: min stake");

        // pull CREDIT from user & transfer it to surplus buffer
        CreditToken(credit).transferFrom(msg.sender, address(this), amount);
        CreditToken(credit).approve(address(profitManager), amount);
        ProfitManager(profitManager).donateToSurplusBuffer(amount);

        // self-mint GUILD tokens
        uint256 _ratio = ratio;
        uint256 guildAmount = (_ratio * amount) / 1e18;
        RateLimitedMinter(rlgm).mint(address(this), guildAmount);
        GuildToken(guild).incrementGauge(term, guildAmount);

        // update state
        require(
            stakes[msg.sender][term] == 0,
            "SurplusGuildMinter: already staking"
        );
        stakes[msg.sender][term] = amount;
        lastGaugeLoss[msg.sender][term] = GuildToken(guild).lastGaugeLoss(term);
        profitIndex[msg.sender][term] = ProfitManager(profitManager)
            .userGaugeProfitIndex(address(this), term);
        stakeRatio[msg.sender][term] = _ratio;
        stakeInterestRate[msg.sender][term] = interestRate;
        stakeTimestamp[msg.sender][term] = block.timestamp;

        // emit event
        emit Stake(block.timestamp, term, amount);
    }

    /// @notice unstake CREDIT tokens and stop voting in a gauge.
    /// user must have been staking for at least one block.
    function unstake(address term) external {
        // check that the user is staking
        uint256 creditStaked = stakes[msg.sender][term];
        require(creditStaked != 0, "SurplusGuildMinter: not staking");

        // check if losses (slashing) occurred since user joined
        uint256 _lastGaugeLoss = GuildToken(guild).lastGaugeLoss(term);
        uint256 _userLastGaugeLoss = lastGaugeLoss[msg.sender][term];

        // compute CREDIT rewards
        ProfitManager(profitManager).claimRewards(address(this)); // this will update profit indexes
        uint256 _profitIndex = ProfitManager(profitManager)
            .userGaugeProfitIndex(address(this), term);
        uint256 _userProfitIndex = profitIndex[msg.sender][term];
        if (_profitIndex == 0) _profitIndex = 1e18;
        if (_userProfitIndex == 0) _userProfitIndex = 1e18;
        uint256 deltaIndex = _profitIndex - _userProfitIndex;
        uint256 guildAmount = (stakeRatio[msg.sender][term] * creditStaked) /
            1e18;
        uint256 guildReward;
        uint256 creditToUser;
        if (deltaIndex != 0) {
            creditToUser += (guildAmount * deltaIndex) / 1e18;
        }

        // if a loss occurred while the user was staking, the GuildToken.applyGaugeLoss(address(this))
        // can be called by anyone to slash address(this) and decrement gauge weight etc. The contribution
        // to the surplus buffer is also forfeited.
        // if no loss occurred while the user was staking :
        if (
            _lastGaugeLoss == 0 ||
            (_lastGaugeLoss == _userLastGaugeLoss &&
                _lastGaugeLoss != block.timestamp)
        ) {
            // decrement GUILD voting weight
            GuildToken(guild).decrementGauge(term, guildAmount);

            // pull CREDIT from surplus buffer
            ProfitManager(profitManager).withdrawFromSurplusBuffer(
                creditStaked
            );
            creditToUser += creditStaked;

            // replenish GUILD minter buffer
            GuildToken(guild).burn(guildAmount);
            RateLimitedMinter(rlgm).replenishBuffer(guildAmount);

            // mint interest rates to users
            guildReward =
                (((guildAmount * stakeInterestRate[msg.sender][term]) / 1e18) *
                    (block.timestamp - stakeTimestamp[msg.sender][term])) /
                YEAR;
            if (guildReward != 0) {
                RateLimitedMinter(rlgm).mint(msg.sender, guildReward);
                emit GuildReward(block.timestamp, msg.sender, guildReward);
            }
        }

        // forward CREDIT principal + rewards to user
        if (creditToUser != 0) {
            CreditToken(credit).transfer(msg.sender, creditToUser);
        }

        // update state
        stakes[msg.sender][term] = 0;

        // emit event
        emit Unstake(
            block.timestamp,
            term,
            creditStaked,
            guildReward,
            int256(creditToUser) - int256(creditStaked)
        );
    }

    /// @notice downgrade a position that has been opened with a higher ratio than
    /// what is currently set, or an interest rate higher than what is currently set.
    /// positions that did not realize slashing can also be downgraded to be closed,
    /// equivalent as if the user called unstake().
    function downgrade(address user, address term) external {
        // check that the user is staking
        uint256 creditStaked = stakes[user][term];
        require(creditStaked != 0, "SurplusGuildMinter: not staking");

        // check that the position can be downgraded
        uint256 _ratio = ratio;
        uint256 _interestRate = interestRate;
        require(stakeRatio[user][term] > _ratio || stakeInterestRate[user][term] > _interestRate, "SurplusGuildMinter: cannot downgrade");

        // check if losses (slashing) occurred since user joined
        uint256 _lastGaugeLoss = GuildToken(guild).lastGaugeLoss(term);
        uint256 _userLastGaugeLoss = lastGaugeLoss[user][term];

        // compute CREDIT rewards
        ProfitManager(profitManager).claimRewards(address(this)); // this will update profit indexes
        uint256 _profitIndex = ProfitManager(profitManager).userGaugeProfitIndex(address(this), term);
        if (_profitIndex == 0) _profitIndex = 1e18;
        uint256 guildAmount = stakeRatio[user][term] * creditStaked / 1e18;
        uint256 creditToUser;
        {
            uint256 _userProfitIndex = profitIndex[user][term];
            if (_userProfitIndex == 0) _userProfitIndex = 1e18;
            uint256 deltaIndex = _profitIndex - _userProfitIndex;
            if (deltaIndex != 0) {
                creditToUser = guildAmount * deltaIndex / 1e18;
            }
        }

        // if a loss occurred while the user was staking, the GuildToken.applyGaugeLoss(address(this))
        // can be called by anyone to slash address(this) and decrement gauge weight etc. The contribution
        // to the surplus buffer is also forfeited.
        // if no loss occurred while the user was staking :
        if (
            _lastGaugeLoss == 0 ||
            (_lastGaugeLoss == _userLastGaugeLoss &&
                _lastGaugeLoss != block.timestamp)
        ) {
            {
                uint256 guildDecrement = guildAmount - (_ratio * creditStaked / 1e18);
                if (guildDecrement != 0) {
                    // decrement GUILD voting weight
                    GuildToken(guild).decrementGauge(term, guildDecrement);

                    // replenish GUILD minter buffer
                    GuildToken(guild).burn(guildDecrement);
                    RateLimitedMinter(rlgm).replenishBuffer(guildDecrement);
                }
            }

            // mint interest rates to users
            uint256 guildReward =
                (((guildAmount * stakeInterestRate[user][term]) / 1e18) *
                    (block.timestamp - stakeTimestamp[user][term])) /
                YEAR;
            if (guildReward != 0) {
                RateLimitedMinter(rlgm).mint(user, guildReward);
                emit GuildReward(block.timestamp, user, guildReward);
            }

            // update state
            profitIndex[user][term] = _profitIndex;
            stakeRatio[user][term] = _ratio;
            stakeInterestRate[user][term] = _interestRate;
            stakeTimestamp[user][term] = block.timestamp;

            // emit events
            emit Unstake(
                block.timestamp,
                term,
                creditStaked,
                guildReward,
                int256(creditToUser)
            );
            emit Stake(block.timestamp, term, creditStaked);
        } else {
            // loss happened, set staking position to 0
            emit Unstake(
                block.timestamp,
                term,
                creditStaked,
                0, // no guildReward
                int256(creditToUser) - int256(creditStaked)
            );

            stakes[msg.sender][term] = 0;
        }

        // forward CREDIT rewards to user
        if (creditToUser != 0) {
            CreditToken(credit).transfer(user, creditToUser);
        }
    }

    /// @notice governor-only function to set the ratio of GUILD tokens minted
    /// per CREDIT tokens contributed to the surplus buffer.
    function setRatio(
        uint256 _ratio
    ) external onlyCoreRole(CoreRoles.GOVERNOR) {
        ratio = _ratio;
    }

    /// @notice governor-only function to set the interest rate of GUILD tokens
    /// borrowed through the SurplusGuildMinter.
    function setInterestRate(
        uint256 _interestRate
    ) external onlyCoreRole(CoreRoles.GOVERNOR) {
        interestRate = _interestRate;
    }
}
