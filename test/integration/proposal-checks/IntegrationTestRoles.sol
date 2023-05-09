// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {PostProposalCheck} from "@test/integration/proposal-checks/PostProposalCheck.sol";

import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";

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
        string memory path = string.concat(root, "/protocol-configuration/roles.mainnet.json");
        string memory json = vm.readFile(path);
        bytes memory parsedJson = vm.parseJson(json);
        CoreRole[] memory roles = abi.decode(parsedJson, (CoreRole[]));

        Core core = Core(addresses.mainnet("CORE"));
        for (uint256 i = 0; i < roles.length; i++) {
            address addr = addresses.mainnet(roles[i].name);
            bytes32 role = keccak256(bytes(roles[i].role));
            
            assertEq(
                core.getRoleAdmin(role),
                CoreRoles.GOVERNOR,
                string.concat("Wrong admin for role ", roles[i].role, ", expected GOVERNOR")
            );
            assertEq(
                core.hasRole(role, addr),
                true,
                string.concat("Expected ", roles[i].name, " to have role ", roles[i].role)
            );

            roleHashes.push(role);
            roleMember[role][roleMemberCount[role]++] = addr;
            roleHashToLabel[role] = roles[i].role;
        }

        for (uint256 i = 0; i < roleHashes.length; i++) {
            bytes32 roleHash = roleHashes[i];
            assertEq(
                core.getRoleMemberCount(roleHash),
                roleMemberCount[roleHash],
                string.concat("Expected role ", roleHashToLabel[roleHash], " to have ", Strings.toString(roleMemberCount[roleHash]), " members")
            );
            for (uint256 j = 0; j < roleMemberCount[roleHash]; j++) {
                assertEq(
                    core.getRoleMember(roleHash, j),
                    roleMember[roleHash][j],
                    string.concat("Expected role ", roleHashToLabel[roleHash], " member ", Strings.toString(j), " to be ", addresses.mainnetLabel(roleMember[roleHash][j]))
                );
            }
        }
    }
}
