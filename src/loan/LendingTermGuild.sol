// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {GuildToken} from "@src/tokens/GuildToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";

/// @notice Lending Term that allows minting of GUILD tokens.
contract LendingTermGuild is LendingTerm {

    constructor(
        address _core,
        address _guildToken,
        address _collateralToken,
        uint256 _guildPerCollateralToken
    ) LendingTerm(
        _core,
        _guildToken,
        address(0), //_auctionHouse,
        address(0), //_creditMinter,
        address(0), //_creditToken,
        LendingTerm.LendingTermParams({
            collateralToken: _collateralToken,
            maxDebtPerCollateralToken: _guildPerCollateralToken,
            interestRate: 0,
            callFee: 0,
            callPeriod: 0,
            hardCap: type(uint256).max,
            ltvBuffer: 0
        })
    ) {}

    /// @notice noop on pnl reports
    function _notifyPnL(int256 pnl) internal override {}

    /// @notice noop on debt ceiling check during borrow
    function _borrow_checkDebtCeiling(uint256 borrowAmount, uint256 postBorrowIssuance) internal view override {}

    /// @notice on borrow, mint GUILD as if it were the debt token
    function _borrow_mintDebt(address account, uint256 amount) internal override {
        GuildToken(guildToken).mint(account, amount);
    }

    /// @notice on repay, burn GUILD as if it were the debt token
    function _repay_pullAndBurnDebt(address pullFrom, uint256/* pullAmount*/, uint256 debtAmount, int256/* pnl*/) internal override {
        GuildToken(guildToken).burnFrom(pullFrom, debtAmount);
    }

    /// @notice noop on loan call, disable the loan calling
    function _call(bytes32 loanId) internal override returns (uint256 debtToPull) {}
}
