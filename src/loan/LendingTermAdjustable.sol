// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {CoreRoles} from "@src/core/CoreRoles.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";

/// @notice Lending Term contract whose parameters can be changed :
/// - interestRate 
/// - maxDebtPerCollateralToken
/// Note that interest rate is compounding between each new borrows
/// and interest rate updates.
contract LendingTermAdjustable is LendingTerm {
    
    /// @notice emitted when maxDebtPerCollateralToken is updated
    event SetMaxDebtPerCollateralToken(uint256 indexed when, uint256 value);
    /// @notice emitted when interestRate is updated
    event SetInterestRate(uint256 indexed when, uint256 value);

    struct InterestIndex {
        uint48 lastUpdate;
        uint208 lastValue;
    }
    /// @notice internal interest index
    InterestIndex internal __interestIndex = InterestIndex({
        lastUpdate: uint48(block.timestamp),
        lastValue: uint208(1e18)
    });

    /// @notice loan's interest rate index on open
    mapping(bytes32 => uint256) internal loanOpenInterestIndex;

    /// @notice returns the current interest index
    function _getCurrentInterestIndex() internal view returns (uint256) {
        InterestIndex memory _interestIndex = __interestIndex;
        uint256 elapsed = block.timestamp - _interestIndex.lastUpdate;
        uint256 increment = (_interestIndex.lastValue *
            params.interestRate *
            (elapsed)) /
            YEAR /
            1e18;
        return _interestIndex.lastValue + increment;
    }

    /// @notice checkpoints the interest index.
    /// Should be called every time there is an interest rate change.
    function _checkpointInterestIndex() internal returns (uint256) {
        uint256 idx = _getCurrentInterestIndex();
        if (idx == 0) {
            // for first-ever checkpoint, set value to 1e18
            idx = 1e18;
        }
        __interestIndex = InterestIndex({
            lastUpdate: uint48(block.timestamp),
            lastValue: uint208(idx)
        });
        return idx;
    }

    // override to checkpoint interestIndex & emit additional events
    function initialize(
        address _core,
        LendingTermReferences calldata _refs,
        bytes calldata _params
    ) public override {
        super.initialize(_core, _refs, _params);
        _checkpointInterestIndex();
        emit SetMaxDebtPerCollateralToken(block.timestamp, params.maxDebtPerCollateralToken);
        emit SetInterestRate(block.timestamp, params.interestRate);
    }

    // override to save interestIndex at time of loan open
    function _borrow(
        address payer,
        address borrower,
        uint256 borrowAmount,
        uint256 collateralAmount
    ) internal override returns (bytes32) {
        bytes32 loanId = super._borrow(payer, borrower, borrowAmount, collateralAmount);
        loanOpenInterestIndex[loanId] = _checkpointInterestIndex();
        return loanId;
    }

    // override to use interestIndex instead of time since opening + interestRate
    // when computing the interest owed by an open loan.
    function _getLoanDebt(
        bytes32 loanId,
        uint256 creditMultiplier
    ) internal override view returns (uint256) {
        Loan storage loan = loans[loanId];
        uint256 borrowTime = loan.borrowTime;

        if (borrowTime == 0) {
            return 0;
        }

        if (loan.closeTime != 0) {
            return 0;
        }

        if (loan.callTime != 0) {
            return loan.callDebt;
        }

        // compute interest owed
        uint256 borrowAmount = loan.borrowAmount;
        uint256 loanDebt = (_getCurrentInterestIndex() * borrowAmount) / loanOpenInterestIndex[loanId];
        uint256 _openingFee = params.openingFee;
        if (_openingFee != 0) {
            loanDebt += (borrowAmount * _openingFee) / 1e18;
        }
        loanDebt = (loanDebt * loan.borrowCreditMultiplier) / creditMultiplier;

        return loanDebt;
    }

    /// @notice set the maxDebtPerCollateralToken.
    /// lowering this value might make some open loans callable.
    function setMaxDebtPerCollateralToken(
        uint256 _newValue
    ) external onlyCoreRole(CoreRoles.GOVERNOR) {
        params.maxDebtPerCollateralToken = _newValue;
        emit SetMaxDebtPerCollateralToken(block.timestamp, _newValue);
    }

    /// @notice set the interestRate.
    /// checkpointing should only apply the new interest rate on loans
    /// starting from now, and not retroactively apply to open loans since
    /// they have been opened.
    function setInterestRate(
        uint256 _newValue
    ) external onlyCoreRole(CoreRoles.GOVERNOR) {
        _checkpointInterestIndex();
        params.interestRate = _newValue;
        emit SetInterestRate(block.timestamp, _newValue);
    }
}
