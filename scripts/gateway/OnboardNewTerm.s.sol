// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Script, console} from "@forge-std/Script.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";

contract OnboardNewTerm is Script {
    uint256 public PRIVATE_KEY;

    function _parseEnv() internal {
        // Default behavior: use Anvil 0 private key
        PRIVATE_KEY = vm.envOr(
            "ETH_PRIVATE_KEY",
            77814517325470205911140941194401928579557062014761831930645393041380819009408
        );
    }

    function run() public {
        _parseEnv();
        vm.startBroadcast(PRIVATE_KEY);
        LendingTerm implementation = new LendingTerm();
        address core = 0x5864658b6B6316e5E0643ad77e449960ee128b04;
        address guildToken = 0xcc65D0FeAa7568b70453c26648e8A7bbEF7248B4;
        address newTerm = Clones.clone(address(implementation));
        LendingTerm(newTerm).initialize(
            core,
            LendingTerm.LendingTermReferences({
                profitManager: 0xD8c5748984d27Af2b1FC8235848B16C326e1F6de,
                guildToken: guildToken,
                auctionHouse: 0x723fc745cc58122F6C297a12324fA3245ce920B7,
                creditMinter: 0xc8197E8B9ffE1039761F56C41C6ce9CbC7C2d1D9,
                creditToken: 0x33b79F707C137AD8b70FA27d63847254CF4cF80f
            }),
            LendingTerm.LendingTermParams({
                collateralToken: 0xeeF0AB67262046d5bED00CE9C447e08D92b8dA61,
                maxDebtPerCollateralToken: 1000000000000000000,
                interestRate: 60000000000000000,
                maxDelayBetweenPartialRepay: 0,
                minPartialRepayPercent: 0,
                openingFee: 0,
                hardCap: 2000000000000000000000000
            })
        );

        Core(core).grantRole(CoreRoles.GAUGE_ADD, vm.addr(PRIVATE_KEY));
        GuildToken(guildToken).addGauge(1, newTerm);
        Core(core).grantRole(CoreRoles.RATE_LIMITED_CREDIT_MINTER, newTerm);
        Core(core).grantRole(CoreRoles.GAUGE_PNL_NOTIFIER, newTerm);
        vm.stopBroadcast();
    }
}
