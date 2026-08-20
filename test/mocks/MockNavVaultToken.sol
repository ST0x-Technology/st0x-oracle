// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

/// @title MockNavVaultToken
/// @notice Minimal wt-vault collateral stub for `MorphoPairAdapter` tests:
/// `decimals()` for the init-time scale precompute plus a settable
/// `convertToAssets` — the live NAV probe the adapter's ratio gate performs.
/// The probe asserts the exact `NAV_RATIO_SHARES` share amount so a drifted
/// probe convention surfaces as a revert instead of a silently-wrong ratio.
/// The rest of the ERC-4626 / ERC-20 surface is intentionally absent — a new
/// dependency will revert and surface itself.
contract MockNavVaultToken {
    uint8 internal immutable I_DECIMALS;
    uint256 private _navRatio;

    constructor(uint8 tokenDecimals) {
        I_DECIMALS = tokenDecimals;
    }

    function decimals() external view returns (uint8) {
        return I_DECIMALS;
    }

    function setNavRatio(uint256 v) external {
        _navRatio = v;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        require(shares == 1e18, "probe must ask for NAV_RATIO_SHARES");
        return _navRatio;
    }
}
