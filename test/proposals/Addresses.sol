// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Test} from "@forge-std/Test.sol";

contract Addresses is Test {
    mapping(string => address) private _mainnet;
    mapping(address => string) private _mainnetLabel;

    struct RecordedAddress {
        address addr;
        string name;
    }
    RecordedAddress[] private recordedAddresses;

    constructor() {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/protocol-configuration/addresses.mainnet.json");
        string memory json = vm.readFile(path);
        bytes memory parsedJson = vm.parseJson(json);
        RecordedAddress[] memory addresses = abi.decode(parsedJson, (RecordedAddress[]));

        for (uint256 i = 0; i < addresses.length; i++) {
            _addMainnet(addresses[i].name, addresses[i].addr);
        }
    }

    function _addMainnet(string memory name, address addr) private {
        _mainnet[name] = addr;
        _mainnetLabel[addr] = name;
        vm.label(addr, name);
    }

    function mainnet(string memory name) public view returns (address) {
        return _mainnet[name];
    }

    function mainnetLabel(address addr) public view returns (string memory) {
        return _mainnetLabel[addr];
    }

    function addMainnet(string memory name, address addr) public {
        _addMainnet(name, addr);

        recordedAddresses.push(RecordedAddress({name: name, addr: addr}));
    }

    function resetRecordingAddresses() external {
        delete recordedAddresses;
    }

    function getRecordedAddresses()
        external
        view
        returns (string[] memory names, address[] memory addresses)
    {
        names = new string[](recordedAddresses.length);
        addresses = new address[](recordedAddresses.length);
        for (uint256 i = 0; i < recordedAddresses.length; i++) {
            names[i] = recordedAddresses[i].name;
            addresses[i] = recordedAddresses[i].addr;
        }
    }
}
