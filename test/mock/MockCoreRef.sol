// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {CoreRef} from "@src/core/CoreRef.sol";

contract MockCoreRef is CoreRef {
    constructor(address core) CoreRef(core) {}
}
