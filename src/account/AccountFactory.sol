// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {AccountImplementation} from "@src/account/AccountImplementation.sol";

/// Smart account factory for the ECG
contract AccountFactory is Ownable {
    /// @notice mapping of allowed account implementations
    mapping(address => bool) public implementations;

    /// @notice timestamp of creation of an account
    /// (used to check that an account has been created by this factory)
    mapping(address => uint256) public created;

    /// @notice mapping of allowed signatures per target address
    /// For example allowing "flashLoan" on the balancer vault
    mapping(address => mapping(bytes4 => bool)) public allowedCalls;

    /// @notice emitted when an account implementation's "allowed" status changes
    event ImplementationAllowChanged(
        uint256 indexed when,
        address indexed implementation,
        bool allowed
    );

    /// @notice emitted when an account is created
    event AccountCreated(
        uint256 indexed when,
        address indexed implementation,
        address indexed account,
        address user
    );

    /// @notice emitted when a call is allowed or not by the function allowCall
    event CallAllowed(address indexed target, bytes4 functionSelector, bool isAllowed);

    constructor() Ownable() {}

    /// @notice Allow or disallow a given implemenation
    function allowImplementation(
        address implementation,
        bool allowed
    ) external onlyOwner {
        implementations[implementation] = allowed;
        emit ImplementationAllowChanged(
            block.timestamp,
            implementation,
            allowed
        );
    }

    /// @notice allow (or disallow) a function call for a target address
    function allowCall(address target, bytes4 functionSelector, bool allowed) public onlyOwner {
        allowedCalls[target][functionSelector] = allowed;
        emit CallAllowed(target, functionSelector, allowed);
    }

    /// @notice Create a new acount and initialize it.
    function createAccount(address implementation) external returns (address) {
        require(
            implementations[implementation],
            "AccountFactory: invalid implementation"
        );

        address account = Clones.clone(implementation);
        AccountImplementation(account).initialize(msg.sender);

        created[account] = block.timestamp;

        emit AccountCreated(
            block.timestamp,
            implementation,
            account,
            msg.sender
        );
        return account;
    }
}
