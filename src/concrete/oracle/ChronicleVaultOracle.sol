// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {IChronicle} from "src/interface/IChronicle.sol";
import {AggregatorV2V3Interface} from "src/interface/IAggregatorV2V3.sol";
import {LibDecimalFloat, Float} from "rain-math-float-0.1.1/src/lib/LibDecimalFloat.sol";
import {IERC4626} from "@openzeppelin-contracts-5.6.1/interfaces/IERC4626.sol";
import {ICLONEABLE_V2_SUCCESS, ICloneableV2} from "rain-factory-0.1.1/src/interface/ICloneableV2.sol";
import {Initializable} from "@openzeppelin-contracts-5.6.1/proxy/utils/Initializable.sol";

/// @dev Error raised when a zero address is provided for the Chronicle feed.
error ZeroChronicle();

/// @dev Error raised when a zero address is provided for the vault.
error ZeroVault();

/// @dev Error raised when a zero max age is provided. Zero would mean every
/// price read is instantly stale, which is never the desired configuration.
error ZeroMaxAge();

/// @dev Error raised when the Chronicle reading is older than `maxAge` seconds.
/// @param age The `block.timestamp` of the stale Chronicle poke.
error ChroniclePriceStale(uint256 age);

/// @dev Error raised when the vault has zero total supply (no shares minted).
/// Pricing one share of a zero-supply vault is undefined.
error ZeroVaultSupply();

/// @dev Error raised when the computed vault share price is zero. A zero
/// price is never a valid Chainlink-compatible answer.
error ZeroVaultSharePrice();

/// @dev Error raised when the vault share price overflows int256.
/// @param price8 The unsigned 8-decimal share price that wouldn't fit.
error VaultSharePriceOverflow(uint256 price8);

/// @dev Error raised when a caller requests historical round data. Chronicle
/// exposes only the latest poke, so there is no per-round history here.
/// Callers needing historical data should query an indexer or Chronicle's
/// off-chain feed history directly.
/// @param roundId The unsupported round id that was requested.
error HistoricalRoundDataUnsupported(uint80 roundId);

/// @title ChronicleVaultOracleConfig
/// @notice Configuration for `ChronicleVaultOracle.initialize`.
/// @param chronicle The Chronicle Protocol oracle (`IChronicle`) for the
/// underlying asset price.
/// @param vault The ERC-4626 vault address whose shares we're pricing.
/// `vault.totalAssets() / vault.totalSupply()` is the share-to-asset ratio
/// applied on top of the Chronicle price. For a wtStock-style wrapper this
/// captures the post-corporate-action NAV bump.
/// @param maxAge Maximum acceptable Chronicle reading age in seconds.
/// `block.timestamp - age > maxAge` reverts `ChroniclePriceStale`. Immutable
/// after init — redeploy a fresh proxy to change.
struct ChronicleVaultOracleConfig {
    IChronicle chronicle;
    address vault;
    uint256 maxAge;
}

