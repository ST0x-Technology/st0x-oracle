// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

/// @title MockERC20Decimals
/// @dev Minimal token stub exposing only `decimals()` — the sole ERC-20
/// surface `MorphoPairAdapter.initialize` reads to precompute its scale.
contract MockERC20Decimals {
    uint8 internal immutable I_DECIMALS;

    constructor(uint8 tokenDecimals) {
        I_DECIMALS = tokenDecimals;
    }

    function decimals() external view returns (uint8) {
        return I_DECIMALS;
    }
}
