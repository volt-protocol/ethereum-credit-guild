//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {Core} from "@src/core/Core.sol";
import {Proposal} from "@test/proposals/proposalTypes/Proposal.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {SimplePSM} from "@src/loan/SimplePSM.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {AuctionHouse} from "@src/loan/AuctionHouse.sol";
import {GuildGovernor} from "@src/governance/GuildGovernor.sol";
import {ProfitManager} from "@src/governance/ProfitManager.sol";
import {ERC20MultiVotes} from "@src/tokens/ERC20MultiVotes.sol";
import {GuildVetoGovernor} from "@src/governance/GuildVetoGovernor.sol";
import {RateLimitedMinter} from "@src/rate-limits/RateLimitedMinter.sol";
import {SurplusGuildMinter} from "@src/loan/SurplusGuildMinter.sol";
import {LendingTermFactory} from "@src/governance/LendingTermFactory.sol";
import {LendingTermOnboarding} from "@src/governance/LendingTermOnboarding.sol";
import {GuildTimelockController} from "@src/governance/GuildTimelockController.sol";
import {LendingTermOffboarding} from "@src/governance/LendingTermOffboarding.sol";
import {TestnetToken} from "@src/tokens/TestnetToken.sol";

contract Arbitrum_4b_MarketWETH_Clean is Proposal {
    function name() public view virtual returns (string memory) {
        return "Arbitrum_4b_MarketWETH_Clean";
    }

    constructor() {
        require(
            block.chainid == 42161,
            "Arbitrum_4b_MarketWETH_Clean: wrong chain id"
        );
    }

    function _mkt(
        string memory addressLabel
    ) private pure returns (string memory) {
        return string.concat(Strings.toString(MARKET_ID), addressLabel);
    }

    uint256 internal constant MARKET_ID = 2; // gauge type / market ID

    function deploy() public pure virtual {}

    function afterDeploy(address /* deployer*/) public virtual {
        GuildToken guild = GuildToken(getAddr("ERC20_GUILD"));
        Core core = Core(getAddr("CORE"));

        // revoke roles from smart contracts
        // CREDIT_MINTER
        core.revokeRole(CoreRoles.CREDIT_MINTER, getAddr(_mkt("_RLCM")));
        core.revokeRole(CoreRoles.CREDIT_MINTER, getAddr(_mkt("_PSM")));

        // CREDIT_BURNER
        core.revokeRole(CoreRoles.CREDIT_BURNER, getAddr(_mkt("_PROFIT_MANAGER")));
        core.revokeRole(CoreRoles.CREDIT_BURNER, getAddr(_mkt("_PSM")));

        /// RATE_LIMITED_GUILD_MINTER
        core.revokeRole(CoreRoles.RATE_LIMITED_GUILD_MINTER, getAddr(_mkt("_SGM")));

        // GUILD_SURPLUS_BUFFER_WITHDRAW
        core.revokeRole(CoreRoles.GUILD_SURPLUS_BUFFER_WITHDRAW, getAddr(_mkt("_SGM")));

        // CREDIT_REBASE_PARAMETERS
        core.revokeRole(CoreRoles.CREDIT_REBASE_PARAMETERS, getAddr(_mkt("_PSM")));

        // TIMELOCK_CANCELLER
        core.revokeRole(CoreRoles.TIMELOCK_CANCELLER, getAddr(_mkt("_DAO_VETO_CREDIT")));
        core.revokeRole(CoreRoles.TIMELOCK_CANCELLER, getAddr(_mkt("_ONBOARD_VETO_CREDIT")));

        // For each term:
        // - remove gauge
        // - revoke CREDIT_BURNER role
        // - revoke RATE_LIMITED_CREDIT_MINTER role
        // - revoke GAUGE_PNL_NOTIFIER role
        RecordedAddress[] memory addresses = _read();
        string memory search = string.concat(
            Strings.toString(MARKET_ID),
            "_TERM_"
        );
        for (uint256 i = 0; i < addresses.length; i++) {
            if (_contains(search, addresses[i].name)) {
                guild.removeGauge(addresses[i].addr);
                core.revokeRole(CoreRoles.CREDIT_BURNER, addresses[i].addr);
                core.revokeRole(CoreRoles.RATE_LIMITED_CREDIT_MINTER, addresses[i].addr);
                core.revokeRole(CoreRoles.GAUGE_PNL_NOTIFIER, addresses[i].addr);
            }
        }

        // Configuration
        guild.setCanExceedMaxGauges(
            getAddr(_mkt("_SGM")),
            false
        );
    }

    function run(address deployer) public pure virtual {}

    function teardown(address deployer) public pure virtual {}

    function validate(address deployer) public pure virtual {}
}
