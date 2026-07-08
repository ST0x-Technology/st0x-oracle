// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

/// @title MockERC4626
/// @notice Minimal mock that only exposes `totalAssets()` and `totalSupply()`,
/// which are the only ERC-4626 surface points `ChronicleVaultOracle` actually
/// consumes. Tests set them via the setters. The rest of the IERC4626 / IERC20
/// surface is intentionally absent — if a consumer regresses into needing
/// e.g. `convertToAssets`, the call will revert and surface the new dependency.
contract MockERC4626 {
    uint256 private _totalAssets;
    uint256 private _totalSupply;

    function setTotalAssets(uint256 v) external {
        _totalAssets = v;
    }

    function setTotalSupply(uint256 v) external {
        _totalSupply = v;
    }

    function totalAssets() external view returns (uint256) {
        return _totalAssets;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }
}
