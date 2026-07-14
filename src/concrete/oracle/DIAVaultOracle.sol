// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {IDIAOracleV2} from "src/interface/IDIAOracleV2.sol";
import {AggregatorV2V3Interface} from "src/interface/IAggregatorV2V3.sol";
import {LibDecimalFloat, Float} from "rain-math-float-0.1.1/src/lib/LibDecimalFloat.sol";
import {IERC4626} from "@openzeppelin-contracts-5.6.1/interfaces/IERC4626.sol";
import {ICLONEABLE_V2_SUCCESS, ICloneableV2} from "rain-factory-0.1.1/src/interface/ICloneableV2.sol";
import {Initializable} from "@openzeppelin-contracts-5.6.1/proxy/utils/Initializable.sol";

/// @dev Error raised when a zero address is provided for the DIA feed.
error ZeroDIAOracle();

/// @dev Error raised when a zero address is provided for the vault.
error ZeroVault();

/// @dev Error raised when an empty symbol is provided. DIA keys feeds by
/// the bare symbol string (`"COIN"`, `"AMZN"`, ...) and an empty key is a
/// configuration error that would silently return zero.
error EmptySymbol();

/// @dev Error raised when a zero max age is provided. Zero would mean every
/// price read is instantly stale, which is never the desired configuration.
error ZeroMaxAge();

/// @dev Error raised when the DIA feed has never been pushed (value or
/// timestamp == 0). Distinct from `DIAPriceStale` so integrators can
/// disambiguate "feed not yet active" from "feed active but late".
error DIAPriceNotSet();

/// @dev Error raised when the DIA reading is older than `maxAge` seconds.
/// @param timestamp The `block.timestamp` of the stale DIA push.
error DIAPriceStale(uint256 timestamp);

/// @dev Error raised when the vault has zero total supply (no shares minted).
/// Pricing one share of a zero-supply vault is undefined.
error ZeroVaultSupply();

/// @dev Error raised when the computed vault share price is zero. A zero
/// price is never a valid Chainlink-compatible answer.
error ZeroVaultSharePrice();

/// @dev Error raised when the vault share price overflows int256.
/// @param price8 The unsigned 8-decimal share price that wouldn't fit.
error VaultSharePriceOverflow(uint256 price8);

/// @dev Error raised when a caller requests historical round data. DIA
/// exposes only the latest push, so there is no per-round history here.
/// Callers needing historical data should query DIA's off-chain feed
/// history or an indexer of DIA pushes directly.
/// @param roundId The unsupported round id that was requested.
error HistoricalRoundDataUnsupported(uint80 roundId);

/// @title DIAVaultOracleConfig
/// @notice Configuration for `DIAVaultOracle.initialize`.
/// @param diaOracle The DIA Data Association V2 oracle contract holding the
/// underlying asset price.
/// @param symbol The DIA feed key (bare symbol, e.g. `"COIN"`). DIA keys
/// feeds by the bare symbol, not the pair string.
/// @param vault The ERC-4626 vault address whose shares we're pricing.
/// `vault.totalAssets() / vault.totalSupply()` is the share-to-asset ratio
/// applied on top of the DIA price. For a wtStock-style wrapper this
/// captures the post-corporate-action NAV bump.
/// @param maxAge Maximum acceptable DIA push age in seconds.
/// `block.timestamp - timestamp > maxAge` reverts `DIAPriceStale`. Immutable
/// after init — redeploy a fresh proxy to change.
struct DIAVaultOracleConfig {
    IDIAOracleV2 diaOracle;
    string symbol;
    address vault;
    uint256 maxAge;
}

