// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {LendingTerm} from "@src/loan/LendingTerm.sol";

interface IUSDC {
    function blacklist(address) external;
    function unBlacklist(address) external;
    function blacklister() external view returns (address);
    function isBlacklisted(address) external view returns (bool);
}

/// @notice Lending Term for USDC collateral, can automatically forgive loans if
/// the lending term or its linked auction house are blacklisted for USDC Movements.
contract LendingTermUSDC is LendingTerm {

    /// @notice Ethereum mainnet USDC token address (proxy)
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    constructor(
        address _core,
        address _guildToken,
        address _auctionHouse,
        address _creditMinter,
        address _creditToken,
        LendingTerm.LendingTermParams memory params
    ) LendingTerm(
        _core,
        _guildToken,
        _auctionHouse,
        _creditMinter,
        _creditToken,
        params
    ) {
        require(params.collateralToken == USDC, "LendingTermUSDC: invalid collateralToken");
    }

    /// @notice loan forgiveness if blacklisted by Circle
    function canAutomaticallyForgive() public override view returns (bool) {
        return IUSDC(USDC).isBlacklisted(address(this)) || IUSDC(USDC).isBlacklisted(address(auctionHouse));
    }
}
