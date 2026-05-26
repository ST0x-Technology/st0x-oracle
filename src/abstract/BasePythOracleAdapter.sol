// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {PythStructs} from "pyth-sdk/PythStructs.sol";
import {LibDecimalFloat, Float} from "rain-math-float-0.1.1/src/lib/LibDecimalFloat.sol";
import {IERC4626} from "@openzeppelin-contracts-5.6.1/interfaces/IERC4626.sol";
import {AggregatorV3Interface} from "src/interface/IAggregatorV3.sol";

/// @dev Error raised when the oracle is paused.
error OraclePaused();

/// @dev Error raised when the conservative price (price - confidence) is not
/// positive.
error NonPositivePrice(int256 price);

/// @dev Error raised when a zero address is provided for the vault.
error ZeroVault();

/// @dev Error raised when the caller is not the admin.
error OnlyAdmin();

/// @dev Error raised when a zero address is provided for the admin.
error ZeroAdmin();

/// @dev Error raised when the vault has zero total supply (no shares minted).
error ZeroVaultSupply();

/// @dev Error raised when the computed vault share price is zero.
error ZeroVaultSharePrice();

/// @dev Error raised when the vault share price overflows int256.
error VaultSharePriceOverflow(uint256 price8);

/// @title BasePythOracleAdapter
/// @notice Abstract base for Pyth oracle adapters that price ERC-4626 vault
/// shares. Provides shared logic for conservative pricing, vault share price
/// computation, admin/pause governance, and AggregatorV3Interface metadata.
/// Subclasses implement `_getPriceData()` to fetch price from Pyth (single
/// feed or multi-feed cascading).
abstract contract BasePythOracleAdapter is AggregatorV3Interface {
    /// @dev The ERC-4626 vault this oracle prices shares for.
    address public vault;
    /// @dev Emergency pause flag.
    bool public paused;
    /// @dev Admin address for governance actions.
    address public admin;

    /// @dev Emitted when the pause state changes.
    event PauseSet(bool isPaused);
    /// @dev Emitted when the admin is changed.
    event AdminSet(address indexed oldAdmin, address indexed newAdmin);

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    /// @inheritdoc AggregatorV3Interface
    function description() external pure override returns (string memory) {
        return "";
    }

    /// @inheritdoc AggregatorV3Interface
    function decimals() external pure override returns (uint8) {
        return 8;
    }

    /// @inheritdoc AggregatorV3Interface
    function version() external pure override returns (uint256) {
        return 1;
    }

    /// @inheritdoc AggregatorV3Interface
    // slither-disable-next-line pyth-unchecked-confidence
    function latestAnswer() external view override returns (int256) {
        _validateNotPaused();
        // Confidence is checked in _vaultSharePrice -> _conservativePriceFloat
        PythStructs.Price memory priceData = _getPriceData();
        return _vaultSharePrice(priceData);
    }

    /// @inheritdoc AggregatorV3Interface
    // slither-disable-next-line pyth-unchecked-confidence
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        _validateNotPaused();
        // Confidence is checked in _vaultSharePrice -> _conservativePriceFloat
        PythStructs.Price memory priceData = _getPriceData();
        int256 scaledPrice = _vaultSharePrice(priceData);

        return (1, scaledPrice, uint256(uint64(priceData.publishTime)), uint256(uint64(priceData.publishTime)), 1);
    }

    /// @notice Pause or unpause the oracle. Admin only.
    function setPaused(bool isPaused) external onlyAdmin {
        paused = isPaused;
        emit PauseSet(isPaused);
    }

    /// @notice Update the admin address. Admin only.
    /// @param newAdmin The new admin address.
    function setAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAdmin();
        emit AdminSet(admin, newAdmin);
        admin = newAdmin;
    }

    /// @dev Subclasses implement this to fetch Pyth price data.
    /// Single-feed adapters call getPriceNoOlderThan directly.
    /// Multi-feed adapters iterate and return the first non-stale price.
    function _getPriceData() internal view virtual returns (PythStructs.Price memory);

    /// @dev Reverts if the oracle is paused.
    function _validateNotPaused() internal view {
        if (paused) revert OraclePaused();
    }

    /// @dev Computes conservative price (price - confidence) as a Rain Float.
    /// Reverts if the conservative price is not positive.
    /// @param priceData The Pyth price data.
    /// @return The conservative price as a Rain Float.
    function _conservativePriceFloat(PythStructs.Price memory priceData) internal pure returns (Float) {
        // slither-disable-next-line pyth-unchecked-confidence
        int256 conservativePrice = int256(priceData.price) - int256(uint256(priceData.conf));
        if (conservativePrice <= 0) {
            revert NonPositivePrice(conservativePrice);
        }
        return LibDecimalFloat.packLossless(conservativePrice, int256(priceData.expo));
    }

    /// @dev Computes the vault share price using Rain float arithmetic
    /// throughout to avoid overflow. The conservative Pyth price is multiplied
    /// by the vault's assets-per-share ratio entirely in float space, then
    /// converted to 8-decimal fixed point only at the end.
    /// vaultSharePrice = conservativePrice * totalAssets / totalSupply
    /// Reverts if the vault has zero total supply.
    /// @param priceData The Pyth price data.
    /// @return The vault share price at 8 decimals.
    function _vaultSharePrice(PythStructs.Price memory priceData) internal view returns (int256) {
        Float priceFloat = _conservativePriceFloat(priceData);

        IERC4626 vaultContract = IERC4626(vault);
        uint256 totalAssets = vaultContract.totalAssets();
        uint256 totalSupply = vaultContract.totalSupply();

        if (totalSupply == 0) revert ZeroVaultSupply();

        // Perform vault ratio multiplication entirely in float space.
        Float assetsFloat = LibDecimalFloat.fromFixedDecimalLosslessPacked(totalAssets, 0);
        Float supplyFloat = LibDecimalFloat.fromFixedDecimalLosslessPacked(totalSupply, 0);
        Float vaultSharePriceFloat = LibDecimalFloat.div(LibDecimalFloat.mul(priceFloat, assetsFloat), supplyFloat);

        // The second return (bool lossy) is intentionally ignored — lossy
        // conversion is expected and acceptable when scaling to 8 decimals.
        // slither-disable-next-line unused-return
        (uint256 price8,) = LibDecimalFloat.toFixedDecimalLossy(vaultSharePriceFloat, 8);

        if (price8 == 0) revert ZeroVaultSharePrice();
        if (price8 > uint256(type(int256).max)) revert VaultSharePriceOverflow(price8);

        return int256(price8);
    }
}
