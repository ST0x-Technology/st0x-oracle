// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {IPyth} from "pyth-sdk/IPyth.sol";
import {PythErrors} from "pyth-sdk/PythErrors.sol";
import {PythStructs} from "pyth-sdk/PythStructs.sol";
import {LibPyth} from "rain.pyth/src/lib/pyth/LibPyth.sol";
import {ICLONEABLE_V2_SUCCESS, ICloneableV2} from "rain.factory/interface/ICloneableV2.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {
    BasePythOracleAdapter,
    CorporateActionPauseConfig,
    ZeroVault,
    ZeroAdmin
} from "src/abstract/BasePythOracleAdapter.sol";

/// @dev Error raised when all feeds are stale.
error AllFeedsStale();

/// @dev Error raised when no feeds are provided.
error ZeroFeeds();

/// @dev Error raised when too many feeds are provided.
error TooManyFeeds();

/// @dev Error raised when feed index is out of bounds.
error FeedIndexOutOfBounds(uint256 index, uint256 length);

/// @dev Error raised when a zero price ID is provided for a feed.
error ZeroPriceId(uint256 index);

/// @dev Error raised when a zero max age is provided for a feed.
error ZeroMaxAge(uint256 index);

/// @dev Maximum number of feeds allowed.
uint256 constant MAX_FEEDS = 8;

/// @title FeedConfig
/// @notice Configuration for a single Pyth price feed.
/// @param priceId The Pyth price feed ID.
/// @param maxAge Maximum acceptable price age in seconds.
struct FeedConfig {
    bytes32 priceId;
    uint256 maxAge;
}

/// @title MultiPythOracleAdapterConfig
/// @notice Configuration for MultiPythOracleAdapter initialization.
/// @param vault The ERC-4626 vault address this oracle prices shares for.
/// @param feeds Ordered list of feed configurations (tried in order).
/// MUTABLE post-init via admin's `setFeeds` / `setMaxAge`.
/// @param admin The admin address for governance.
/// @param pauseConfig Corporate-action auto-pause config — see SPEC § 16.
/// All-zero is the legacy/manual-only mode; `corporateActionsVault =
/// address(0)` disables auto-pause for the life of the proxy.
struct MultiPythOracleAdapterConfig {
    address vault;
    FeedConfig[] feeds;
    address admin;
    CorporateActionPauseConfig pauseConfig;
}

