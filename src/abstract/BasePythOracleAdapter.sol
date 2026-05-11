// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {PythStructs} from "pyth-sdk/PythStructs.sol";
import {LibDecimalFloat, Float} from "rain-math-float-0.1.1/src/lib/LibDecimalFloat.sol";
import {IERC4626} from "@openzeppelin-contracts-5.6.1/interfaces/IERC4626.sol";
import {AggregatorV2V3Interface} from "src/interface/IAggregatorV2V3.sol";
import {LibCorporateActionsPause} from "src/lib/LibCorporateActionsPause.sol";

/// @dev Error raised when the manual admin pause is active.
error OraclePausedManual();

/// @dev Error raised when an automatic corporate-action pause is active.
/// @param effectiveTime The `effectiveTime` of the action whose window is
/// currently open. When both a pending and a completed action's window
/// overlap `now`, the pending action's `effectiveTime` is reported —
/// integrators see the next event coming, not the last one done.
error OraclePausedCorporateAction(uint64 effectiveTime);

/// @dev Error raised when the conservative price (raw Pyth price minus
/// confidence interval) is not positive. The carried value is that
/// conservative price, not the raw Pyth price.
error NonPositivePrice(int256 conservativePrice);

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

/// @dev Error raised when a caller requests historical round data. Pyth-backed
/// adapters do not expose per-round history through this interface — see
/// `getRoundData`. Callers needing historical data must read from a different
/// source (Pyth's own getPriceAtPublishTime, an indexer, etc.).
error HistoricalRoundDataUnsupported(uint80 roundId);

/// @dev Error raised when `_setCorporateActionPauseConfig` is called more than
/// once. Enforces the SPEC §16.2 "immutable after initialize" invariant on the
/// four corporate-action pause storage slots so subclass discipline cannot
/// silently break it.
error CorporateActionConfigAlreadyInitialized();

/// @title CorporateActionPauseConfig
/// @notice Configuration for the corporate-action-aware auto-pause feature.
/// All fields are immutable after initialize — see SPEC § 16.2.
/// @param corporateActionsVault Address implementing `ICorporateActionsV1`.
/// May be the same as the priced `vault` if it implements the interface, or a
/// separate address (e.g. the underlying rebasing token under a wtStock
/// wrapper). Zero address disables auto-pause entirely.
/// @param actionTypeMask Bitmap of action types that trigger an auto-pause.
/// `ACTION_TYPE_STOCK_SPLIT_V1` (`1 << 1`) for splits only, or
/// `type(uint256).max` to catch every present and future action type.
/// @param pauseTimeBefore Seconds before a pending action's `effectiveTime` to
/// start pausing.
/// @param pauseTimeAfter Seconds after a completed action's `effectiveTime` to
/// keep pausing.
struct CorporateActionPauseConfig {
    address corporateActionsVault;
    uint256 actionTypeMask;
    uint64 pauseTimeBefore;
    uint64 pauseTimeAfter;
}

