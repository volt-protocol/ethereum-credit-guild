// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {AddressLib} from "@test/proposals/AddressLib.sol";
import {PostProposalCheck} from "@test/integration/PostProposalCheck.sol";

contract IntegrationTestRoles is PostProposalCheck {

    bytes32[] roleHashes;
    mapping(bytes32=>string) roleHashToLabel;
    mapping(bytes32=>uint256) roleMemberCount;
    mapping(bytes32=>mapping(uint256=>address)) roleMember;

    struct CoreRole {
        string name;
        string role;
    }

    function testMainnetRoles() public {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/protocol-configuration/roles.json");
        string memory json = vm.readFile(path);

        string[] memory roles = vm.parseJsonKeys(json, "$");

        assertEq(roles.length, 17, "incorrect role count");
        
        for (uint256 i = 0; i < roles.length; i++) {
            Core core = Core(AddressLib.get("CORE"));
            bytes32 role = keccak256(bytes(string.concat(roles[i], "_ROLE")));
            
            assertEq(
                core.getRoleAdmin(role),
                CoreRoles.GOVERNOR,
                string.concat("Wrong admin for role ", roles[i], ", expected GOVERNOR")
            );

            bytes memory parsedJson = vm.parseJson(json, string.concat(".", roles[i]));
            string[] memory addressNames = abi.decode(parsedJson, (string[]));

            assertEq(
                core.getRoleMemberCount(role),
                addressNames.length,
                string.concat("Expected role ", roles[i], " to have ", Strings.toString(addressNames.length), " members")
            );

            for (uint256 j = 0; j < addressNames.length; j++) {
                assertEq(
                    core.hasRole(role, AddressLib.get(addressNames[j])),
                    true,
                    string.concat("Expected ", addressNames[j], " to have role ", roles[i])
                );
            }
        }
    }
}
