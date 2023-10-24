// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

/// @notice library that contains the names of ECG System Contracts
library NameLib {
    /// @notice core contract, manages all roles
    string internal constant CORE = "CORE";

    /// @notice system timelock
    string internal constant TIMELOCK = "TIMELOCK";

    /// @notice first lending term for SDAI
    string internal constant TERM_SDAI_1 = "TERM_SDAI_1";

    /// @notice rate limited guild minter
    string internal constant SURPLUS_GUILD_MINTER = "SURPLUS_GUILD_MINTER";

    /// @notice rate limited credit minter
    string internal constant RATE_LIMITED_CREDIT_MINTER = "RATE_LIMITED_CREDIT_MINTER";

    /// @notice rate limited guild minter
    string internal constant RATE_LIMITED_GUILD_MINTER = "RATE_LIMITED_GUILD_MINTER";

    /// @notice Volt Governor DAO, governed by GUILD token
    string internal constant GOVERNOR = "GOVERNOR";

    /// @notice Volt Governor Veto DAO, governed by CREDIT token
    string internal constant VETO_GOVERNOR = "VETO_GOVERNOR";

    /// @notice reference to the credit stablecoin token
    string internal constant CREDIT_TOKEN = "CREDIT_TOKEN";

    /// @notice reference to the guild governance token
    string internal constant GUILD_TOKEN = "GUILD_TOKEN";

    /// @notice lending term contract
    string internal constant LENDING_TERM = "LENDING_TERM";

    /// @notice lending term onboarding contract
    string internal constant LENDING_TERM_ONBOARDING = "LENDING_TERM_ONBOARDING";

    /// @notice lending term offboarding contract, able to remove lending terms instantly with quorum
    string internal constant LENDING_TERM_OFFBOARDING = "LENDING_TERM_OFFBOARDING";

    /// @notice system accounting contract that sets the price of CREDIT
    string internal constant PROFIT_MANAGER = "PROFIT_MANAGER";

    /// @notice auction contract that sells collateral when a loan is called and not repaid
    string internal constant AUCTION_HOUSE = "AUCTION_HOUSE";

    /// @notice auction contract that sells collateral when a loan is called and not repaid
    string internal constant PSM_USDC = "PSM_USDC";

    /// @notice reference to mainnet USDC
    string internal constant ERC20_USDC = "ERC20_USDC";

    /// @notice reference to mainnet SDAI
    string internal constant ERC20_SDAI = "ERC20_SDAI";

    /// @notice team multisig
    string internal constant TEAM_MULTISIG = "TEAM_MULTISIG";
}
