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
        TStorageLib._bytes(_SLOT_FLASHLOAN_CALL, "");
    }

    /// @notice Fallback function is used to handle flashloan callback because
    /// every flashloan provider has a different callback function they call after
    /// sending funds.
    /// @dev do not forget to transfer back tokens to flashloan provider or approve
    /// flashloaned tokens to the flashloan provider inside the flashloanCall
    fallback() external payable afterEntry {
        // tloads
        address flashloanProvider = TStorageLib._address(_SLOT_FLASHLOAN_PROVIDER);
        bytes memory flashloanCall = TStorageLib._bytes(_SLOT_FLASHLOAN_CALL);

        // check sender
        require(
            msg.sender == flashloanProvider,
            "FlashloanReceiver: invalid sender"
        );

        // perform calls
        // we have to repay flashloan (transfer or approve),
        // so we know there needs to be a flashloanCall
        require(
            flashloanCall.length != 0,
            "FlashloanReceiver: no flashloan call"
        );
        _call(address(this), flashloanCall);
    }

    // can receive ETH
    receive() external payable {}
}
