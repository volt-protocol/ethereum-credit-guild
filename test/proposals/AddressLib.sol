// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {console, Vm} from "@test/forge-std/src/Components.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

library AddressLib {

    string internal constant ADDR_PATH = "/protocol-configuration/addresses.json";

    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct RecordedAddress {
        address addr;
        string name;
    }

    function _read() internal view returns (RecordedAddress[] memory addresses) {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, ADDR_PATH);
        string memory json = vm.readFile(path);
        bytes memory parsedJson = vm.parseJson(json);
        addresses = abi.decode(parsedJson, (RecordedAddress[]));
    }

    function _write(RecordedAddress[] memory addresses) internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, ADDR_PATH);

        string memory json = '[';
        for (uint256 i = 0; i < addresses.length; i++) {
            json = string.concat(json, '{');
            json = string.concat(json, '"addr":');
            json = string.concat(json, '"', Strings.toHexString(addresses[i].addr), '"');
            json = string.concat(json, ',');
            json = string.concat(json, '"name":');
            json = string.concat(json, '"', addresses[i].name, '"');
            json = string.concat(json, '}');
            if (i < addresses.length - 1) {
                json = string.concat(json, ',');
            }
        }
        json = string.concat(json, ']');

        vm.writeJson(json, path);
    }

    function get(string memory name) external view returns (address) {
        RecordedAddress[] memory addresses = _read();

        for (uint256 i = 0; i < addresses.length; i++) {
            bool sameName = keccak256(abi.encodePacked(addresses[i].name)) == keccak256(abi.encodePacked(name));
            if (sameName) {
                return addresses[i].addr;
            }
        }

        revert(
            string.concat(
                "[AddressLib] Getting unknown address ",
                name
            )
        );
    }

    function set(string memory name, address addr) external {
        RecordedAddress[] memory addresses = _read();

        bool replaced = false;
        for (uint256 i = 0; i < addresses.length; i++) {
            bool sameAddress = addresses[i].addr == addr;
            bool sameName = keccak256(abi.encodePacked(addresses[i].name)) == keccak256(abi.encodePacked(name));

            // check if address is duplicate
            if (sameAddress && !sameName) {
                console.log(
                    string.concat(
                        "[AddressLib] Adding duplicate address ",
                        Strings.toHexString(addr),
                        ", adding with name ",
                        name,
                        ", exists with name ",
                        addresses[i].name
                    )
                );
            }

            // check if name is duplicate
            if (sameName) {
                console.log(string.concat("[AddressLib] Overriding address with name: ", name));
                replaced = true;
                addresses[i].addr = addr;
            }
        }

        if (replaced) {
            _write(addresses);
            return;
        }

        RecordedAddress[] memory newAddresses = new RecordedAddress[](addresses.length + 1);
        for (uint256 i = 0; i < addresses.length; i++) {
            newAddresses[i] = addresses[i];
        }
        newAddresses[addresses.length] = RecordedAddress({name: name, addr: addr});
        console.log(
            string.concat(
                "[AddressLib] Add address ",
                name,
                " = ",
                Strings.toHexString(addr)
            )
        );
        _write(newAddresses);
    }
}
