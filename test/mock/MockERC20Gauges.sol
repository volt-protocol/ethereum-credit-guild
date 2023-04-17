// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {ERC20Gauges} from "@src/tokens/ERC20Gauges.sol";

contract MockERC20Gauges is ERC20Gauges, MockERC20 {
    constructor(
        uint32 _cycleLength,
        uint32 _freezeWindow
    ) ERC20Gauges(_cycleLength, _freezeWindow) {}

    /// ------------------------------------------------------------------------
    /// Open access to internal functions.
    /// ------------------------------------------------------------------------

    function addGauge(address gauge) external returns (uint112) {
        return _addGauge(gauge);
    }

    function removeGauge(address gauge) external {
        _removeGauge(gauge);
    }

    function setMaxGauges(uint256 max) external {
        _setMaxGauges(max);
    }

    function setCanExceedMaxGauges(address who, bool can) external {
        _setCanExceedMaxGauges(who, can);
    }

    /// ------------------------------------------------------------------------
    /// Overrides required by Solidity.
    /// ------------------------------------------------------------------------

    function _burn(
        address from,
        uint256 amount
    ) internal override(ERC20, ERC20Gauges) {
        return super._burn(from, amount);
    }

    function transfer(
        address to,
        uint256 amount
    ) public override(ERC20, ERC20Gauges) returns (bool) {
        return super.transfer(to, amount);
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override(ERC20, ERC20Gauges) returns (bool) {
        return super.transferFrom(from, to, amount);
    }
}
