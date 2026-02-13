// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {IPyth} from "pyth-sdk/IPyth.sol";
import {PythStructs} from "pyth-sdk/PythStructs.sol";
import {LibPyth} from "rain.pyth/src/lib/pyth/LibPyth.sol";
import {LibDecimalFloat, Float} from "rain.math.float/lib/LibDecimalFloat.sol";
import {ICLONEABLE_V2_SUCCESS, ICloneableV2} from "rain.factory/interface/ICloneableV2.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {AggregatorV3Interface} from "src/interface/IAggregatorV3.sol";

/// @dev Error raised when the oracle is paused.
error MultiOraclePaused();

/// @dev Error raised when the conservative price (price - confidence) is not
/// positive.
error MultiNonPositivePrice(int256 price);

/// @dev Error raised when a zero address is provided for the vault.
error MultiZeroVault();

/// @dev Error raised when a zero max age is provided for any feed.
error MultiZeroMaxAge(uint256 index);

/// @dev Error raised when a zero price ID is provided for any feed.
error MultiZeroPriceId(uint256 index);

/// @dev Error raised when the caller is not the admin.
error MultiOnlyAdmin();

/// @dev Error raised when a zero address is provided for the admin.
error MultiZeroAdmin();

/// @dev Error raised when the vault has zero total supply (no shares minted).
error MultiZeroVaultSupply();

/// @dev Error raised when the computed vault share price is zero.
error MultiZeroVaultSharePrice();

/// @dev Error raised when all feeds are stale.
error AllFeedsStale();

/// @dev Error raised when no feeds are provided.
error ZeroFeeds();

/// @dev Error raised when too many feeds are provided.
error TooManyFeeds();

/// @dev Error raised when feed index is out of bounds.
error FeedIndexOutOfBounds(uint256 index, uint256 length);

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
contract MultiPythOracleAdapter is AggregatorV3Interface, ICloneableV2, Initializable {
    /// @dev The ERC-4626 vault this oracle prices shares for.
    address public vault;
    /// @dev Emergency pause flag.
    bool public paused;
    /// @dev Admin address for governance actions.
    address public admin;
    /// @dev Number of configured feeds.
    uint256 public feedCount;
    /// @dev Feed configurations indexed by position.
    mapping(uint256 => FeedConfig) internal _feeds;

    /// @dev Emitted when the oracle is initialized.
    event MultiPythOracleAdapterInitialized(address indexed sender, MultiPythOracleAdapterConfig config);
    /// @dev Emitted when the pause state changes.
    event PauseSet(bool isPaused);
    /// @dev Emitted when the admin is changed.
    event AdminSet(address indexed oldAdmin, address indexed newAdmin);
    /// @dev Emitted when feeds are updated.
    event FeedsSet(FeedConfig[] feeds);
    /// @dev Emitted when a single feed's maxAge is updated.
    event FeedMaxAgeSet(uint256 index, uint256 maxAge);
    /// @dev Emitted indicating which feed index was used for the price.
    event FeedUsed(uint256 index, bytes32 priceId);

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

        if (config.vault == address(0)) revert MultiZeroVault();
        if (config.admin == address(0)) revert MultiZeroAdmin();
        if (config.feeds.length == 0) revert ZeroFeeds();
        if (config.feeds.length > MAX_FEEDS) revert TooManyFeeds();

        vault = config.vault;
        admin = config.admin;

        _setFeeds(config.feeds);

        emit MultiPythOracleAdapterInitialized(msg.sender, config);

        return ICLONEABLE_V2_SUCCESS;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert MultiOnlyAdmin();
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

        (, PythStructs.Price memory priceData) = _getFirstValidPrice();
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

        (, PythStructs.Price memory priceData) = _getFirstValidPrice();
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
        if (newAdmin == address(0)) revert MultiZeroAdmin();
        emit AdminSet(admin, newAdmin);
        admin = newAdmin;
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
        if (newMaxAge == 0) revert MultiZeroMaxAge(index);
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

    /// @dev Internal feed setter. Validates and stores feeds.
    function _setFeeds(FeedConfig[] memory feeds) internal {
        // Clear old feeds if any exist beyond new length.
        uint256 oldCount = feedCount;
        for (uint256 i = feeds.length; i < oldCount; i++) {
            delete _feeds[i];
        }

        feedCount = feeds.length;
        for (uint256 i = 0; i < feeds.length; i++) {
            if (feeds[i].priceId == bytes32(0)) revert MultiZeroPriceId(i);
            if (feeds[i].maxAge == 0) revert MultiZeroMaxAge(i);
            _feeds[i] = feeds[i];
        }
    }

    /// @dev Iterate feeds in order, return the first non-stale price.
    /// Reverts with AllFeedsStale if no feed returns a valid price.
    // Slither false positives:
    // - pyth-unchecked-confidence: confidence is checked downstream in
    //   _conservativeScaledPrice (price - conf).
    // - calls-inside-a-loop: intentional cascading design — max 8 iterations,
    //   each calling the immutable Pyth contract. Not a reentrancy risk.
    // slither-disable-next-line calls-loop
    function _getFirstValidPrice() internal view returns (uint256 feedIndex, PythStructs.Price memory priceData) {
        IPyth pyth = LibPyth.getPriceFeedContract(block.chainid);
        uint256 count = feedCount;

        for (uint256 i = 0; i < count; i++) {
            FeedConfig memory feed = _feeds[i];
            // slither-disable-next-line pyth-unchecked-confidence
            try pyth.getPriceNoOlderThan(feed.priceId, feed.maxAge) returns (PythStructs.Price memory price) {
                return (i, price);
            } catch {
                continue;
            }
        }

        revert AllFeedsStale();
    }

    /// @dev Reverts if the oracle is paused.
    function _validateNotPaused() internal view {
        if (paused) revert MultiOraclePaused();
    }

    /// @dev Computes conservative price (price - confidence) and scales to 8
    /// decimals using LibDecimalFloat.
    function _conservativeScaledPrice(PythStructs.Price memory priceData) internal pure returns (int256) {
        // slither-disable-next-line pyth-unchecked-confidence
        int256 conservativePrice = int256(priceData.price) - int256(uint256(priceData.conf));
        if (conservativePrice <= 0) {
            revert MultiNonPositivePrice(conservativePrice);
        }
        Float conservativePriceFloat = LibDecimalFloat.packLossless(conservativePrice, int256(priceData.expo));
        //slither-disable-next-line unused-return
        (uint256 price8,) = LibDecimalFloat.toFixedDecimalLossy(conservativePriceFloat, 8);
        return int256(price8);
    }

    /// @dev Computes the vault share price.
    function _vaultSharePrice(PythStructs.Price memory priceData) internal view returns (int256) {
        int256 price8 = _conservativeScaledPrice(priceData);

        IERC4626 vaultContract = IERC4626(vault);
        uint256 totalAssets = vaultContract.totalAssets();
        uint256 totalSupply = vaultContract.totalSupply();

        if (totalSupply == 0) revert MultiZeroVaultSupply();

        int256 vaultSharePrice = int256(uint256(price8) * totalAssets / totalSupply);

        if (vaultSharePrice == 0) revert MultiZeroVaultSharePrice();

        return vaultSharePrice;
    }
}
