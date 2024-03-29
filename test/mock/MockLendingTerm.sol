// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {CoreRef} from "@src/core/CoreRef.sol";

contract MockLendingTerm is CoreRef {
    uint256 public issuance;
    address public profitManager;
    address public creditToken;

    constructor(
        address core,
        address _profitManager,
        address _creditToken
    ) CoreRef(core) {
        profitManager = _profitManager;
        creditToken = _creditToken;
    }
}
