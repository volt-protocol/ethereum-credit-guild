// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/** 
@title  An ERC20 with an embedded "Gauge" style vote with liquid weights
@author joeysantoro, eswak
@notice This contract is meant to be used to support gauge style votes with weights associated with resource allocation.
        Holders can allocate weight in any proportion to supported gauges.
        A "gauge" is represented by an address which would receive the resources periodically or continuously.
        For example, gauges can be used to direct token emissions, similar to Curve or Tokemak.
        Alternatively, gauges can be used to direct another quantity such as relative access to a line of credit.
        This contract is abstract, and a parent shall implement public setter with adequate access control to manage
        the gauge set and caps.
        All gauges are in the set `_gauges` (live + deprecated).  
        Users can only add weight to live gauges but can remove weight from live or deprecated gauges.
        Gauges can be deprecated and reinstated, and will maintain any non-removed weight from before.
@dev    SECURITY NOTES: `maxGauges` is a critical variable to protect against gas DOS attacks upon token transfer. 
        This must be low enough to allow complicated transactions to fit in a block.
        Weight state is preserved on the gauge and user level even when a gauge is removed, in case it is re-added. 
        This maintains state efficiently, and global accounting is managed only on the `_totalWeight`
@dev This contract was originally published as part of TribeDAO's flywheel-v2 repo, please see:
    https://github.com/fei-protocol/flywheel-v2/blob/main/src/token/ERC20Gauges.sol
    The original version was included in 2 audits :
    - https://code4rena.com/reports/2022-04-xtribe/
    - https://consensys.net/diligence/audits/2022/04/tribe-dao-flywheel-v2-xtribe-xerc4626/
    ECG made the following changes to the original flywheel-v2 version :
    - Does not inherit Solmate's Auth (all requiresAuth functions are now internal, see below)
        -> This contract is abstract, and permissioned public functions can be added in parent.
        -> permissioned public functions to add in parent:
            - function addGauge(address) external returns (uint112)
            - function removeGauge(address) external
            - function setMaxGauges(uint256) external
            - function setCanExceedMaxGauges(address, bool) external
    - Remove public addGauge(address) requiresAuth method 
    - Remove public removeGauge(address) requiresAuth method
    - Remove public replaceGauge(address, address) requiresAuth method
    - Remove public setMaxGauges(uint256) requiresAuth method
        ... Add internal _setMaxGauges(uint256) method
    - Remove public setContractExceedMaxGauges(address, bool) requiresAuth method
        ... Add internal _setCanExceedMaxGauges(address, bool) method
        ... Remove check of "target address has nonzero code size"
        ... Rename to remove "contract" from name because we don't check if target is a contract
    - Rename `calculateGaugeAllocation` to `calculateGaugeStoredAllocation` to make clear that it reads from stored weights.
    - Add `calculateGaugeAllocation` helper function that reads from current weight.
    - Add `isDeprecatedGauge(address)->bool` view function that returns true if gauge is deprecated.
    - Consistency: make incrementGauges return a uint112 instead of uint256
    - Import OpenZeppelin ERC20 & EnumerableSet instead of Solmate's
    - Update error management style (use require + messages instead of Solidity errors)
    - Implement C4 audit fixes for [M-03], [M-04], [M-07], [G-02], and [G-04].
    - Remove cycle-based logic
    - Add gauge types
    - Prevent removal of gauges if they were not previously added
    - Add liveGauges() and numLiveGauges() getters
