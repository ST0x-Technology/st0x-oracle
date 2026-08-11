// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

/// @title MockRevertingNavVaultToken
/// @notice A collateral stub whose `convertToAssets` always reverts — the
/// "vault exists but the probe fails" arm of `MorphoPairAdapter`'s
/// fail-closed NAV-ratio gate. `decimals()` exists only so the adapter's
/// `initialize` can precompute its scale.
contract MockRevertingNavVaultToken {
    function decimals() external pure returns (uint8) {
        return 18;
    }

    function convertToAssets(uint256) external pure returns (uint256) {
        revert("probe reverts");
    }
}