/// @title MultiPythOracleAdapter
/// @notice Oracle adapter that prices ERC-4626 vault shares by trying multiple
/// Pyth price feeds in order, returning the first non-stale price. This gives
/// near 24/7 coverage for equities with separate feeds for regular, pre-market,
/// post-market, and overnight sessions.
///
/// **Mutability divergence from PythOracleAdapter.** Unlike the single-feed
/// sibling, the feed list and per-feed maxAge are mutable post-init under
/// admin (`setFeeds`, `setMaxAge`) so per-session feed retuning does not
/// require a new proxy + registry switch. Vault, admin, and corporate-action
/// pause config remain immutable per SPEC §16.2 and the BeaconSetDeployer
/// pattern.
///
/// Same external interface as PythOracleAdapter (AggregatorV2V3Interface).
/// Each feed has its own maxAge since update frequency varies by session.
///
/// Price formula: vaultSharePrice = (pythPrice - pythConfidence) * totalAssets / totalSupply
/// — i.e. the conservative price is used. See SPEC §15.2 and
/// `BasePythOracleAdapter._conservativePriceFloat`.
contract MultiPythOracleAdapter is BasePythOracleAdapter, ICloneableV2, Initializable {
    /// @dev Number of configured feeds.
    uint256 public feedCount;
    /// @dev Feed configurations indexed by position.
    mapping(uint256 => FeedConfig) internal _feeds;

    /// @notice Emitted when the oracle is initialized.
    /// @param sender The caller that initialized the proxy.
    /// @param config The initialization configuration.
    event MultiPythOracleAdapterInitialized(address indexed sender, MultiPythOracleAdapterConfig config);
    /// @notice Emitted when feeds are updated.
    /// @param feeds The new ordered feed configurations.
    event FeedsSet(FeedConfig[] feeds);
    /// @notice Emitted when a single feed's maxAge is updated.
    /// @param index The feed index whose maxAge changed.
    /// @param maxAge The new maxAge value in seconds.
    event FeedMaxAgeSet(uint256 index, uint256 maxAge);

    constructor() {
        _disableInitializers();
    }

    /// @notice Documents the typed signature of the initialize function. Per
    /// ICloneableV2 this overload MUST always revert; callers should use the
    /// `bytes calldata` overload instead.
    /// @dev Always reverts with `InitializeSignatureFn`.
    /// @param config The initialization configuration. Ignored.
    /// @return Never returns; included only for the function signature.
    function initialize(MultiPythOracleAdapterConfig memory config) external pure returns (bytes32) {
        (config);
        revert InitializeSignatureFn();
    }

    /// @inheritdoc ICloneableV2
    function initialize(bytes calldata data) external initializer returns (bytes32) {
        MultiPythOracleAdapterConfig memory config = abi.decode(data, (MultiPythOracleAdapterConfig));

        if (config.vault == address(0)) revert ZeroVault();
        if (config.admin == address(0)) revert ZeroAdmin();

        vault = config.vault;
        admin = config.admin;

        _setFeeds(config.feeds);
        _setCorporateActionPauseConfig(config.pauseConfig);

        emit MultiPythOracleAdapterInitialized(msg.sender, config);

        return ICLONEABLE_V2_SUCCESS;
    }

    /// @notice Update the entire feed list. Admin only.
    /// @param feeds The new ordered feed configurations.
    function setFeeds(FeedConfig[] calldata feeds) external onlyAdmin {
        _setFeeds(feeds);
        emit FeedsSet(feeds);
    }

    /// @notice Update maxAge for a specific feed. Admin only.
    /// @param index The feed index.
    /// @param newMaxAge The new maxAge value.
    function setMaxAge(uint256 index, uint256 newMaxAge) external onlyAdmin {
        if (index >= feedCount) revert FeedIndexOutOfBounds(index, feedCount);
        if (newMaxAge == 0) revert ZeroMaxAge(index);
        _feeds[index].maxAge = newMaxAge;
        emit FeedMaxAgeSet(index, newMaxAge);
    }

    /// @notice Get feed configuration at a specific index.
    /// @param index The feed index.
    /// @return The feed configuration.
    function getFeed(uint256 index) external view returns (FeedConfig memory) {
        if (index >= feedCount) revert FeedIndexOutOfBounds(index, feedCount);
        return _feeds[index];
    }

    /// @notice Get all feed configurations.
    /// @return feeds Array of all feed configurations.
    function getFeeds() external view returns (FeedConfig[] memory feeds) {
        feeds = new FeedConfig[](feedCount);
        for (uint256 i = 0; i < feedCount; i++) {
            feeds[i] = _feeds[i];
        }
    }

    /// @inheritdoc BasePythOracleAdapter
    // Slither false positives:
    // - pyth-unchecked-confidence: confidence is checked downstream in
    //   _conservativePriceFloat (price - conf).
    // - calls-inside-a-loop: intentional cascading design — max 8 iterations,
    //   each calling the immutable Pyth contract. Not a reentrancy risk.
    // slither-disable-next-line calls-loop
    function _getPriceData() internal view override returns (PythStructs.Price memory) {
        IPyth pyth = LibPyth.getPriceFeedContract(block.chainid);
        uint256 count = feedCount;

        for (uint256 i = 0; i < count; i++) {
            FeedConfig memory feed = _feeds[i];
            (bool success, PythStructs.Price memory price) = _tryGetPrice(pyth, feed.priceId, feed.maxAge);
            if (success) {
                return price;
            }
        }

        revert AllFeedsStale();
    }

    /// @dev Attempts to get a price from Pyth.
    /// Returns `success = true` when Pyth returns a price. Returns
    /// `success = false` **only** for `PythErrors.StalePrice()` — the
    /// signal to try the next session feed. All other reverts
    /// (e.g. `PriceFeedNotFound` for a misconfigured priceId, OOG, governance
    /// guards) propagate so configuration errors fail loudly instead of
    /// being silently absorbed into the cascade. Confidence is checked
    /// downstream in `_conservativePriceFloat`.
    ///
    /// Slither suppression notes:
    /// - `pyth-unchecked-confidence`: confidence IS checked downstream.
    /// - `calls-loop`: intentional cascading design — max 8 iterations,
    ///   each calling the immutable Pyth contract. Not a reentrancy risk.
    // slither-disable-next-line pyth-unchecked-confidence,calls-loop
    function _tryGetPrice(IPyth pyth, bytes32 feedPriceId, uint256 feedMaxAge)
        internal
        view
        returns (bool success, PythStructs.Price memory price)
    {
        try pyth.getPriceNoOlderThan(feedPriceId, feedMaxAge) returns (PythStructs.Price memory p) {
            return (true, p);
        } catch (bytes memory reason) {
            // Only StalePrice falls through to the next session feed.
            // Anything else (PriceFeedNotFound, OOG, etc.) bubbles up.
            if (reason.length == 4 && bytes4(reason) == PythErrors.StalePrice.selector) {
                return (false, price);
            }
            // Re-raise the original revert preserving its selector + data.
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
    }

    /// @dev Internal feed setter. Validates every entry and the length bounds
    /// up front, then mutates storage. The validate-then-mutate ordering means
    /// a bad input never partially clobbers existing feeds — important even
    /// though Solidity reverts roll back state today, because it keeps the
    /// helper composable into future delegatecall / multi-call contexts where
    /// partial reverts would otherwise leak. Length checks are folded in so
    /// `initialize` and `setFeeds` become thin wrappers and any future internal
    /// caller is also bound by `MAX_FEEDS` / non-empty.
    function _setFeeds(FeedConfig[] memory feeds) internal {
        // Validate length bounds first.
        if (feeds.length == 0) revert ZeroFeeds();
        if (feeds.length > MAX_FEEDS) revert TooManyFeeds();

        // Validate each entry before any storage write.
        for (uint256 i = 0; i < feeds.length; i++) {
            if (feeds[i].priceId == bytes32(0)) revert ZeroPriceId(i);
            if (feeds[i].maxAge == 0) revert ZeroMaxAge(i);
        }

        // Mutate: clear tail of old entries that no longer fit, then write new
        // entries, then update `feedCount` last so an external reader can
        // never observe a length without its slot also populated.
        uint256 oldCount = feedCount;
        for (uint256 i = feeds.length; i < oldCount; i++) {
            delete _feeds[i];
        }

        for (uint256 i = 0; i < feeds.length; i++) {
            _feeds[i] = feeds[i];
        }

        feedCount = feeds.length;
    }
}