/// @title BasePythOracleAdapter
/// @notice Abstract base for Pyth oracle adapters that price ERC-4626 vault
/// shares. Provides shared logic for conservative pricing, vault share price
/// computation, admin/pause governance, and AggregatorV2V3Interface metadata.
/// Subclasses implement `_getPriceData()` to fetch price from Pyth (single
/// feed or multi-feed cascading).
///
/// Pause behaviour is layered:
///
/// 1. **Manual** — admin can `setPaused(true)` for emergencies. Persists
///    until `setPaused(false)`. Reverts with `OraclePausedManual()`.
/// 2. **Auto, corporate-action-aware** — driven by `ICorporateActionsV1`
///    on a configured vault. Reverts with
///    `OraclePausedCorporateAction(effectiveTime)` whenever the current
///    block is inside a configured pre- or post-window of a matching
///    scheduled or completed action. See `LibCorporateActionsPause` for the
///    exact semantics.
///
/// The two are independent and OR'd: either condition pauses the oracle.
/// Distinct errors let integrators disambiguate via static-call introspection
/// or simulation. Auto-pause configuration is set once at initialize and is
/// immutable thereafter; manual pause stays as the operational escape hatch.
abstract contract BasePythOracleAdapter is AggregatorV2V3Interface {
    /// @dev The ERC-4626 vault this oracle prices shares for.
    address public vault;
    /// @dev Manual emergency pause flag. Independent of the corporate-action
    /// auto-pause — either condition causes price reads to revert.
    bool public paused;
    /// @dev Admin address for governance actions.
    address public admin;

    /// @dev Address implementing `ICorporateActionsV1` consulted on every price
    /// read for auto-pause. Zero address disables auto-pause. Immutable after
    /// initialize — to repoint, redeploy and switch via
    /// `OracleRegistry.setOracle`.
    address public corporateActionsVault;
    /// @dev Bitmap of action types that trigger an auto-pause. Immutable.
    uint256 public actionTypeMask;
    /// @dev Seconds before a pending action's `effectiveTime` to start
    /// pausing. Immutable.
    uint64 public pauseTimeBefore;
    /// @dev Seconds after a completed action's `effectiveTime` to keep
    /// pausing. Immutable.
    uint64 public pauseTimeAfter;

    /// @dev True once `_setCorporateActionPauseConfig` has run. The four
    /// corporate-action pause slots become immutable thereafter — any second
    /// call reverts with `CorporateActionConfigAlreadyInitialized`. Subclass
    /// initializers MUST call the helper exactly once. Packed alongside
    /// `pauseTimeBefore` and `pauseTimeAfter` in the same storage slot
    /// (8 + 8 + 1 bytes ≪ 32), so the new invariant costs no extra slot.
    bool internal _corporateActionConfigInitialized;

    /// @dev Reserved storage to avoid shifting subclass slot positions when
    /// new base-class state is introduced in future versions. Decrement
    /// `__gap.length` by 1 for each `uint256`-equivalent slot added above.
    uint256[50] private __gap;

    /// @notice Emitted when the manual pause state changes.
    /// @param isPaused The new pause state.
    event PauseSet(bool isPaused);
    /// @notice Emitted when the admin is changed.
    /// @param oldAdmin The previous admin address.
    /// @param newAdmin The new admin address.
    event AdminSet(address indexed oldAdmin, address indexed newAdmin);
    /// @notice Emitted exactly once on initialize to record the corporate-action
    /// auto-pause config. Lets off-chain indexers reconstruct an oracle's
    /// full governance state from event logs alone, without per-oracle storage
    /// reads.
    /// @param corporateActionsVault Address implementing `ICorporateActionsV1`,
    /// or `address(0)` to disable auto-pause.
    /// @param actionTypeMask Bitmap of action types that trigger an auto-pause.
    /// @param pauseTimeBefore Seconds before a pending action's `effectiveTime`
    /// to start pausing.
    /// @param pauseTimeAfter Seconds after a completed action's `effectiveTime`
    /// to keep pausing.
    event CorporateActionPauseConfigSet(
        address corporateActionsVault, uint256 actionTypeMask, uint64 pauseTimeBefore, uint64 pauseTimeAfter
    );

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
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
    // slither-disable-next-line pyth-unchecked-confidence
    function latestAnswer() external view override returns (int256) {
        _validateNotPaused();
        // Confidence is checked in _vaultSharePrice -> _conservativePriceFloat
        PythStructs.Price memory priceData = _getPriceData();
        return _vaultSharePrice(priceData);
    }

    /// @inheritdoc AggregatorV2V3Interface
    /// @dev `roundId` and `answeredInRound` are derived from the Pyth
    /// `publishTime` (truncated to `uint80`) so they advance monotonically per
    /// Chainlink convention without adding storage. Integrators that diff
    /// `roundId` between calls to detect a fresh update will see a different
    /// value whenever Pyth has produced a new price. The truncation collision
    /// is far in the future — `uint80` covers more seconds than any plausible
    /// deployment lifetime.
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

        uint80 publishRoundId = uint80(uint64(priceData.publishTime));
        return (
            publishRoundId,
            scaledPrice,
            uint256(uint64(priceData.publishTime)),
            uint256(uint64(priceData.publishTime)),
            publishRoundId
        );
    }

    /// @inheritdoc AggregatorV2V3Interface
    /// @dev Pyth does not expose historical rounds via this interface — every
    /// call reverts with `HistoricalRoundDataUnsupported(_roundId)`. Callers
    /// needing point-in-time data should use Pyth's `getPriceAtPublishTime`
    /// directly or query an indexer.
    function getRoundData(uint80 _roundId) external pure override returns (uint80, int256, uint256, uint256, uint80) {
        revert HistoricalRoundDataUnsupported(_roundId);
    }

    /// @notice Pause or unpause the oracle's manual flag. Admin only.
    /// @dev Independent of the corporate-action auto-pause; either condition
    /// causes price reads to revert.
    /// @param isPaused True to pause, false to unpause.
    function setPaused(bool isPaused) external onlyAdmin {
        paused = isPaused;
        emit PauseSet(isPaused);
    }

    /// @notice Update the admin address. Admin only.
    /// @dev One-step transfer — the new admin takes effect immediately. A
    /// wrong `newAdmin` will lock the adapter's governance permanently:
    /// `setPaused` will become uncallable. The only recovery is to redeploy
    /// the oracle and `OracleRegistry.setOracle(vault, newOracle)` to
    /// redirect downstream protocols. Use a multisig that cannot be
    /// misaddressed.
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

    /// @dev Reverts if either pause condition is currently active. Manual
    /// pause is checked first because it is cheaper (single SLOAD) — when an
    /// admin has explicitly set the manual flag we want that error returned,
    /// not the corporate-action one.
    function _validateNotPaused() internal view {
        if (paused) revert OraclePausedManual();
        (bool autoPaused, uint64 effectiveTime) = LibCorporateActionsPause.inPauseWindow(
            corporateActionsVault, actionTypeMask, pauseTimeBefore, pauseTimeAfter
        );
        if (autoPaused) revert OraclePausedCorporateAction(effectiveTime);
    }

    /// @dev Subclass initializers call this exactly once to install the
    /// corporate-action auto-pause config. All four fields may be zero —
    /// `corporateActionsVault == address(0)` disables auto-pause for the
    /// life of the proxy and is the right choice when an oracle is
    /// redeployed against a vault that hasn't yet been upgraded to expose
    /// `ICorporateActionsV1`. Reverts with
    /// `CorporateActionConfigAlreadyInitialized` if called a second time —
    /// the four corporate-action pause slots are SPEC §16.2 immutable.
    /// Emits `CorporateActionPauseConfigSet` so off-chain indexers can
    /// reconstruct the config from logs alone.
    function _setCorporateActionPauseConfig(CorporateActionPauseConfig memory config) internal {
        if (_corporateActionConfigInitialized) revert CorporateActionConfigAlreadyInitialized();
        _corporateActionConfigInitialized = true;
        corporateActionsVault = config.corporateActionsVault;
        actionTypeMask = config.actionTypeMask;
        pauseTimeBefore = config.pauseTimeBefore;
        pauseTimeAfter = config.pauseTimeAfter;
        emit CorporateActionPauseConfigSet(
            config.corporateActionsVault, config.actionTypeMask, config.pauseTimeBefore, config.pauseTimeAfter
        );
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
