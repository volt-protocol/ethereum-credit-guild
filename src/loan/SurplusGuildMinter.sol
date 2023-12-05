// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {SafeCastLib} from "@src/external/solmate/SafeCastLib.sol";

import {CoreRef} from "@src/core/CoreRef.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {ProfitManager} from "@src/governance/ProfitManager.sol";
import {RateLimitedMinter} from "@src/rate-limits/RateLimitedMinter.sol";

/// @notice SurplusGuildMinter allows GUILD to be minted from CREDIT collateral.
/// In this contract, CREDIT tokens can be provided as first-loss capital to
/// the surplus buffer of chosen terms, and in exchange, users can participate in the
/// gauge voting system at a reduced capital cost & without exposure to GUILD
/// token's price fluctuations. GUILD minted through this contract can only
/// participate in the gauge system to increase debt ceiling and earn fees
/// from selected lending terms.
/// @dev note that any update to the `rewardRatio` (through `setRewardRatio`) will
/// change the rewards of all pending unclaimed rewards. Before a proposal to update
/// the reward ratio execute, this contract should be pinged with `getRewards` for
/// all users that have pending rewards.
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
        uint256 amount
    );
    /// @notice emitted when a user is rewarded GUILD from non-zero interest
    /// rate and closing their position without loss.
    event GuildReward(
        uint256 indexed timestamp,
        address indexed user,
        uint256 amount
    );
    /// @notice emitted when the mintRatio is updated
    event MintRatioUpdate(uint256 indexed timestamp, uint256 ratio);
    /// @notice emitted when the rewardRatio is updated
    event RewardRatioUpdate(uint256 indexed timestamp, uint256 ratio);

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
    uint256 public mintRatio;

    /// @notice ratio of GUILD tokens earned per CREDIT tokens earned.
    /// expressed with 18 decimals, e.g. a ratio of 2e18 would provide 2e18
    /// GUILD tokens to a user that stakes earned 1e18 CREDIT tokens.
    uint256 public rewardRatio;

    struct UserStake {
        uint48 stakeTime;
        uint48 lastGaugeLoss;
        uint160 profitIndex;
        uint128 credit;
        uint128 guild;
    }

    /// @notice list of user stakes (stakes[user][term]=UserStake)
    mapping(address => mapping(address => UserStake)) internal _stakes;

    constructor(
        address _core,
        address _profitManager,
        address _credit,
        address _guild,
        address _rlgm,
        uint256 _mintRatio,
        uint256 _rewardRatio
    ) CoreRef(_core) {
        profitManager = _profitManager;
        credit = _credit;
        guild = _guild;
        rlgm = _rlgm;
        mintRatio = _mintRatio;
        rewardRatio = _rewardRatio;
    }

    /// @notice get a given user stake
    function getUserStake(
        address user,
        address term
    ) external view returns (UserStake memory) {
        return _stakes[user][term];
    }

    /// @notice stake CREDIT tokens to start voting in a gauge.
    function stake(address term, uint256 amount) external whenNotPaused {
        // apply pending rewards
        (uint256 lastGaugeLoss, UserStake memory userStake, ) = getRewards(
            msg.sender,
            term
        );

        require(
            lastGaugeLoss != block.timestamp,
            "SurplusGuildMinter: loss in block"
        );
        require(amount >= MIN_STAKE, "SurplusGuildMinter: min stake");

        // pull CREDIT from user & transfer it to surplus buffer
        CreditToken(credit).transferFrom(msg.sender, address(this), amount);
        CreditToken(credit).approve(address(profitManager), amount);
        ProfitManager(profitManager).donateToTermSurplusBuffer(term, amount);

        // self-mint GUILD tokens
        uint256 _mintRatio = mintRatio;
        uint256 guildAmount = (_mintRatio * amount) / 1e18;
        RateLimitedMinter(rlgm).mint(address(this), guildAmount);
        GuildToken(guild).incrementGauge(term, guildAmount);

        // update state
        userStake = UserStake({
            stakeTime: SafeCastLib.safeCastTo48(block.timestamp),
            lastGaugeLoss: SafeCastLib.safeCastTo48(lastGaugeLoss),
            profitIndex: SafeCastLib.safeCastTo160(
                ProfitManager(profitManager).userGaugeProfitIndex(
                    address(this),
                    term
                )
            ),
            credit: userStake.credit + SafeCastLib.safeCastTo128(amount),
            guild: userStake.guild + SafeCastLib.safeCastTo128(guildAmount)
        });
        _stakes[msg.sender][term] = userStake;

        // emit event
        emit Stake(block.timestamp, term, amount);
    }

    /// @notice unstake CREDIT tokens and stop voting in a gauge.
    function unstake(address term, uint256 amount) external {
        // apply pending rewards
        (, UserStake memory userStake, bool slashed) = getRewards(
            msg.sender,
            term
        );

        // if the user has been slashed, there is nothing to do
        if (slashed) return;

        // check that the user is at least staking `amount` CREDIT
        require(
            amount != 0 && userStake.credit >= amount,
            "SurplusGuildMinter: invalid amount"
        );

        // update stake
        uint256 userMintRatio = (uint256(userStake.guild) * 1e18) /
            userStake.credit; /// upcast guild to prevent overflow
        uint256 guildAmount = (userMintRatio * amount) / 1e18;

        if (amount == userStake.credit) guildAmount = userStake.guild;

        userStake.credit -= SafeCastLib.safeCastTo128(amount);
        userStake.guild -= SafeCastLib.safeCastTo128(guildAmount);

        if (userStake.credit == 0) {
            userStake.stakeTime = 0;
            userStake.lastGaugeLoss = 0;
            userStake.profitIndex = 0;
        } else {
            // if not unstaking all, make sure the stake remains
            // greater than the minimum stake
            require(
                userStake.credit >= MIN_STAKE,
                "SurplusGuildMinter: remaining stake below min"
            );
        }
        _stakes[msg.sender][term] = userStake;

        // withdraw & transfer CREDIT
        ProfitManager(profitManager).withdrawFromTermSurplusBuffer(
            term,
            msg.sender,
            amount
        );

        // burn GUILD
        GuildToken(guild).decrementGauge(term, guildAmount);
        RateLimitedMinter(rlgm).replenishBuffer(guildAmount);
        GuildToken(guild).burn(guildAmount);

        // emit event
        emit Unstake(block.timestamp, term, amount);
    }

    /// @notice get rewards from a staking position without unstaking.
    /// This can be used to slash users that have an outstanding unapplied loss.
    function getRewards(
        address user,
        address term
    )
        public
        returns (
            uint256 lastGaugeLoss, // GuildToken.lastGaugeLoss(term)
            UserStake memory userStake, // stake state after execution of getRewards()
            bool slashed // true if the user has been slashed
        )
    {
        bool updateState;
        lastGaugeLoss = GuildToken(guild).lastGaugeLoss(term);
        if (lastGaugeLoss > uint256(userStake.lastGaugeLoss)) {
            slashed = true;
        }

        // if the user is not staking, do nothing
        userStake = _stakes[user][term];
        if (userStake.stakeTime == 0)
            return (lastGaugeLoss, userStake, slashed);

        // compute CREDIT rewards
        ProfitManager(profitManager).claimRewards(address(this)); // this will update profit indexes
        uint256 _profitIndex = ProfitManager(profitManager)
            .userGaugeProfitIndex(address(this), term);
        uint256 _userProfitIndex = uint256(userStake.profitIndex);

        if (_profitIndex == 0) _profitIndex = 1e18;
        if (_userProfitIndex == 0) _userProfitIndex = 1e18;

        uint256 deltaIndex = _profitIndex - _userProfitIndex;

        if (deltaIndex != 0) {
            uint256 creditReward = (uint256(userStake.guild) * deltaIndex) /
                1e18;
            uint256 guildReward = (creditReward * rewardRatio) / 1e18;
            if (slashed) {
                guildReward = 0;
            }

            // forward rewards to user
            if (guildReward != 0) {
                RateLimitedMinter(rlgm).mint(user, guildReward);
                emit GuildReward(block.timestamp, user, guildReward);
            }
            if (creditReward != 0) {
                CreditToken(credit).transfer(user, creditReward);
            }

            // save the updated profitIndex
            userStake.profitIndex = SafeCastLib.safeCastTo160(_profitIndex);
            updateState = true;
        }

        // if a loss occurred while the user was staking, the GuildToken.applyGaugeLoss(address(this))
        // can be called by anyone to slash address(this) and decrement gauge weight etc.
        // The contribution to the surplus buffer is also forfeited.
        if (slashed) {
            emit Unstake(block.timestamp, term, uint256(userStake.credit));
            userStake = UserStake({
                stakeTime: uint48(0),
                lastGaugeLoss: uint48(0),
                profitIndex: uint160(0),
                credit: uint128(0),
                guild: uint128(0)
            });
            updateState = true;
        }

        // store the updated stake, if needed
        if (updateState) {
            _stakes[user][term] = userStake;
        }
    }

    /// @notice update the mint ratio for a given user.
    function updateMintRatio(address user, address term) external {
        // apply pending rewards
        (, UserStake memory userStake, bool slashed) = getRewards(user, term);

        // if the user has been slashed or isnt staking, there is nothing to do
        if (userStake.stakeTime == 0 || slashed) return;

        // update amount of GUILD tokens staked
        uint256 guildBefore = uint256(userStake.guild);
        uint256 guildAfter = (mintRatio * uint256(userStake.credit)) / 1e18;
        if (guildAfter > guildBefore) {
            uint256 guildAmount = guildAfter - guildBefore;
            RateLimitedMinter(rlgm).mint(address(this), guildAmount);
            GuildToken(guild).incrementGauge(term, guildAmount);
            _stakes[user][term].guild = SafeCastLib.safeCastTo128(guildAfter);
        } else if (guildAfter < guildBefore) {
            uint256 guildAmount = guildBefore - guildAfter;
            GuildToken(guild).decrementGauge(term, guildAmount);
            RateLimitedMinter(rlgm).replenishBuffer(guildAmount);
            GuildToken(guild).burn(guildAmount);
            _stakes[user][term].guild = SafeCastLib.safeCastTo128(guildAfter);
        }
    }

    /// @notice governor-only function to set the ratio of GUILD tokens minted
    /// per CREDIT tokens contributed to the surplus buffer.
    function setMintRatio(
        uint256 _mintRatio
    ) external onlyCoreRole(CoreRoles.GOVERNOR) {
        mintRatio = _mintRatio;
        emit MintRatioUpdate(block.timestamp, _mintRatio);
    }

    /// @notice governor-only function to set the ratio of GUILD tokens rewarded
    /// per CREDIT tokens earned from GUILD staking.
    function setRewardRatio(
        uint256 _rewardRatio
    ) external onlyCoreRole(CoreRoles.GOVERNOR) {
        rewardRatio = _rewardRatio;
        emit RewardRatioUpdate(block.timestamp, _rewardRatio);
    }
}
