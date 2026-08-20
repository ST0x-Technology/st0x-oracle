// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

/// @title MockWordRevertingNavVaultToken
/// @notice A collateral stub whose `convertToAssets` REVERTS but leaves
/// exactly one 32-byte word in returndata — the same shape a successful
/// `convertToAssets` produces.
///
/// `MockRevertingNavVaultToken` reverts with a plain `Error(string)`, whose
/// returndata is far longer than a word, so it cannot distinguish a probe
/// that keys off the call's success flag from one that keys off the returned
/// data's shape. This stub can: the word it reverts with is caller-chosen, so
/// a test can make it the very ratio the stored price was computed against.
/// Anything that reads returndata without honouring the failure would decode
/// a "matching" ratio out of a call that never succeeded.
///
/// `decimals()` exists only so the adapter's `initialize` can precompute its
/// scale; the rest of the ERC-4626 / ERC-20 surface is intentionally absent.
contract MockWordRevertingNavVaultToken {
    uint256 private _revertWord;

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function setRevertWord(uint256 v) external {
        _revertWord = v;
    }

    /// @dev No declared return type: the probe is a low-level staticcall, so
    /// only the raw success flag and returndata matter.
    function convertToAssets(uint256) external view {
        uint256 word = _revertWord;
        assembly ("memory-safe") {
            mstore(0x00, word)
            revert(0x00, 0x20)
        }
    }
}
