//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

library ProtocolConstants {
    /// @notice initial maximum guild supply is 1b tokens, however this number can change
    /// later if new tokens are minted
    uint256 internal constant GUILD_SUPPLY = 1_000_000_000 * 1e18;

    /// @notice initial credit supply is 100 tokens
    uint256 internal constant CREDIT_SUPPLY = 100 * 1e18;

    /// @notice initial amount of USDC to mint with is 100
    uint256 internal constant INITIAL_USDC_MINT_AMOUNT = 100 * 1e6;

    /// @notice maximum delegates for both credit and guild token
    uint256 internal constant MAX_DELEGATES = 12;

    /// @notice for each USDC collateral, up to 1 credit can be borrowed
    uint256 internal constant MAX_USDC_CREDIT_RATIO = 1e30;

    /// @notice for each SDAI collateral, up to 1 credit can be borrowed
    uint256 internal constant MAX_SDAI_CREDIT_RATIO = 1e18;

    /// @notice credit hardcap at launch
    uint256 internal constant CREDIT_HARDCAP = 20_000 * 1e18;

    /// ------------------------------------------------------------------------
    /// @notice Governance Parameters
    /// ------------------------------------------------------------------------

    /// @notice voting period in the DAO
    uint256 internal constant VOTING_PERIOD = 7000 * 3;

    /// @notice timelock delay for all governance actions
    uint256 internal constant TIMELOCK_DELAY = 3 days;

    /// @notice voting delay for the DAO
    uint256 internal constant VOTING_DELAY = 0;

    /// @notice proposal threshold for proposing governance actions to the DAO
    uint256 internal constant PROPOSAL_THRESHOLD = 2_500_000 * 1e18;

    /// @notice initial quorum for a proposal to pass on the DAO
    uint256 internal constant INITIAL_QUORUM = 10_000_000 * 1e18;

    /// @notice initial quorum for a proposal to be vetoed on the Veto DAO is 25k CREDIT
    uint256 internal constant INITIAL_QUORUM_VETO_DAO = 25_000 * 1e18;

    /// @notice initial quorum for a proposal to be vetoed on the Veto DAO by Credit holders
    uint256 internal constant LENDING_TERM_OFFBOARDING_QUORUM =
        5_000_000 * 1e18;

    /// ------------------------------------------------------------------------
    /// @notice profit sharing configuration parameters for the Profit Manager
    /// ------------------------------------------------------------------------

    /// @notice 10% of profits go to the surplus buffer
    uint256 internal constant SURPLUS_BUFFER_SPLIT = 0.1e18;

    /// @notice 90% of profits go to credit holders that opt into rebasing
    uint256 internal constant CREDIT_SPLIT = 0.9e18;

    /// @notice 0% of profits go to guild holders staked in gauges
    uint256 internal constant GUILD_SPLIT = 0;

    /// @notice 0% of profits go to other
    uint256 internal constant OTHER_SPLIT = 0;
}
