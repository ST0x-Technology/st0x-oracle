// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

/// @title MockERC4626
/// @notice Minimal mock exposing `totalAssets()`, `totalSupply()`, and
/// `asset()` — the only ERC-4626 surface `DIAVaultOracle` consumes (`asset()`
/// is the tStock the oracle derives its corporate-actions vault from). Tests
/// set them via the setters. The rest of the IERC4626 / IERC20 surface is
/// intentionally absent — a new dependency will revert and surface itself.
contract MockERC4626 {
    uint256 private _totalAssets;
    uint256 private _totalSupply;
    address private _asset;

    function setTotalAssets(uint256 v) external {
        _totalAssets = v;
    }

    function setTotalSupply(uint256 v) external {
        _totalSupply = v;
    }

    function setAsset(address a) external {
        _asset = a;
    }

    function totalAssets() external view returns (uint256) {
        return _totalAssets;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function asset() external view returns (address) {
        return _asset;
    }
}
