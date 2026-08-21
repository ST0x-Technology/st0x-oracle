// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

/// @title MockMalformedNavVaultToken
/// @notice A collateral stub whose `convertToAssets` SUCCEEDS but returns a
/// caller-chosen number of bytes instead of the single 32-byte word ERC-4626
/// mandates.
///
/// Neither `MockNavVaultToken` (a well-behaved word) nor
/// `MockRevertingNavVaultToken` (a failed call) can express this arm of the
/// adapter's fail-closed NAV probe: a call that reports success while saying
/// nothing (empty returndata, e.g. a token with a permissive fallback) or
/// saying too much (an over-long return whose leading word merely looks like
/// a ratio). Both are unverifiable, not usable.
///
/// `decimals()` exists only so the adapter's `initialize` can precompute its
/// scale; the rest of the ERC-4626 / ERC-20 surface is intentionally absent.
contract MockMalformedNavVaultToken {
    uint256 private _returnLength;
    uint256 private _returnWord;

    function decimals() external pure returns (uint8) {
        return 18;
    }

    /// @param returnLength How many bytes the probe returns. At most 64 — the
    /// scratch space the return is served from.
    /// @param returnWord The word both returned slots carry.
    function setProbeReturn(uint256 returnLength, uint256 returnWord) external {
        require(returnLength <= 64, "return must fit scratch space");
        _returnLength = returnLength;
        _returnWord = returnWord;
    }

    /// @dev No declared return type: the probe is a low-level staticcall, so
    /// only the raw success flag and returndata matter.
    function convertToAssets(uint256) external view {
        uint256 length = _returnLength;
        uint256 word = _returnWord;
        assembly ("memory-safe") {
            mstore(0x00, word)
            mstore(0x20, word)
            return(0x00, length)
        }
    }
}
