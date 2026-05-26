// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {IPyth} from "pyth-sdk/IPyth.sol";
import {PythStructs} from "pyth-sdk/PythStructs.sol";
import {LibPyth} from "rain-pyth-0.0.0-git/src/lib/pyth/LibPyth.sol";
import {ICLONEABLE_V2_SUCCESS, ICloneableV2} from "rain-factory-0.1.1/src/interface/ICloneableV2.sol";
import {Initializable} from "@openzeppelin-contracts-5.6.1/proxy/utils/Initializable.sol";
import {BasePythOracleAdapter, ZeroVault, ZeroAdmin} from "src/abstract/BasePythOracleAdapter.sol";

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
/// @param admin The admin address for governance.
struct MultiPythOracleAdapterConfig {
    address vault;
    FeedConfig[] feeds;
    address admin;
}

/// @title MultiPythOracleAdapter
/// @notice Oracle adapter that prices ERC-4626 vault shares by trying multiple
/// Pyth price feeds in order, returning the first non-stale price. This gives
/// near 24/7 coverage for equities with separate feeds for regular, pre-market,
/// post-market, and overnight sessions.
///
/// Same external interface as PythOracleAdapter (AggregatorV3Interface).
/// Each feed has its own maxAge since update frequency varies by session.
///
/// Price formula: vaultSharePrice = pythPrice * totalAssets / totalSupply
contract MultiPythOracleAdapter is BasePythOracleAdapter, ICloneableV2, Initializable {
    /// @dev Number of configured feeds.
    uint256 public feedCount;
    /// @dev Feed configurations indexed by position.
    mapping(uint256 => FeedConfig) internal _feeds;

    /// @dev Emitted when the oracle is initialized.
    event MultiPythOracleAdapterInitialized(address indexed sender, MultiPythOracleAdapterConfig config);
    /// @dev Emitted when feeds are updated.
    event FeedsSet(FeedConfig[] feeds);
    /// @dev Emitted when a single feed's maxAge is updated.
    event FeedMaxAgeSet(uint256 index, uint256 maxAge);

    constructor() {
        _disableInitializers();
    }

    /// As per ICloneableV2, this overload MUST always revert. Documents the
    /// signature of the initialize function.
    /// @param config The initialization configuration.
    function initialize(MultiPythOracleAdapterConfig memory config) external pure returns (bytes32) {
        (config);
        revert InitializeSignatureFn();
    }

    /// @inheritdoc ICloneableV2
    function initialize(bytes calldata data) external initializer returns (bytes32) {
        MultiPythOracleAdapterConfig memory config = abi.decode(data, (MultiPythOracleAdapterConfig));

        if (config.vault == address(0)) revert ZeroVault();
        if (config.admin == address(0)) revert ZeroAdmin();
        if (config.feeds.length == 0) revert ZeroFeeds();
        if (config.feeds.length > MAX_FEEDS) revert TooManyFeeds();

        vault = config.vault;
        admin = config.admin;

        _setFeeds(config.feeds);

        emit MultiPythOracleAdapterInitialized(msg.sender, config);

        return ICLONEABLE_V2_SUCCESS;
    }

    /// @notice Update the entire feed list. Admin only.
    /// @param feeds The new ordered feed configurations.
    function setFeeds(FeedConfig[] calldata feeds) external onlyAdmin {
        if (feeds.length == 0) revert ZeroFeeds();
        if (feeds.length > MAX_FEEDS) revert TooManyFeeds();
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

    /// @dev Attempts to get a price from Pyth, returning success flag.
    /// Extracted to avoid slither's pyth-unchecked-confidence detector
    /// crashing on try/catch with Pyth calls (slither bug).
    /// Confidence IS checked downstream in _conservativePriceFloat.
    // slither-disable-next-line pyth-unchecked-confidence,calls-loop
    function _tryGetPrice(IPyth pyth, bytes32 feedPriceId, uint256 feedMaxAge)
        internal
        view
        returns (bool success, PythStructs.Price memory price)
    {
        try pyth.getPriceNoOlderThan(feedPriceId, feedMaxAge) returns (PythStructs.Price memory p) {
            return (true, p);
        } catch {
            return (false, price);
        }
    }

    /// @dev Internal feed setter. Validates and stores feeds.
    function _setFeeds(FeedConfig[] memory feeds) internal {
        uint256 oldCount = feedCount;
        for (uint256 i = feeds.length; i < oldCount; i++) {
            delete _feeds[i];
        }

        feedCount = feeds.length;
        for (uint256 i = 0; i < feeds.length; i++) {
            if (feeds[i].priceId == bytes32(0)) revert ZeroPriceId(i);
            if (feeds[i].maxAge == 0) revert ZeroMaxAge(i);
            _feeds[i] = feeds[i];
        }
    }
}
