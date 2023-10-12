// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

/// @notice library that contains the names of ECG System Contracts
library NameLib {
    /// @notice core contract, manages all roles
    string internal constant core = "CORE";

    /// @notice system timelock
    string internal constant timelock = "TIMELOCK";

    /// @notice first lending term for USDC
    string internal constant termUsdc = "TERM_USDC_1";

    /// @notice first lending term for SDAI
    string internal constant termSdai = "TERM_SDAI_1";

    /// @notice rate limited guild minter
    string internal constant guildMinter = "SURPLUS_GUILD_MINTER";

    /// @notice rate limited credit minter
    string internal constant rlcm = "RATE_LIMITED_CREDIT_MINTER";

    /// @notice rate limited guild minter
    string internal constant rlgm = "RATE_LIMITED_GUILD_MINTER";

    /// @notice Volt Governor DAO, governed by GUILD token
    string internal constant governor = "GOVERNOR";

    /// @notice Volt Governor Veto DAO, governed by CREDIT token
    string internal constant vetoGovernor = "VETO_GOVERNOR";

    /// @notice reference to the credit stablecoin token
    string internal constant creditToken = "CREDIT_TOKEN";

    /// @notice reference to the guild governance token
    string internal constant guildToken = "GUILD_TOKEN";

    /// @notice lending term contract
    string internal constant lendingTerm = "LENDING_TERM";

    /// @notice lending term onboarding contract
    string internal constant lendingTermOnboarding = "LENDING_TERM_ONBOARDING";

    /// @notice lending term offboarding contract, able to remove lending terms instantly with quorum
    string internal constant lendingTermOffboarding =
        "LENDING_TERM_OFFBOARDING";

    /// @notice system accounting contract that sets the price of CREDIT
    string internal constant profitManager = "PROFIT_MANAGER";

    /// @notice auction contract that sells collateral when a loan is called and not repaid
    string internal constant auctionHouse = "AUCTION_HOUSE";
}
