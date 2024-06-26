// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";

contract LendingTermLens {

    address constant public GUILD_TOKEN = 0xb8ae64F191F829fC00A4E923D460a8F2E0ba3978;
    address constant public weETH_TOKEN = 0x35751007a407ca6FEFfE80b3cB397736D2cf4dbe;

    function getTermsForToken(address _tokenAddress) public view returns (address[] memory terms) {
        address[] memory allTerms = GuildToken(GUILD_TOKEN).gauges();
        uint256 termForTokenCounter = 0;
        for(uint256 i = 0; i < allTerms.length; i++) {
            if(LendingTerm(allTerms[i]).collateralToken() == _tokenAddress) {
                termForTokenCounter++;
            }
        }

        terms = new address[](termForTokenCounter);
        uint256 cursor = 0;
        for(uint256 i = 0; i < allTerms.length; i++) {
            if(LendingTerm(allTerms[i]).collateralToken() == _tokenAddress) {
                terms[cursor++] = allTerms[i];
            }
        }
    }

    function getEtherfiTerms() public view returns (address[] memory terms) {
        return getTermsForToken(weETH_TOKEN);
    }
}
