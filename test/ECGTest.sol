pragma solidity 0.8.13;

import {Vm} from "@forge-std/Vm.sol";
import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

abstract contract ECGTest is Test {
    string internal constant ADDR_PATH =
        "/protocol-configuration/addresses.json";

    string internal constant ADDR_PATH_SEPOLIA =
        "/protocol-configuration/addresses.sepolia.json";

    string internal constant ADDR_PATH_ARBITRUM =
        "/protocol-configuration/addresses.arbitrum.json";

    struct RecordedAddress {
        address addr;
        string name;
    }

    function _read() public view returns (RecordedAddress[] memory addresses) {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, ADDR_PATH);

        if (block.chainid == 11155111) {
            path = string.concat(root, ADDR_PATH_SEPOLIA);
        }
        if (block.chainid == 42161) {
            path = string.concat(root, ADDR_PATH_ARBITRUM);
        }

        string memory json = vm.readFile(path);
        bytes memory parsedJson = vm.parseJson(json);
        addresses = abi.decode(parsedJson, (RecordedAddress[]));
    }

    function _write(RecordedAddress[] memory addresses) internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, ADDR_PATH);

        if (block.chainid == 11155111) {
            path = string.concat(root, ADDR_PATH_SEPOLIA);
        }
        if (block.chainid == 42161) {
            path = string.concat(root, ADDR_PATH_ARBITRUM);
        }

        string memory json = "[";
        for (uint256 i = 0; i < addresses.length; i++) {
            json = string.concat(json, "{");
            json = string.concat(json, '"addr":');
            json = string.concat(
                json,
                '"',
                Strings.toHexString(addresses[i].addr),
                '"'
            );
            json = string.concat(json, ",");
            json = string.concat(json, '"name":');
            json = string.concat(json, '"', addresses[i].name, '"');
            json = string.concat(json, "}");
            if (i < addresses.length - 1) {
                json = string.concat(json, ",");
            }
        }
        json = string.concat(json, "]");

        vm.writeJson(json, path);
    }

    function getAddr(string memory name) public view returns (address) {
        RecordedAddress[] memory addresses = _read();

        for (uint256 i = 0; i < addresses.length; i++) {
            bool sameName = keccak256(abi.encodePacked(addresses[i].name)) ==
                keccak256(abi.encodePacked(name));
            if (sameName) {
                return addresses[i].addr;
            }
        }

        revert(string.concat("[AddressLib] Getting unknown address ", name));
    }

    function setAddr(string memory name, address addr) public {
        RecordedAddress[] memory addresses = _read();

        bool replaced = false;
        for (uint256 i = 0; i < addresses.length; i++) {
            bool sameAddress = addresses[i].addr == addr;
            bool sameName = keccak256(abi.encodePacked(addresses[i].name)) ==
                keccak256(abi.encodePacked(name));

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
                console.log(
                    string.concat(
                        "[AddressLib] Overriding address with name: ",
                        name
                    )
                );
                replaced = true;
                addresses[i].addr = addr;
            }
        }

        if (replaced) {
            _write(addresses);
            return;
        }

        RecordedAddress[] memory newAddresses = new RecordedAddress[](
            addresses.length + 1
        );
        for (uint256 i = 0; i < addresses.length; i++) {
            newAddresses[i] = addresses[i];
        }
        newAddresses[addresses.length] = RecordedAddress({
            name: name,
            addr: addr
        });
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

    function _contains(
        string memory what,
        string memory where
    ) internal pure returns (bool) {
        bytes memory whatBytes = bytes(what);
        bytes memory whereBytes = bytes(where);

        if (whatBytes.length > whereBytes.length) {
            return false;
        }

        bool found = false;
        for (uint i = 0; i <= whereBytes.length - whatBytes.length; i++) {
            bool flag = true;
            for (uint j = 0; j < whatBytes.length; j++)
                if (whereBytes[i + j] != whatBytes[j]) {
                    flag = false;
                    break;
                }
            if (flag) {
                found = true;
                break;
            }
        }
        return found;
    }
}
