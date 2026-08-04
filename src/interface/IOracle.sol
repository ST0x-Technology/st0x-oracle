// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity ^0.8.25;

/// @title IOracle
/// @notice Morpho Blue oracle interface, vendored from Morpho's published
/// shape.
/// @dev `price()` returns the price of 1 unit of collateral in loan token,
/// scaled by `1e36 * 10^loanDecimals / 10^collateralDecimals`.
interface IOracle {
    function price() external view returns (uint256);
}
