// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {EntryGuard} from "./EntryGuard.sol";
import {TStorageLib} from "@src/gateway/v2/TStorageLib.sol";
import {LowLevelCall} from "./LowLevelCall.sol";

/// @title FlashloanReceiver
/// @notice util to receive flashloans
abstract contract FlashloanReceiver is EntryGuard, LowLevelCall, Pausable {

    // keccak256(abi.encode(uint256(keccak256("ecg.storage.gateway.flashloanProvider")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _SLOT_FLASHLOAN_PROVIDER = 0xc0b4846dffbaf021cf5493af440aba0010f84b495c6da5f6bdc8f33c4014a800;
    // keccak256(abi.encode(uint256(keccak256("ecg.storage.gateway.flashloanToken")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _SLOT_FLASHLOAN_TOKEN = 0xb171977de5e0be753b6b27a95d648d37e2c0b684c56a955ca38681e22de6a500;
    // keccak256(abi.encode(uint256(keccak256("ecg.storage.gateway.flashloanAmount")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _SLOT_FLASHLOAN_AMOUNT = 0x2837d0abf4cb716bd4a569eb90915c2813b45a56962010f6acd221d6da060900;
    // keccak256(abi.encode(uint256(keccak256("ecg.storage.gateway.flashloanFee")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _SLOT_FLASHLOAN_FEE = 0x8beaf72728a3820c3512f1ed473d1e460045613aa803096527a31dbe3bd07800;
    // keccak256(abi.encode(uint256(keccak256("ecg.storage.gateway.flashloanCall")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _SLOT_FLASHLOAN_CALL = 0x00582406970a5f4f653f08368825d166534bfe985acacb314acb165f7895f300;

    /// @notice optional override for checking whitelists of flashloan providers
    function _isFlashloanProviderWhitelisted(
        address/* provider*/,
        bytes memory/* data*/
    ) internal virtual returns (bool) {
        return true;
    }

    /// @notice execute an action after receiving a flashloan
    function actionWithFlashLoan(
        address flashloanToken,
        uint256 flashloanAmount,
        uint256 flashloanFee,
        address flashloanProvider,
        bytes memory initiateFlashloanCall,
        bytes memory preFlashloanCall,
        bytes memory withFlashloanCall,
        bytes memory postFlashloanCall
    ) external entryPoint whenNotPaused {
        // check allowlist
        require(
            _isFlashloanProviderWhitelisted(flashloanProvider, initiateFlashloanCall),
            "FlashloanReceiver: invalid provider"
        );

        // tstores
        TStorageLib._address(_SLOT_FLASHLOAN_PROVIDER, flashloanProvider);
        TStorageLib._address(_SLOT_FLASHLOAN_TOKEN, flashloanToken);
        TStorageLib._uint256(_SLOT_FLASHLOAN_AMOUNT, flashloanAmount);
        TStorageLib._uint256(_SLOT_FLASHLOAN_FEE, flashloanFee);
        TStorageLib._bytes(_SLOT_FLASHLOAN_CALL, withFlashloanCall);

        // pre-flashloan call
        if (preFlashloanCall.length != 0) {
            _call(address(this), preFlashloanCall);
        }
        // initiate flashloan call
        _call(flashloanProvider, initiateFlashloanCall);
        // post-flashloan call
        if (postFlashloanCall.length != 0) {
            _call(address(this), postFlashloanCall);
        }

        TStorageLib._address(_SLOT_FLASHLOAN_PROVIDER, address(0));
        TStorageLib._address(_SLOT_FLASHLOAN_TOKEN, address(0));
        TStorageLib._uint256(_SLOT_FLASHLOAN_AMOUNT, 0);
        TStorageLib._uint256(_SLOT_FLASHLOAN_FEE, 0);
        TStorageLib._bytes(_SLOT_FLASHLOAN_CALL, "");
    }

    /// @notice Fallback function is used to handle flashloan callback because
    /// every flashloan provider has a different callback function they call after
    /// sending funds.
    fallback() external payable afterEntry {
        // tloads
        address flashloanProvider = TStorageLib._address(_SLOT_FLASHLOAN_PROVIDER);
        address flashloanToken = TStorageLib._address(_SLOT_FLASHLOAN_TOKEN);
        uint256 flashloanAmount = TStorageLib._uint256(_SLOT_FLASHLOAN_AMOUNT);
        uint256 flashloanFee = TStorageLib._uint256(_SLOT_FLASHLOAN_FEE);
        bytes memory flashloanCall = TStorageLib._bytes(_SLOT_FLASHLOAN_CALL);

        // check sender
        require(
            msg.sender == flashloanProvider,
            "FlashloanReceiver: invalid sender"
        );
    
        // perform calls
        if (flashloanCall.length != 0) {
            _call(address(this), flashloanCall);
        }

        // repay flashloan
        IERC20(flashloanToken).transfer(
            flashloanProvider,
            flashloanAmount + flashloanFee
        );
    }

    // can receive ETH
    receive() external payable {}
}