/// @title ChronicleVaultOracle
/// @notice Prices ERC-4626 vault shares by reading the underlying asset price
/// from a Chronicle Protocol feed and multiplying by the vault's
/// assets-per-share ratio. Exposes prices via Chainlink's
/// `AggregatorV2V3Interface` so consumers (Euler, Aave-style lending protocols)
/// can target the same surface they already use for Chainlink feeds.
///
/// Math: `vaultSharePrice = chroniclePrice * totalAssets / totalSupply`
/// scaled to 8 decimals. Performed in Rain float space throughout so neither
/// operand can overflow uint256 — the conversion to fixed-point 8dp happens
/// only at the final return.
///
/// Deliberately stateless beyond config. No admin, no pause flag. Operational
/// concerns (manual emergency pause, corporate-action-aware auto-pause) live
/// in `PausableOracleWrapper` so the same wrapper can decorate any
/// `AggregatorV2V3Interface` source without coupling pause logic to one
/// oracle provider.
///
/// Deployed as a beacon-proxy clone via `ICloneableV2.initialize`.
contract ChronicleVaultOracle is AggregatorV2V3Interface, ICloneableV2, Initializable {
    /// @dev The Chronicle Protocol feed for the underlying asset.
    IChronicle public chronicle;

    /// @dev The ERC-4626 vault this oracle prices shares for.
    address public vault;

    /// @dev Maximum acceptable Chronicle reading age in seconds.
    uint256 public maxAge;

    /// @notice Emitted when the oracle is initialized. Single source of
    /// truth for off-chain indexers — all immutable config in one event.
    /// @param sender The caller that initialized the proxy.
    /// @param config The initialization configuration.
    event ChronicleVaultOracleInitialized(address indexed sender, ChronicleVaultOracleConfig config);

    constructor() {
        _disableInitializers();
    }

    /// @notice Documents the typed signature of the initialize function. Per
    /// `ICloneableV2` this overload MUST always revert; callers use the
    /// `bytes calldata` overload below.
    /// @dev Always reverts with `InitializeSignatureFn`.
    /// @param config The initialization configuration. Ignored.
    /// @return Never returns; included only for the function signature.
    function initialize(ChronicleVaultOracleConfig memory config) external pure returns (bytes32) {
        (config);
        revert InitializeSignatureFn();
    }

    /// @inheritdoc ICloneableV2
    function initialize(bytes calldata data) external initializer returns (bytes32) {
        ChronicleVaultOracleConfig memory config = abi.decode(data, (ChronicleVaultOracleConfig));

        if (address(config.chronicle) == address(0)) revert ZeroChronicle();
        if (config.vault == address(0)) revert ZeroVault();
        if (config.maxAge == 0) revert ZeroMaxAge();

        chronicle = config.chronicle;
        vault = config.vault;
        maxAge = config.maxAge;

        emit ChronicleVaultOracleInitialized(msg.sender, config);

        return ICLONEABLE_V2_SUCCESS;
    }

    /// @inheritdoc AggregatorV2V3Interface
    function description() external pure override returns (string memory) {
        return "";
    }

    /// @inheritdoc AggregatorV2V3Interface
    function decimals() external pure override returns (uint8) {
        return 8;
    }

    /// @inheritdoc AggregatorV2V3Interface
    function version() external pure override returns (uint256) {
        return 1;
    }

    /// @inheritdoc AggregatorV2V3Interface
    function latestAnswer() external view override returns (int256) {
        (uint256 chroniclePrice,) = _readChronicleChecked();
        return _vaultSharePrice(chroniclePrice);
    }

    /// @inheritdoc AggregatorV2V3Interface
    /// @dev `roundId` and `answeredInRound` are derived from the Chronicle
    /// `age` (truncated to `uint80`) so they advance monotonically per
    /// Chainlink convention without adding storage. Integrators that diff
    /// `roundId` between calls to detect a fresh update will see a different
    /// value whenever Chronicle has produced a new poke. The `uint80` window
    /// covers every plausible deployment lifetime.
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (uint256 chroniclePrice, uint256 age) = _readChronicleChecked();
        int256 scaledPrice = _vaultSharePrice(chroniclePrice);

        uint80 ageRound = uint80(age);
        return (ageRound, scaledPrice, age, age, ageRound);
    }

    /// @inheritdoc AggregatorV2V3Interface
    /// @dev Chronicle exposes only its latest value — no per-round history
    /// through this interface. Every call reverts with
    /// `HistoricalRoundDataUnsupported(_roundId)`. Callers needing
    /// point-in-time data should query Chronicle's off-chain feed history
    /// or an indexer of Chronicle pokes directly.
    function getRoundData(uint80 _roundId) external pure override returns (uint80, int256, uint256, uint256, uint80) {
        revert HistoricalRoundDataUnsupported(_roundId);
    }

    /// @dev Read Chronicle and revert if the reading is stale. We use
    /// `readWithAge` (which reverts on no value) rather than `tryReadWithAge`
    /// (which returns isValid=false) — a missing Chronicle value is always
    /// an oracle failure that must surface, not be silently masked.
    function _readChronicleChecked() internal view returns (uint256 value, uint256 age) {
        // slither-disable-next-line chronicle-unchecked-price
        (value, age) = chronicle.readWithAge();
        // slither-disable-next-line timestamp
        if (block.timestamp - age > maxAge) revert ChroniclePriceStale(age);
    }

    /// @dev Compute vault share price from a Chronicle reading via Rain float
    /// math so neither operand can overflow uint256. Chronicle prices are
    /// 18-decimal `uint256` (Chronicle convention). The vault ratio is
    /// `totalAssets / totalSupply`. Output is 8-decimal `int256` per Chainlink
    /// `latestAnswer` convention.
    function _vaultSharePrice(uint256 chroniclePrice) internal view returns (int256) {
        // Chronicle's value is 18-decimal uint256 — pack as a float with
        // exponent -18 to recover the natural quantity.
        Float priceFloat = LibDecimalFloat.fromFixedDecimalLosslessPacked(chroniclePrice, 18);

        IERC4626 vaultContract = IERC4626(vault);
        uint256 totalAssets = vaultContract.totalAssets();
        uint256 totalSupply = vaultContract.totalSupply();

        if (totalSupply == 0) revert ZeroVaultSupply();

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
