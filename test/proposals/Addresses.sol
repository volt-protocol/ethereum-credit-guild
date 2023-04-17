// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.13;

import {Test} from "@forge-std/Test.sol";

contract Addresses is Test {
    mapping(string => address) private _mainnet;

    struct RecordedAddress {
        string name;
        address addr;
    }
    RecordedAddress[] private recordedAddresses;

    constructor() {
        // TODO: read a json file
        _addMainnet("TEAM_MULTISIG", 0xcBB83206698E8788F85EFbEeeCAd17e53366EBDf);
        _addMainnet("EOA_1", 0x6ef71cA9cD708883E129559F5edBFb9d9D5C6148);
        _addMainnet("EOA_2", 0xd90E9181B20D8D1B5034d9f5737804Da182039F6);
        _addMainnet("ERC20_USDC", 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    }

    function _addMainnet(string memory name, address addr) private {
        _mainnet[name] = addr;
        vm.label(addr, name);
    }

    function mainnet(string memory name) public view returns (address) {
        return _mainnet[name];
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