*/
abstract contract ERC20Gauges is ERC20 {
    using EnumerableSet for EnumerableSet.AddressSet;

    /*///////////////////////////////////////////////////////////////
                        GAUGE STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice a mapping from users to gauges to a user's allocated weight to that gauge
    mapping(address => mapping(address => uint256)) public getUserGaugeWeight;

    /// @notice a mapping from a user to their total allocated weight across all gauges
    /// @dev NOTE this may contain weights for deprecated gauges
    mapping(address => uint256) public getUserWeight;

    /// @notice a mapping from a gauge to the total weight allocated to it
    /// @dev NOTE this may contain weights for deprecated gauges
    mapping(address => uint256) public getGaugeWeight;

    /// @notice the total global allocated weight ONLY of live gauges
    uint256 public totalWeight;

    /// @notice the total allocated weight to gauges of a given type, ONLY of live gauges.
    /// keys : totalTypeWeight[type] = total.
    mapping(uint256 => uint256) public totalTypeWeight;

    /// @notice the type of gauges.
    mapping(address => uint256) public gaugeType;

    mapping(address => EnumerableSet.AddressSet) internal _userGauges;

    EnumerableSet.AddressSet internal _gauges;

    // Store deprecated gauges in case a user needs to free dead weight
    EnumerableSet.AddressSet internal _deprecatedGauges;

    /*///////////////////////////////////////////////////////////////
                            VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice returns the set of live + deprecated gauges
    function gauges() external view returns (address[] memory) {
        return _gauges.values();
    }

    /// @notice returns true if `gauge` is not in deprecated gauges
    function isGauge(address gauge) public view returns (bool) {
        return _gauges.contains(gauge) && !_deprecatedGauges.contains(gauge);
    }

    /// @notice returns true if `gauge` is in deprecated gauges
    function isDeprecatedGauge(address gauge) public view returns (bool) {
        return _deprecatedGauges.contains(gauge);
    }

    /// @notice returns the number of live + deprecated gauges
    function numGauges() external view returns (uint256) {
        return _gauges.length();
    }

    /// @notice returns the set of previously live but now deprecated gauges
    function deprecatedGauges() external view returns (address[] memory) {
        return _deprecatedGauges.values();
    }

    /// @notice returns the number of deprecated gauges
    function numDeprecatedGauges() external view returns (uint256) {
        return _deprecatedGauges.length();
    }

    /// @notice returns the set of currently live gauges
    function liveGauges() external view returns (address[] memory _liveGauges) {
        _liveGauges = new address[](
            _gauges.length() - _deprecatedGauges.length()
        );
        address[] memory allGauges = _gauges.values();
        uint256 j;
        for (uint256 i; i < allGauges.length && j < _liveGauges.length; ) {
            if (!_deprecatedGauges.contains(allGauges[i])) {
                _liveGauges[j] = allGauges[i];
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
        return _liveGauges;
    }

    /// @notice returns the number of currently live gauges
    function numLiveGauges() external view returns (uint256) {
        return _gauges.length() - _deprecatedGauges.length();
    }

    /// @notice returns the set of gauges the user has allocated to, may be live or deprecated.
    function userGauges(address user) external view returns (address[] memory) {
        return _userGauges[user].values();
    }

    /// @notice returns true if `gauge` is in user gauges
    function isUserGauge(
        address user,
        address gauge
    ) external view returns (bool) {
        return _userGauges[user].contains(gauge);
    }

    /// @notice returns the number of user gauges
    function numUserGauges(address user) external view returns (uint256) {
        return _userGauges[user].length();
    }

    /// @notice helper function exposing the amount of weight available to allocate for a user
    function userUnusedWeight(address user) external view returns (uint256) {
        return balanceOf(user) - getUserWeight[user];
    }

    /** 
    @notice helper function for calculating the proportion of a `quantity` allocated to a gauge
    @param gauge the gauge to calculate allocation of
    @param quantity a representation of a resource to be shared among all gauges
    @return the proportion of `quantity` allocated to `gauge`. Returns 0 if gauge is not live, even if it has weight.
    */
    function calculateGaugeAllocation(
        address gauge,
        uint256 quantity
    ) external view returns (uint256) {
        if (_deprecatedGauges.contains(gauge)) return 0;

        uint256 total = totalTypeWeight[gaugeType[gauge]];
        if (total == 0) return 0;
        uint256 weight = getGaugeWeight[gauge];

        return (quantity * weight) / total;
    }

    /*///////////////////////////////////////////////////////////////
                        USER GAUGE OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice emitted when incrementing a gauge
    event IncrementGaugeWeight(
        address indexed user,
        address indexed gauge,
        uint256 weight
    );

    /// @notice emitted when decrementing a gauge
    event DecrementGaugeWeight(
        address indexed user,
        address indexed gauge,
        uint256 weight
    );

    /** 
    @notice increment a gauge with some weight for the caller
    @param gauge the gauge to increment
    @param weight the amount of weight to increment on gauge
    @return newUserWeight the new user weight
    */
    function incrementGauge(
        address gauge,
        uint256 weight
    ) public virtual returns (uint256 newUserWeight) {
        require(isGauge(gauge), "ERC20Gauges: invalid gauge");
        _incrementGaugeWeight(msg.sender, gauge, weight);
        return _incrementUserAndGlobalWeights(msg.sender, weight);
    }

    /// @dev this function does not check if the gauge exists, this is performed
    /// in the calling function.
    function _incrementGaugeWeight(
        address user,
        address gauge,
        uint256 weight
    ) internal virtual {
        bool added = _userGauges[user].add(gauge); // idempotent add
        if (added && _userGauges[user].length() > maxGauges) {
            require(canExceedMaxGauges[user], "ERC20Gauges: exceed max gauges");
        }

        getUserGaugeWeight[user][gauge] += weight;

        getGaugeWeight[gauge] += weight;

        totalTypeWeight[gaugeType[gauge]] += weight;

        emit IncrementGaugeWeight(user, gauge, weight);
    }

    function _incrementUserAndGlobalWeights(
        address user,
        uint256 weight
    ) internal returns (uint256 newUserWeight) {
        newUserWeight = getUserWeight[user] + weight;
        // Ensure under weight
        require(newUserWeight <= balanceOf(user), "ERC20Gauges: overweight");

        // Update gauge state
        getUserWeight[user] = newUserWeight;

        totalWeight += weight;
    }

    /** 
    @notice increment a list of gauges with some weights for the caller
    @param gaugeList the gauges to increment
    @param weights the weights to increment by
    @return newUserWeight the new user weight
    */
    function incrementGauges(
        address[] calldata gaugeList,
        uint256[] calldata weights
    ) public virtual returns (uint256 newUserWeight) {
        uint256 size = gaugeList.length;
        require(weights.length == size, "ERC20Gauges: size mismatch");

        // store total in summary for batch update on user/global state
        uint256 weightsSum;

        // Update gauge specific state
        for (uint256 i = 0; i < size; ) {
            address gauge = gaugeList[i];
            uint256 weight = weights[i];
            weightsSum += weight;

            require(isGauge(gauge), "ERC20Gauges: invalid gauge");

            _incrementGaugeWeight(msg.sender, gauge, weight);
            unchecked {
                ++i;
            }
        }
        return _incrementUserAndGlobalWeights(msg.sender, weightsSum);
    }

    /** 
     @notice decrement a gauge with some weight for the caller
     @param gauge the gauge to decrement
     @param weight the amount of weight to decrement on gauge
     @return newUserWeight the new user weight
    */
    function decrementGauge(
        address gauge,
        uint256 weight
    ) public virtual returns (uint256 newUserWeight) {
        // All operations will revert on underflow, protecting against bad inputs
        _decrementGaugeWeight(msg.sender, gauge, weight);
        if (!_deprecatedGauges.contains(gauge)) {
            totalTypeWeight[gaugeType[gauge]] -= weight;
            totalWeight -= weight;
        }
        return getUserWeight[msg.sender];
    }

    function _decrementGaugeWeight(
        address user,
        address gauge,
        uint256 weight
    ) internal virtual {
        uint256 oldWeight = getUserGaugeWeight[user][gauge];

        getUserGaugeWeight[user][gauge] = oldWeight - weight;
        if (oldWeight == weight) {
            // If removing all weight, remove gauge from user list.
            require(_userGauges[user].remove(gauge));
        }

        getGaugeWeight[gauge] -= weight;

        getUserWeight[user] -= weight;

        emit DecrementGaugeWeight(user, gauge, weight);
    }

    /** 
     @notice decrement a list of gauges with some weights for the caller
     @param gaugeList the gauges to decrement
     @param weights the list of weights to decrement on the gauges
     @return newUserWeight the new user weight
    */
    function decrementGauges(
        address[] calldata gaugeList,
        uint256[] calldata weights
    ) public virtual returns (uint256 newUserWeight) {
        uint256 size = gaugeList.length;
        require(weights.length == size, "ERC20Gauges: size mismatch");

        // store total in summary for batch update on user/global state
        uint256 weightsSum;

        // Update gauge specific state
        // All operations will revert on underflow, protecting against bad inputs
        for (uint256 i = 0; i < size; ) {
            address gauge = gaugeList[i];
            uint256 weight = weights[i];

            _decrementGaugeWeight(msg.sender, gauge, weight);
            if (!_deprecatedGauges.contains(gauge)) {
                totalTypeWeight[gaugeType[gauge]] -= weight;
                weightsSum += weight;
            }
            unchecked {
                ++i;
            }
        }
        totalWeight -= weightsSum;
        return getUserWeight[msg.sender];
    }

    /*///////////////////////////////////////////////////////////////
                        ADMIN GAUGE OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice emitted when adding a new gauge to the live set.
    event AddGauge(address indexed gauge, uint256 indexed gaugeType);

    /// @notice emitted when removing a gauge from the live set.
    event RemoveGauge(address indexed gauge);

    /// @notice emitted when updating the max number of gauges a user can delegate to.
    event MaxGaugesUpdate(uint256 oldMaxGauges, uint256 newMaxGauges);

    /// @notice emitted when changing a contract's approval to go over the max gauges.
    event CanExceedMaxGaugesUpdate(
        address indexed account,
        bool canExceedMaxGauges
    );

    /// @notice the default maximum amount of gauges a user can allocate to.
    /// @dev if this number is ever lowered, or a contract has an override, then existing addresses MAY have more gauges allocated to. Use `numUserGauges` to check this.
    uint256 public maxGauges;

    /// @notice an approve list for contracts to go above the max gauge limit.
    mapping(address => bool) public canExceedMaxGauges;

    function _addGauge(
        uint256 _type,
        address gauge
    ) internal returns (uint256 weight) {
        bool newAdd = _gauges.add(gauge);
        bool previouslyDeprecated = _deprecatedGauges.remove(gauge);
        // add and fail loud if zero address or already present and not deprecated
        require(
            gauge != address(0) && (newAdd || previouslyDeprecated),
            "ERC20Gauges: invalid gauge"
        );

        if (newAdd) {
            // save gauge type on first add
            gaugeType[gauge] = _type;
        } else {
            // cannot change gauge type on re-add of a previously deprecated gauge
            require(gaugeType[gauge] == _type, "ERC20Gauges: invalid type");
        }

        // Check if some previous weight exists and re-add to total. Gauge and user weights are preserved.
        weight = getGaugeWeight[gauge];
        if (weight != 0) {
            totalTypeWeight[_type] += weight;
            totalWeight += weight;
        }

        emit AddGauge(gauge, _type);
    }

    function _removeGauge(address gauge) internal {
        // add to deprecated and fail loud if not present
        require(
            _gauges.contains(gauge) && _deprecatedGauges.add(gauge),
            "ERC20Gauges: invalid gauge"
        );

        // Remove weight from total but keep the gauge and user weights in storage in case gauge is re-added.
        uint256 weight = getGaugeWeight[gauge];
        if (weight != 0) {
            totalTypeWeight[gaugeType[gauge]] -= weight;
            totalWeight -= weight;
        }

        emit RemoveGauge(gauge);
    }

    /// @notice set the new max gauges. Requires auth by `authority`.
    /// @dev if this is set to a lower number than the current max, users MAY have more gauges active than the max. Use `numUserGauges` to check this.
    function _setMaxGauges(uint256 newMax) internal {
        uint256 oldMax = maxGauges;
        maxGauges = newMax;

        emit MaxGaugesUpdate(oldMax, newMax);
    }

    /// @notice set the canExceedMaxGauges flag for an account.
    function _setCanExceedMaxGauges(
        address account,
        bool canExceedMax
    ) internal {
        if (canExceedMax) {
            require(
                account.code.length != 0,
                "ERC20Gauges: not a smart contract"
            );
        }

        canExceedMaxGauges[account] = canExceedMax;

        emit CanExceedMaxGaugesUpdate(account, canExceedMax);
    }

    /*///////////////////////////////////////////////////////////////
                            ERC20 LOGIC
    //////////////////////////////////////////////////////////////*/

    /// NOTE: any "removal" of tokens from a user requires userUnusedWeight < amount.
    /// _decrementWeightUntilFree is called as a greedy algorithm to free up weight.
    /// It may be more gas efficient to free weight before burning or transferring tokens.

    function _burn(address from, uint256 amount) internal virtual override {
        _decrementWeightUntilFree(from, amount);
        super._burn(from, amount);
    }

    function transfer(
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
        _decrementWeightUntilFree(msg.sender, amount);
        return super.transfer(to, amount);
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
        _decrementWeightUntilFree(from, amount);
        return super.transferFrom(from, to, amount);
    }

    /// a greedy algorithm for freeing weight before a token burn/transfer
    /// frees up entire gauges, so likely will free more than `weight`
    function _decrementWeightUntilFree(address user, uint256 weight) internal {
        uint256 userFreeWeight = balanceOf(user) - getUserWeight[user];

        // early return if already free
        if (userFreeWeight >= weight) return;

        // cache totals for batch updates
        uint256 userFreed;
        uint256 totalFreed;

        // Loop through all user gauges, live and deprecated
        address[] memory gaugeList = _userGauges[user].values();

        // Free gauges until through entire list or under weight
        uint256 size = gaugeList.length;
        for (
            uint256 i = 0;
            i < size && (userFreeWeight + userFreed) < weight;

        ) {
            address gauge = gaugeList[i];
            uint256 userGaugeWeight = getUserGaugeWeight[user][gauge];
            if (userGaugeWeight != 0) {
                userFreed += userGaugeWeight;
                _decrementGaugeWeight(user, gauge, userGaugeWeight);

                // If the gauge is live (not deprecated), include its weight in the total to remove
                if (!_deprecatedGauges.contains(gauge)) {
                    totalTypeWeight[gaugeType[gauge]] -= userGaugeWeight;
                    totalFreed += userGaugeWeight;
                }

                unchecked {
                    ++i;
                }
            }
        }

        totalWeight -= totalFreed;
    }
}
