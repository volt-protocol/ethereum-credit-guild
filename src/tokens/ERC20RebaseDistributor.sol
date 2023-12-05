// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeCastLib} from "@src/external/solmate/SafeCastLib.sol";

/** 
@title  An ERC20 with rebase capabilities. Anyone can sacrifice tokens to rebase up the balance
        of all addresses that are currently rebasing.
@author eswak
@notice This contract is meant to be used to distribute rewards proportionately to all holders of
        a token, for instance to distribute buybacks or income generated by a protocol.

        Anyone can subscribe to rebasing by calling `enterRebase()`, and unsubcribe with `exitRebase()`.
        Anyone can burn tokens they own to `distribute(uint256)` proportionately to rebasing addresses.

        The following conditions are always met :
        ```
        totalSupply() == nonRebasingSupply() + rebasingSupply()
        sum of balanceOf(x) == totalSupply() [+= rounding down errors of 1 wei for each balanceOf]
        ```

        Internally, when a user subscribes to the rebase, their balance is converted to a number of
        shares, and the total number of shares is updated. When a user unsubscribes, their shares are
        converted back to a balance, and the total number of shares is updated.

        On each distribution, the share price of rebasing tokens is updated to reflect the new value
        of rebasing shares. The formula is as follow :

        ```
        newSharePrice = oldSharePrice * (rebasingSupply + amount) / rebasingSupply
        ```

        If the rebasingSupply is 0 (nobody subscribed to rebasing), the tokens distributed are burnt
        but nobody benefits for the share price increase, since the share price cannot be updated.

        /!\ The first user subscribing to rebase should have a meaningful balance in order to avoid
        share price manipulation (see hundred finance exploit).
        It is advised to keep a minimum balance rebasing at all times, for instance with a small
        rebasing balance held by the deployer address or address(0) or the token itself.
*/
abstract contract ERC20RebaseDistributor is ERC20 {
    /*///////////////////////////////////////////////////////////////
                            EVENTS
    ///////////////////////////////////////////////////////////////*/

    /// @notice Emitted when an `account` enters rebasing.
    event RebaseEnter(address indexed account, uint256 indexed timestamp);
    /// @notice Emitted when an `account` exits rebasing.
    event RebaseExit(address indexed account, uint256 indexed timestamp);
    /// @notice Emitted when an `amount` of tokens is distributed by `source` to the rebasing accounts.
    event RebaseDistribution(
        address indexed source,
        uint256 indexed timestamp,
        uint256 amountDistributed,
        uint256 amountRebasing
    );
    /// @notice Emitted when an `amount` of tokens is realized as rebase rewards for `account`.
    /// @dev `totalSupply()`, `rebasingSupply()`, and `balanceOf()` reflect the rebase rewards
    /// in real time, but the internal storage only realizes rebase rewards if the user has an
    /// interaction with the token contract in one of the following functions:
    /// - exitRebase()
    /// - burn()
    /// - mint()
    /// - transfer() received or sent
    /// - transferFrom() received or sent
    event RebaseReward(
        address indexed account,
        uint256 indexed timestamp,
        uint256 amount
    );

    /*///////////////////////////////////////////////////////////////
                            INTERNAL STATE
    ///////////////////////////////////////////////////////////////*/

    struct RebasingState {
        uint8 isRebasing;
        uint248 nShares;
    }

    /// @notice For internal accounting. Number of rebasing shares for each rebasing accounts. 0 if account is not rebasing.
    mapping(address => RebasingState) internal rebasingState;

    /// @notice For internal accounting. Total number of rebasing shares
    uint256 internal totalRebasingShares;

    /// @notice The starting share price for rebasing addresses.
    /// @dev rounding errors start to appear when balances of users are near `rebasingSharePrice()`,
    /// due to rounding down in the number of shares attributed, and rounding down in the number of
    /// tokens per share. We use a high base to ensure no crazy rounding errors happen at runtime
    /// (balances of users would have to be > START_REBASING_SHARE_PRICE for rounding errors to start to materialize).
    uint256 internal constant START_REBASING_SHARE_PRICE = 1e30;

    /// @notice share price increase and pending rebase rewards from distribute() are
    /// interpolated linearly over a period of DISTRIBUTION_PERIOD seconds after a distribution.
    uint256 public constant DISTRIBUTION_PERIOD = 30 days;

    struct InterpolatedValue {
        uint32 lastTimestamp;
        uint224 lastValue;
        uint32 targetTimestamp;
        uint224 targetValue;
    }

    /// @notice For internal accounting. Number of tokens per share for the rebasing supply.
    /// Starts at START_REBASING_SHARE_PRICE and goes up only.
    InterpolatedValue internal __rebasingSharePrice =
        InterpolatedValue({
            lastTimestamp: SafeCastLib.safeCastTo32(block.timestamp),
            lastValue: uint224(START_REBASING_SHARE_PRICE), // safe initial value
            targetTimestamp: SafeCastLib.safeCastTo32(block.timestamp),
            targetValue: uint224(START_REBASING_SHARE_PRICE) // safe initial value
        });

    /// @notice For internal accounting. Number of tokens distributed to rebasing addresses that have not
    /// yet been materialized by a movement in the rebasing addresses.
    InterpolatedValue internal __unmintedRebaseRewards =
        InterpolatedValue({
            lastTimestamp: SafeCastLib.safeCastTo32(block.timestamp),
            lastValue: 0,
            targetTimestamp: SafeCastLib.safeCastTo32(block.timestamp),
            targetValue: 0
        });

    /*///////////////////////////////////////////////////////////////
                            INTERNAL UTILS
    ///////////////////////////////////////////////////////////////*/

    /// @notice get the current value of an interpolated value
    function interpolatedValue(
        InterpolatedValue memory val
    ) internal view returns (uint256) {
        // load state
        uint256 lastTimestamp = uint256(val.lastTimestamp); // safe upcast
        uint256 lastValue = uint256(val.lastValue); // safe upcast
        uint256 targetTimestamp = uint256(val.targetTimestamp); // safe upcast
        uint256 targetValue = uint256(val.targetValue); // safe upcast

        // interpolate increase over period
        if (block.timestamp >= targetTimestamp) {
            // if period is passed, return target value
            return targetValue;
        } else {
            // block.timestamp is within [lastTimestamp, targetTimestamp[
            uint256 elapsed = block.timestamp - lastTimestamp;
            uint256 delta = targetValue - lastValue;
            return
                lastValue +
                (delta * elapsed) /
                (targetTimestamp - lastTimestamp);
        }
    }

    /// @notice called to update the number of rebasing shares.
    /// This can happen in multiple situations:
    /// - enterRebase()
    /// - exitRebase()
    /// - burn() from a rebasing address
    /// - mint() to a rebasing address
    /// - transfer() from a rebasing address
    /// - transfer() to a rebasing address
    /// - transferFrom() from a rebasing address
    /// - transferFrom() to a rebasing address
    /// If the number of shares is updated during the interpolation, the target share price
    /// of the interpolation should be changed to reflect the reduced or increased number of shares
    /// and keep a constant rebasing supply value (current & target).
    function updateTotalRebasingShares(
        uint256 currentRebasingSharePrice,
        int256 sharesDelta
    ) internal {
        if (sharesDelta == 0) return;
        uint256 sharesBefore = totalRebasingShares;
        uint256 sharesAfter;
        if (sharesDelta > 0) {
            sharesAfter = sharesBefore + uint256(sharesDelta);
        } else {
            uint256 shareDecrease = uint256(-sharesDelta);
            if (shareDecrease < sharesBefore) {
                unchecked {
                    sharesAfter = sharesBefore - shareDecrease;
                }
            }
            // else sharesAfter stays 0
        }
        totalRebasingShares = sharesAfter;

        // reset interpolation & share price if going to 0 rebasing supply
        if (sharesAfter == 0) {
            __rebasingSharePrice = InterpolatedValue({
                lastTimestamp: SafeCastLib.safeCastTo32(block.timestamp), // now
                lastValue: uint224(START_REBASING_SHARE_PRICE), // safe initial value
                targetTimestamp: SafeCastLib.safeCastTo32(block.timestamp), // now
                targetValue: uint224(START_REBASING_SHARE_PRICE) // safe initial value
            });
            __unmintedRebaseRewards = InterpolatedValue({
                lastTimestamp: SafeCastLib.safeCastTo32(block.timestamp),
                lastValue: 0,
                targetTimestamp: SafeCastLib.safeCastTo32(block.timestamp),
                targetValue: 0
            });
            return;
        }

        // when total shares is multiplied by x, the remaining share price change ("delta" below)
        // should be multiplied by 1/x, e.g. going from a share price of 1.0 to 1.5, and current
        // value is 1.25, the remaining share price change "delta" is 0.25.
        // if the rebasing supply 2x, the share price change should 0.5x to 0.125.
        // at the end of the interpolation period, the share price will be 1.375.
        InterpolatedValue memory val = __rebasingSharePrice;
        uint256 delta = uint256(val.targetValue) - currentRebasingSharePrice;
        if (delta != 0) {
            uint256 percentChange = (sharesAfter * START_REBASING_SHARE_PRICE) /
                sharesBefore;
            uint256 targetNewSharePrice = currentRebasingSharePrice +
                (delta * START_REBASING_SHARE_PRICE) /
                percentChange;
            __rebasingSharePrice = InterpolatedValue({
                lastTimestamp: SafeCastLib.safeCastTo32(block.timestamp), // now
                lastValue: SafeCastLib.safeCastTo224(currentRebasingSharePrice), // current value
                targetTimestamp: val.targetTimestamp, // unchanged
                targetValue: SafeCastLib.safeCastTo224(targetNewSharePrice) // adjusted target
            });
        }
    }

    /// @notice decrease unminted rebase rewards, when rewards are minted to users
    function decreaseUnmintedRebaseRewards(uint256 amount) internal {
        InterpolatedValue memory val = __unmintedRebaseRewards;
        uint256 _unmintedRebaseRewards = interpolatedValue(val);
        __unmintedRebaseRewards = InterpolatedValue({
            lastTimestamp: SafeCastLib.safeCastTo32(block.timestamp), // now
            lastValue: SafeCastLib.safeCastTo224(
                _unmintedRebaseRewards - amount
            ), // adjusted current
            targetTimestamp: val.targetTimestamp, // unchanged
            targetValue: val.targetValue - SafeCastLib.safeCastTo224(amount) // adjusted target
        });
    }

    /// @notice get the current rebasing share price
    function rebasingSharePrice() internal view returns (uint256) {
        return interpolatedValue(__rebasingSharePrice);
    }

    /// @notice get the current unminted rebase rewards
    function unmintedRebaseRewards() internal view returns (uint256) {
        return interpolatedValue(__unmintedRebaseRewards);
    }

    /// @notice convert a balance to a number of shares
    function _balance2shares(
        uint256 balance,
        uint256 sharePrice
    ) internal pure returns (uint256) {
        return (balance * START_REBASING_SHARE_PRICE) / sharePrice;
    }

    /// @notice convert a number of shares to a balance
    function _shares2balance(
        uint256 shares,
        uint256 sharePrice,
        uint256 deltaBalance,
        uint256 minBalance
    ) internal pure returns (uint256) {
        uint256 rebasedBalance = (shares * sharePrice) /
            START_REBASING_SHARE_PRICE +
            deltaBalance;
        if (rebasedBalance < minBalance) {
            rebasedBalance = minBalance;
        }
        return rebasedBalance;
    }

    /*///////////////////////////////////////////////////////////////
                            EXTERNAL API
    ///////////////////////////////////////////////////////////////*/

    /// @notice Enter rebasing supply. All subsequent distributions will increase the balance
    /// of `msg.sender` proportionately.
    function enterRebase() external {
        require(
            rebasingState[msg.sender].isRebasing == 0,
            "ERC20RebaseDistributor: already rebasing"
        );
        _enterRebase(msg.sender);
    }

    function _enterRebase(address account) internal {
        uint256 balance = ERC20.balanceOf(account);
        uint256 currentRebasingSharePrice = rebasingSharePrice();
        uint256 shares = _balance2shares(balance, currentRebasingSharePrice);
        rebasingState[account] = RebasingState({
            isRebasing: 1,
            nShares: uint248(shares)
        });
        updateTotalRebasingShares(currentRebasingSharePrice, int256(shares));
        emit RebaseEnter(account, block.timestamp);
    }

    /// @notice Exit rebasing supply. All unminted rebasing rewards are physically minted to the user,
    /// and they won't be affected by rebases anymore.
    function exitRebase() external {
        require(
            rebasingState[msg.sender].isRebasing == 1,
            "ERC20RebaseDistributor: not rebasing"
        );
        _exitRebase(msg.sender);
    }

    function _exitRebase(address account) internal {
        uint256 rawBalance = ERC20.balanceOf(account);
        RebasingState memory _rebasingState = rebasingState[account];
        uint256 shares = uint256(_rebasingState.nShares);
        uint256 currentRebasingSharePrice = rebasingSharePrice();
        uint256 rebasedBalance = _shares2balance(
            shares,
            currentRebasingSharePrice,
            0,
            rawBalance
        );
        uint256 mintAmount = rebasedBalance - rawBalance;
        if (mintAmount != 0) {
            ERC20._mint(account, mintAmount);
            decreaseUnmintedRebaseRewards(mintAmount);
            emit RebaseReward(account, block.timestamp, mintAmount);
        }

        rebasingState[account] = RebasingState({isRebasing: 0, nShares: 0});
        updateTotalRebasingShares(currentRebasingSharePrice, -int256(shares));

        emit RebaseExit(account, block.timestamp);
    }

    /// @notice distribute tokens proportionately to all rebasing accounts.
    /// @dev if no addresses are rebasing, calling this function will burn tokens
    /// from `msg.sender` and emit an event, but won't rebase up any balances.
    function distribute(uint256 amount) external {
        require(amount != 0, "ERC20RebaseDistributor: cannot distribute zero");

        // burn the tokens received
        _burn(msg.sender, amount);

        // emit event
        uint256 _rebasingSharePrice = rebasingSharePrice();
        uint256 _totalRebasingShares = totalRebasingShares;
        uint256 _rebasingSupply = _shares2balance(
            _totalRebasingShares,
            _rebasingSharePrice,
            0,
            0
        );
        emit RebaseDistribution(
            msg.sender,
            block.timestamp,
            amount,
            _rebasingSupply
        );

        // adjust up the balance of all accounts that are rebasing by increasing
        // the share price of rebasing tokens
        if (_rebasingSupply != 0) {
            // update rebasingSharePrice interpolation
            uint256 endTimestamp = block.timestamp + DISTRIBUTION_PERIOD;
            uint256 newTargetSharePrice = (amount *
                START_REBASING_SHARE_PRICE +
                __rebasingSharePrice.targetValue *
                _totalRebasingShares) / _totalRebasingShares;
            __rebasingSharePrice = InterpolatedValue({
                lastTimestamp: SafeCastLib.safeCastTo32(block.timestamp),
                lastValue: SafeCastLib.safeCastTo224(_rebasingSharePrice),
                targetTimestamp: SafeCastLib.safeCastTo32(endTimestamp),
                targetValue: SafeCastLib.safeCastTo224(newTargetSharePrice)
            });

            // update unmintedRebaseRewards interpolation
            uint256 _unmintedRebaseRewards = unmintedRebaseRewards();
            __unmintedRebaseRewards = InterpolatedValue({
                lastTimestamp: SafeCastLib.safeCastTo32(block.timestamp),
                lastValue: SafeCastLib.safeCastTo224(_unmintedRebaseRewards),
                targetTimestamp: SafeCastLib.safeCastTo32(endTimestamp),
                targetValue: __unmintedRebaseRewards.targetValue +
                    SafeCastLib.safeCastTo224(amount)
            });
        }
    }

    /// @notice True if an address subscribed to rebasing.
    function isRebasing(address account) public view returns (bool) {
        return rebasingState[account].isRebasing == 1;
    }

    /// @notice Total number of the tokens that are rebasing.
    function rebasingSupply() public view returns (uint256) {
        return _shares2balance(totalRebasingShares, rebasingSharePrice(), 0, 0);
    }

    /// @notice Total number of the tokens that are not rebasing.
    function nonRebasingSupply() external view virtual returns (uint256) {
        uint256 _totalSupply = totalSupply();
        uint256 _rebasingSupply = rebasingSupply();

        // compare rebasing supply to total supply :
        // rounding errors due to share price & number of shares could otherwise
        // make this function revert due to an underflow
        if (_rebasingSupply > _totalSupply) {
            return 0;
        } else {
            return _totalSupply - _rebasingSupply;
        }
    }

    /// @notice get the number of distributed tokens that have not yet entered
    /// circulation through rebase due to the interpolation of rewards over time.
    function pendingDistributedSupply() external view returns (uint256) {
        InterpolatedValue memory val = __unmintedRebaseRewards;
        uint256 _unmintedRebaseRewards = interpolatedValue(val);
        return __unmintedRebaseRewards.targetValue - _unmintedRebaseRewards;
    }

    /*///////////////////////////////////////////////////////////////
                            ERC20 OVERRIDE
    ///////////////////////////////////////////////////////////////*/

    /// @notice Override of balanceOf() that takes into account the unminted rebase rewards.
    function balanceOf(
        address account
    ) public view virtual override returns (uint256) {
        RebasingState memory _rebasingState = rebasingState[account];
        if (_rebasingState.isRebasing == 0) {
            return ERC20.balanceOf(account);
        } else {
            return
                _shares2balance(
                    _rebasingState.nShares,
                    rebasingSharePrice(),
                    0,
                    ERC20.balanceOf(account)
                );
        }
    }

    /// @notice Total number of the tokens in existence.
    function totalSupply() public view virtual override returns (uint256) {
        return ERC20.totalSupply() + unmintedRebaseRewards();
    }

    /// @notice Target total number of the tokens in existence after interpolations
    /// of rebase rewards will have completed.
    /// @dev Equal to totalSupply() + pendingDistributedSupply().
    function targetTotalSupply() external view returns (uint256) {
        return ERC20.totalSupply() + __unmintedRebaseRewards.targetValue;
    }

    /// @notice Override of default ERC20 behavior: exit rebase before movement (if rebasing),
    /// and re-enter rebasing after movement (if rebasing).
    /// @dev for _burn(), _mint(), transfer(), and transferFrom() overrides, a naive
    /// and concise implementation would be to just _exitRebase(), call the default ERC20 behavior,
    /// and then _enterRebase(), on the 2 addresses affected by the movement, but this is highly gas
    /// inefficient and the more complex implementations below are saving up to 40% gas costs.
    function _burn(address account, uint256 amount) internal virtual override {
        // if `account` is rebasing, materialize the tokens from rebase first, to ensure
        // proper behavior in `ERC20._burn()`.
        RebasingState memory _rebasingState = rebasingState[account];
        uint256 balanceBefore;
        uint256 _rebasingSharePrice;
        if (_rebasingState.isRebasing == 1) {
            balanceBefore = ERC20.balanceOf(account);
            _rebasingSharePrice = rebasingSharePrice();
            uint256 rebasedBalance = _shares2balance(
                _rebasingState.nShares,
                _rebasingSharePrice,
                0,
                balanceBefore
            );
            uint256 mintAmount = rebasedBalance - balanceBefore;
            if (mintAmount != 0) {
                ERC20._mint(account, mintAmount);
                balanceBefore += mintAmount;
                decreaseUnmintedRebaseRewards(mintAmount);
                emit RebaseReward(account, block.timestamp, mintAmount);
            }
        }

        // do ERC20._burn()
        ERC20._burn(account, amount);

        // if `account` is rebasing, update its number of shares
        if (_rebasingState.isRebasing == 1) {
            uint256 balanceAfter = balanceBefore - amount;
            uint256 sharesAfter = _balance2shares(
                balanceAfter,
                _rebasingSharePrice
            );
            uint256 sharesBurnt = _rebasingState.nShares - sharesAfter;
            rebasingState[account] = RebasingState({
                isRebasing: 1,
                nShares: uint248(sharesAfter)
            });
            updateTotalRebasingShares(
                _rebasingSharePrice,
                -int256(sharesBurnt)
            );
        }
    }

    /// @notice Override of default ERC20 behavior: exit rebase before movement (if rebasing),
    /// and re-enter rebasing after movement (if rebasing).
    function _mint(address account, uint256 amount) internal virtual override {
        // do ERC20._mint()
        ERC20._mint(account, amount);

        // if `account` is rebasing, update its number of shares
        RebasingState memory _rebasingState = rebasingState[account];
        if (_rebasingState.isRebasing == 1) {
            // compute rebased balance
            uint256 _rebasingSharePrice = rebasingSharePrice();
            uint256 rawBalance = ERC20.balanceOf(account);
            uint256 rebasedBalance = _shares2balance(
                _rebasingState.nShares,
                _rebasingSharePrice,
                amount,
                rawBalance
            );

            // update number of shares
            uint256 sharesAfter = _balance2shares(
                rebasedBalance,
                _rebasingSharePrice
            );
            uint256 sharesReceived = sharesAfter - _rebasingState.nShares;
            rebasingState[account] = RebasingState({
                isRebasing: 1,
                nShares: uint248(sharesAfter)
            });
            updateTotalRebasingShares(
                _rebasingSharePrice,
                int256(sharesReceived)
            );

            // "realize" unminted rebase rewards
            uint256 mintAmount = rebasedBalance - rawBalance;
            if (mintAmount != 0) {
                ERC20._mint(account, mintAmount);
                decreaseUnmintedRebaseRewards(mintAmount);
                emit RebaseReward(account, block.timestamp, mintAmount);
            }
        }
    }

    /// @notice Override of default ERC20 behavior: exit rebase before movement (if rebasing),
    /// and re-enter rebasing after movement (if rebasing).
    function transfer(
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
        // if `from` is rebasing, materialize the tokens from rebase to ensure
        // proper behavior in `ERC20.transfer()`.
        RebasingState memory rebasingStateFrom = rebasingState[msg.sender];
        RebasingState memory rebasingStateTo = rebasingState[to];
        uint256 fromBalanceBefore = ERC20.balanceOf(msg.sender);
        uint256 _rebasingSharePrice = (rebasingStateFrom.isRebasing == 1 ||
            rebasingStateTo.isRebasing == 1)
            ? rebasingSharePrice()
            : 0; // only SLOAD if at least one address is rebasing
        if (rebasingStateFrom.isRebasing == 1) {
            uint256 shares = uint256(rebasingStateFrom.nShares);
            uint256 rebasedBalance = _shares2balance(
                shares,
                _rebasingSharePrice,
                0,
                fromBalanceBefore
            );
            uint256 mintAmount = rebasedBalance - fromBalanceBefore;
            if (mintAmount != 0) {
                ERC20._mint(msg.sender, mintAmount);
                fromBalanceBefore += mintAmount;
                decreaseUnmintedRebaseRewards(mintAmount);
                emit RebaseReward(msg.sender, block.timestamp, mintAmount);
            }
        }

        // do ERC20.transfer()
        bool success = ERC20.transfer(to, amount);

        // if `from` is rebasing, update its number of shares
        int256 sharesDelta;
        if (rebasingStateFrom.isRebasing == 1) {
            uint256 fromBalanceAfter = fromBalanceBefore - amount;
            uint256 fromSharesAfter = _balance2shares(
                fromBalanceAfter,
                _rebasingSharePrice
            );
            uint256 sharesSpent = rebasingStateFrom.nShares - fromSharesAfter;
            sharesDelta -= int256(sharesSpent);
            rebasingState[msg.sender] = RebasingState({
                isRebasing: 1,
                nShares: uint248(fromSharesAfter)
            });
        }

        // if `to` is rebasing, update its number of shares
        if (rebasingStateTo.isRebasing == 1) {
            // compute rebased balance
            uint256 rawToBalanceAfter = ERC20.balanceOf(to);
            uint256 toBalanceAfter = _shares2balance(
                rebasingStateTo.nShares,
                _rebasingSharePrice,
                amount,
                rawToBalanceAfter
            );

            // update number of shares
            uint256 toSharesAfter = _balance2shares(
                toBalanceAfter,
                _rebasingSharePrice
            );
            uint256 sharesReceived = toSharesAfter - rebasingStateTo.nShares;
            sharesDelta += int256(sharesReceived);
            rebasingState[to] = RebasingState({
                isRebasing: 1,
                nShares: uint248(toSharesAfter)
            });

            // "realize" unminted rebase rewards
            uint256 mintAmount = toBalanceAfter - rawToBalanceAfter;
            if (mintAmount != 0) {
                ERC20._mint(to, mintAmount);
                decreaseUnmintedRebaseRewards(mintAmount);
                emit RebaseReward(to, block.timestamp, mintAmount);
            }
        }

        // if `from` or `to` was rebasing, update the total number of shares
        if (
            rebasingStateFrom.isRebasing == 1 || rebasingStateTo.isRebasing == 1
        ) {
            updateTotalRebasingShares(_rebasingSharePrice, sharesDelta);
        }

        return success;
    }

    /// @notice Override of default ERC20 behavior: exit rebase before movement (if rebasing),
    /// and re-enter rebasing after movement (if rebasing).
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
        // if `from` is rebasing, materialize the tokens from rebase to ensure
        // proper behavior in `ERC20.transfer()`.
        RebasingState memory rebasingStateFrom = rebasingState[from];
        RebasingState memory rebasingStateTo = rebasingState[to];
        uint256 fromBalanceBefore = ERC20.balanceOf(from);
        uint256 _rebasingSharePrice = (rebasingStateFrom.isRebasing == 1 ||
            rebasingStateTo.isRebasing == 1)
            ? rebasingSharePrice()
            : 0;
        if (rebasingStateFrom.isRebasing == 1) {
            uint256 shares = uint256(rebasingStateFrom.nShares);
            uint256 rebasedBalance = _shares2balance(
                shares,
                _rebasingSharePrice,
                0,
                fromBalanceBefore
            );
            uint256 mintAmount = rebasedBalance - fromBalanceBefore;
            if (mintAmount != 0) {
                ERC20._mint(from, mintAmount);
                fromBalanceBefore += mintAmount;
                decreaseUnmintedRebaseRewards(mintAmount);
                emit RebaseReward(from, block.timestamp, mintAmount);
            }
        }

        // do ERC20.transferFrom()
        bool success = ERC20.transferFrom(from, to, amount);

        // if `from` is rebasing, update its number of shares
        int256 sharesDelta;
        if (rebasingStateFrom.isRebasing == 1) {
            uint256 fromBalanceAfter = fromBalanceBefore - amount;
            uint256 fromSharesAfter = _balance2shares(
                fromBalanceAfter,
                _rebasingSharePrice
            );
            uint256 sharesSpent = rebasingStateFrom.nShares - fromSharesAfter;
            sharesDelta -= int256(sharesSpent);
            rebasingState[from] = RebasingState({
                isRebasing: 1,
                nShares: uint248(fromSharesAfter)
            });
        }

        // if `to` is rebasing, update its number of shares
        if (rebasingStateTo.isRebasing == 1) {
            // compute rebased balance
            uint256 rawToBalanceAfter = ERC20.balanceOf(to);
            uint256 toBalanceAfter = _shares2balance(
                rebasingStateTo.nShares,
                _rebasingSharePrice,
                amount,
                rawToBalanceAfter
            );

            // update number of shares
            uint256 toSharesAfter = _balance2shares(
                toBalanceAfter,
                _rebasingSharePrice
            );
            uint256 sharesReceived = toSharesAfter - rebasingStateTo.nShares;
            sharesDelta += int256(sharesReceived);
            rebasingState[to] = RebasingState({
                isRebasing: 1,
                nShares: uint248(toSharesAfter)
            });

            // "realize" unminted rebase rewards
            uint256 mintAmount = toBalanceAfter - rawToBalanceAfter;
            if (mintAmount != 0) {
                ERC20._mint(to, mintAmount);
                decreaseUnmintedRebaseRewards(mintAmount);
                emit RebaseReward(to, block.timestamp, mintAmount);
            }
        }

        // if `from` or `to` was rebasing, update the total number of shares
        if (
            rebasingStateFrom.isRebasing == 1 || rebasingStateTo.isRebasing == 1
        ) {
            updateTotalRebasingShares(_rebasingSharePrice, sharesDelta);
        }

        return success;
    }
}