/// @title DIAVaultOracle
/// @notice Prices ERC-4626 vault shares by reading the underlying asset price
/// from a DIA Data Association feed and multiplying by the vault's
/// assets-per-share ratio. Exposes prices via Chainlink's
/// `AggregatorV2V3Interface` so consumers (Euler, Aave-style lending
/// protocols) can target the same surface they already use for Chainlink
/// feeds.
///
/// Math: `vaultSharePrice = diaPrice * totalAssets / totalSupply` scaled
/// to 8 decimals. Performed in Rain float space throughout so neither
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
contract DIAVaultOracle is AggregatorV2V3Interface, ICloneableV2, Initializable {
    /// @custom:storage-location erc7201:st0x.diavaultoracle.main
    struct MainStorage {
        // The DIA Data Association V2 oracle feed for the underlying asset.
        IDIAOracleV2 diaOracle;
        // The DIA feed key (bare symbol, e.g. `"COIN"`).
        string symbol;
        // The ERC-4626 vault this oracle prices shares for.
        address vault;
        // Maximum acceptable DIA push age in seconds.
        uint256 maxAge;
    }

    // keccak256(abi.encode(uint256(keccak256("st0x.diavaultoracle.main")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MAIN_STORAGE_LOCATION = 0xa6b686aa52190f2ecc306934b0149933ff4f6d9fe65f143c543f7c981a9b1200;

    function _main() private pure returns (MainStorage storage $) {
        assembly ("memory-safe") {
            $.slot := MAIN_STORAGE_LOCATION
        }
    }

    /// @notice Emitted when the oracle is initialized. Single source of
    /// truth for off-chain indexers — all immutable config in one event.
    /// @param sender The caller that initialized the proxy.
    /// @param config The initialization configuration.
    event DIAVaultOracleInitialized(address indexed sender, DIAVaultOracleConfig config);

    constructor() {
        _disableInitializers();
    }

    /// @notice The DIA Data Association V2 oracle feed for the underlying asset.
    function diaOracle() public view returns (IDIAOracleV2) {
        return _main().diaOracle;
    }

    /// @notice The DIA feed key (bare symbol, e.g. `"COIN"`).
    function symbol() public view returns (string memory) {
        return _main().symbol;
    }

    /// @notice The ERC-4626 vault this oracle prices shares for.
    function vault() public view returns (address) {
        return _main().vault;
    }

    /// @notice Maximum acceptable DIA push age in seconds.
    function maxAge() public view returns (uint256) {
        return _main().maxAge;
    }

    /// @notice Documents the typed signature of the initialize function. Per
    /// `ICloneableV2` this overload MUST always revert; callers use the
    /// `bytes calldata` overload below.
    /// @dev Always reverts with `InitializeSignatureFn`.
    /// @param config The initialization configuration. Ignored.
    /// @return Never returns; included only for the function signature.
    function initialize(DIAVaultOracleConfig memory config) external pure returns (bytes32) {
        (config);
        revert InitializeSignatureFn();
    }

    /// @inheritdoc ICloneableV2
    function initialize(bytes calldata data) external initializer returns (bytes32) {
        DIAVaultOracleConfig memory config = abi.decode(data, (DIAVaultOracleConfig));

        if (address(config.diaOracle) == address(0)) revert ZeroDIAOracle();
        if (bytes(config.symbol).length == 0) revert EmptySymbol();
        if (config.vault == address(0)) revert ZeroVault();
        if (config.maxAge == 0) revert ZeroMaxAge();

        MainStorage storage $ = _main();
        $.diaOracle = config.diaOracle;
        $.symbol = config.symbol;
        $.vault = config.vault;
        $.maxAge = config.maxAge;

        emit DIAVaultOracleInitialized(msg.sender, config);

        return ICLONEABLE_V2_SUCCESS;
    }

    /// @inheritdoc AggregatorV2V3Interface
    function description() external view override returns (string memory) {
        return _main().symbol;
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
        (uint128 diaPrice,) = _readDIAChecked();
        return _vaultSharePrice(diaPrice);
    }

    /// @inheritdoc AggregatorV2V3Interface
    /// @dev `roundId` and `answeredInRound` are derived from the DIA push
    /// `timestamp` (truncated to `uint80`) so they advance monotonically per
    /// Chainlink convention without adding storage. Integrators that diff
    /// `roundId` between calls to detect a fresh update will see a different
    /// value whenever DIA has produced a new push. The `uint80` window
    /// covers every plausible deployment lifetime.
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (uint128 diaPrice, uint128 timestamp) = _readDIAChecked();
        int256 scaledPrice = _vaultSharePrice(diaPrice);

        uint80 round = uint80(timestamp);
        return (round, scaledPrice, timestamp, timestamp, round);
    }

    /// @inheritdoc AggregatorV2V3Interface
    /// @dev DIA exposes only its latest value — no per-round history through
    /// this interface. Every call reverts with
    /// `HistoricalRoundDataUnsupported(_roundId)`. Callers needing
    /// point-in-time data should query DIA's off-chain feed history or an
    /// indexer of DIA pushes directly.
    function getRoundData(uint80 _roundId) external pure override returns (uint80, int256, uint256, uint256, uint80) {
        revert HistoricalRoundDataUnsupported(_roundId);
    }

    /// @dev Read DIA and revert on either "never pushed" (DIAPriceNotSet) or
    /// "too old" (DIAPriceStale). DIA's `getValue` returns `(0, 0)` for an
    /// unset feed rather than reverting — we must check explicitly.
    function _readDIAChecked() internal view returns (uint128 value, uint128 timestamp) {
        MainStorage storage $ = _main();
        (value, timestamp) = $.diaOracle.getValue($.symbol);
        if (value == 0 || timestamp == 0) revert DIAPriceNotSet();
        // slither-disable-next-line timestamp
        if (block.timestamp - uint256(timestamp) > $.maxAge) revert DIAPriceStale(uint256(timestamp));
    }

    /// @dev Compute vault share price from a DIA reading via Rain float math
    /// so neither operand can overflow uint256. DIA prices are 18-decimal
    /// `uint128`. The vault ratio is `totalAssets / totalSupply`. Output is
    /// 8-decimal `int256` per Chainlink `latestAnswer` convention.
    function _vaultSharePrice(uint128 diaPrice) internal view returns (int256) {
        // DIA's value is 18-decimal uint128 — pack as a float with decimal
        // count 18 to recover the natural quantity.
        Float priceFloat = LibDecimalFloat.fromFixedDecimalLosslessPacked(uint256(diaPrice), 18);

        IERC4626 vaultContract = IERC4626(_main().vault);
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
