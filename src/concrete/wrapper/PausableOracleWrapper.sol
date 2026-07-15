// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {AggregatorV2V3Interface} from "../../interface/IAggregatorV2V3.sol";
import {LibCorporateActionsPause} from "../../lib/LibCorporateActionsPause.sol";
import {ICLONEABLE_V2_SUCCESS, ICloneableV2} from "rain-factory-0.1.1/src/interface/ICloneableV2.sol";
import {Initializable} from "@openzeppelin-contracts-5.6.1/proxy/utils/Initializable.sol";

/// @dev Error raised when the manual admin pause is active.
error OraclePausedManual();

/// @dev Error raised when an automatic corporate-action pause is active.
/// @param effectiveTime The `effectiveTime` of the action whose window is
/// currently open. When both a pending and a completed action's window
/// overlap `now`, the pending action's `effectiveTime` is reported —
/// integrators see the next event coming, not the last one done.
error OraclePausedCorporateAction(uint64 effectiveTime);

/// @dev Error raised when a zero address is provided for the upstream oracle.
error ZeroUpstream();

/// @dev Error raised when the caller is not the admin.
error OnlyAdmin();

/// @dev Error raised when a zero address is provided for the admin. A zero
/// admin would permanently lock governance: `setPaused` becomes uncallable
/// and the wrapper cannot be unpaused. Better to fail loud at init than to
/// silently mint a broken oracle.
error ZeroAdmin();

/// @dev Error raised when the corporate-action pause config is internally
/// inconsistent. Auto-pause must be either coherently ENABLED (vault + mask +
/// at least one non-zero window) or coherently DISABLED (all four fields
/// zero). Any partial shape (e.g. a vault with a zero mask, or a vault + mask
/// with both windows zero) silently never pauses — the exact failure the
/// feature exists to prevent — so reject it at init instead of minting a
/// wrapper whose auto-pause is dead.
error InvalidPauseConfig();

/// @title CorporateActionPauseConfig
/// @notice Configuration for the corporate-action-aware auto-pause feature.
/// All fields are immutable after initialize.
/// @param corporateActionsVault Address implementing `ICorporateActionsV1`.
/// May be the same as the priced vault if it implements the interface, or a
/// separate address (e.g. the underlying rebasing token under a wtStock
/// wrapper). Zero address disables auto-pause entirely.
/// @param actionTypeMask Bitmap of action types that trigger an auto-pause.
/// `ACTION_TYPE_STOCK_SPLIT_V1` (`1 << 1`) for splits only, or
/// `type(uint256).max` to catch every present and future action type.
/// @param pauseTimeBefore Seconds before a pending action's `effectiveTime`
/// to start pausing.
/// @param pauseTimeAfter Seconds after a completed action's `effectiveTime`
/// to keep pausing.
struct CorporateActionPauseConfig {
    address corporateActionsVault;
    uint256 actionTypeMask;
    uint64 pauseTimeBefore;
    uint64 pauseTimeAfter;
}

/// @title PausableOracleWrapperConfig
/// @notice Configuration for `PausableOracleWrapper.initialize`.
/// @param admin The governance address with rights to toggle the manual pause
/// and transfer admin. Cannot be zero.
/// @param upstream The wrapped oracle. Any `AggregatorV2V3Interface` works —
/// `ChronicleVaultOracle`, a raw Chainlink feed, another adapter. Immutable
/// after init: redeploy and migrate consumers to swap.
/// @param pauseConfig Corporate-action auto-pause config. All-zero disables
/// auto-pause for the life of the proxy.
struct PausableOracleWrapperConfig {
    address admin;
    AggregatorV2V3Interface upstream;
    CorporateActionPauseConfig pauseConfig;
}

/// @title PausableOracleWrapper
/// @notice A pure-decorator wrapper that adds operational pause semantics on
/// top of any `AggregatorV2V3Interface` oracle. Decimals, description, and
/// version are delegated transparently to the upstream so the wrapper is
/// shape-preserving — consumers can drop it in wherever they'd otherwise
/// drop the upstream and get pause-awareness for free.
///
/// Pause behaviour is layered:
///
/// 1. **Manual** — admin can `setPaused(true)` for emergencies. Persists
///    until `setPaused(false)`. Reverts with `OraclePausedManual()`.
/// 2. **Auto, corporate-action-aware** — driven by `ICorporateActionsV1` on
///    a configured vault. Reverts with `OraclePausedCorporateAction(t)`
///    whenever the current block is inside the configured pre- or post-window
///    of a matching scheduled or completed action. See
///    `LibCorporateActionsPause` for the exact semantics.
///
/// The two are independent and OR'd: either condition pauses the oracle.
/// Distinct error selectors let integrators disambiguate via static-call
/// introspection. Auto-pause configuration is set once at initialize and is
/// immutable thereafter; manual pause stays as the operational escape hatch.
///
/// Deployed as a beacon-proxy clone via `ICloneableV2.initialize`.
contract PausableOracleWrapper is AggregatorV2V3Interface, ICloneableV2, Initializable {
    /// @custom:storage-location erc7201:st0x.pausableoraclewrapper.main
    struct MainStorage {
        // Governance address.
        address admin;
        // Manual emergency pause flag. Independent of corporate-action
        // auto-pause — either condition causes price reads to revert.
        bool paused;
        // The wrapped oracle. Immutable after init.
        AggregatorV2V3Interface upstream;
        // Address implementing `ICorporateActionsV1` consulted on every price
        // read for auto-pause. Zero address disables auto-pause. Immutable.
        address corporateActionsVault;
        // Bitmap of action types that trigger an auto-pause. Immutable.
        uint256 actionTypeMask;
        // Seconds before a pending action's `effectiveTime` to start pausing.
        // Immutable.
        uint64 pauseTimeBefore;
        // Seconds after a completed action's `effectiveTime` to keep pausing.
        // Immutable.
        uint64 pauseTimeAfter;
    }

    // keccak256(abi.encode(uint256(keccak256("st0x.pausableoraclewrapper.main")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MAIN_STORAGE_LOCATION = 0x3bf9f07749a1b9ca296211065904d5a319fee3811030efb4609952e7a2384800;

    function _main() private pure returns (MainStorage storage $) {
        assembly ("memory-safe") {
            $.slot := MAIN_STORAGE_LOCATION
        }
    }

    /// @notice Emitted when the manual pause state changes.
    /// @param isPaused The new pause state.
    event PauseSet(bool isPaused);

    /// @notice Emitted when the admin is changed.
    /// @param oldAdmin The previous admin address.
    /// @param newAdmin The new admin address.
    event AdminSet(address indexed oldAdmin, address indexed newAdmin);

    /// @notice Emitted exactly once on initialize. Single source of truth for
    /// off-chain indexers — all immutable config in one event.
    /// @param sender The caller that initialized the proxy.
    /// @param config The initialization configuration.
    event PausableOracleWrapperInitialized(address indexed sender, PausableOracleWrapperConfig config);

    modifier onlyAdmin() {
        if (msg.sender != _main().admin) revert OnlyAdmin();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /// @notice Governance address.
    function admin() public view returns (address) {
        return _main().admin;
    }

    /// @notice Manual emergency pause flag.
    function paused() public view returns (bool) {
        return _main().paused;
    }

    /// @notice The wrapped oracle.
    function upstream() public view returns (AggregatorV2V3Interface) {
        return _main().upstream;
    }

    /// @notice Address implementing `ICorporateActionsV1` consulted for
    /// auto-pause; zero disables it.
    function corporateActionsVault() public view returns (address) {
        return _main().corporateActionsVault;
    }

    /// @notice Bitmap of action types that trigger an auto-pause.
    function actionTypeMask() public view returns (uint256) {
        return _main().actionTypeMask;
    }

    /// @notice Seconds before a pending action's `effectiveTime` to pause.
    function pauseTimeBefore() public view returns (uint64) {
        return _main().pauseTimeBefore;
    }

    /// @notice Seconds after a completed action's `effectiveTime` to pause.
    function pauseTimeAfter() public view returns (uint64) {
        return _main().pauseTimeAfter;
    }

    /// @notice Documents the typed signature of the initialize function. Per
    /// `ICloneableV2` this overload MUST always revert; callers use the
    /// `bytes calldata` overload below.
    /// @dev Always reverts with `InitializeSignatureFn`.
    /// @param config The initialization configuration. Ignored.
    /// @return Never returns; included only for the function signature.
    function initialize(PausableOracleWrapperConfig memory config) external pure returns (bytes32) {
        (config);
        revert InitializeSignatureFn();
    }

    /// @inheritdoc ICloneableV2
    function initialize(bytes calldata data) external initializer returns (bytes32) {
        PausableOracleWrapperConfig memory config = abi.decode(data, (PausableOracleWrapperConfig));

        if (config.admin == address(0)) revert ZeroAdmin();
        if (address(config.upstream) == address(0)) revert ZeroUpstream();

        CorporateActionPauseConfig memory pause = config.pauseConfig;
        bool vaultSet = pause.corporateActionsVault != address(0);
        bool maskSet = pause.actionTypeMask != 0;
        bool windowSet = pause.pauseTimeBefore != 0 || pause.pauseTimeAfter != 0;
        // Coherent config only: all-off, or vault + mask + at least one window.
        // Anything in between is a dead auto-pause masquerading as enabled.
        bool enabled = vaultSet && maskSet && windowSet;
        bool disabled = !vaultSet && !maskSet && !windowSet;
        if (!enabled && !disabled) revert InvalidPauseConfig();

        // When enabled, probe the vault once so an incompatible wiring — a
        // missing corporate-actions facet (ABI-decode revert) or a mask with
        // no bits in the upstream VALID_ACTION_TYPES_MASK (InvalidMask) —
        // reverts THIS deploy transaction rather than every future consumer
        // read against an immutable, unrecoverable config.
        if (enabled) {
            // slither-disable-next-line unused-return
            LibCorporateActionsPause.inPauseWindow(
                pause.corporateActionsVault, pause.actionTypeMask, pause.pauseTimeBefore, pause.pauseTimeAfter
            );
        }

        MainStorage storage $ = _main();
        $.admin = config.admin;
        $.upstream = config.upstream;
        $.corporateActionsVault = pause.corporateActionsVault;
        $.actionTypeMask = pause.actionTypeMask;
        $.pauseTimeBefore = pause.pauseTimeBefore;
        $.pauseTimeAfter = pause.pauseTimeAfter;

        emit PausableOracleWrapperInitialized(msg.sender, config);

        return ICLONEABLE_V2_SUCCESS;
    }

    /// @inheritdoc AggregatorV2V3Interface
    /// @dev Delegated to upstream — wrapping is shape-preserving.
    function decimals() external view override returns (uint8) {
        return _main().upstream.decimals();
    }

    /// @inheritdoc AggregatorV2V3Interface
    /// @dev Delegated to upstream — wrapping is shape-preserving.
    function description() external view override returns (string memory) {
        return _main().upstream.description();
    }

    /// @inheritdoc AggregatorV2V3Interface
    /// @dev Delegated to upstream — wrapping is shape-preserving.
    function version() external view override returns (uint256) {
        return _main().upstream.version();
    }

    /// @inheritdoc AggregatorV2V3Interface
    function latestAnswer() external view override returns (int256) {
        _validateNotPaused();
        return _main().upstream.latestAnswer();
    }

    /// @inheritdoc AggregatorV2V3Interface
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        _validateNotPaused();
        // slither-disable-next-line unused-return
        return _main().upstream.latestRoundData();
    }

    /// @inheritdoc AggregatorV2V3Interface
    /// @dev Pause-gated as well — historical data must not leak during a
    /// corporate-action window. Upstream may further reject the call (e.g.
    /// `ChronicleVaultOracle` always reverts `HistoricalRoundDataUnsupported`).
    function getRoundData(uint80 _roundId)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        _validateNotPaused();
        // slither-disable-next-line unused-return
        return _main().upstream.getRoundData(_roundId);
    }

    /// @notice Pause or unpause the wrapper's manual flag. Admin only.
    /// @dev Independent of the corporate-action auto-pause; either condition
    /// causes price reads to revert.
    /// @param isPaused True to pause, false to unpause.
    function setPaused(bool isPaused) external onlyAdmin {
        _main().paused = isPaused;
        emit PauseSet(isPaused);
    }

    /// @notice Update the admin address. Admin only.
    /// @dev One-step transfer — the new admin takes effect immediately. A
    /// wrong `newAdmin` will lock the wrapper's governance permanently:
    /// `setPaused` becomes uncallable. The only recovery is to redeploy the
    /// wrapper and migrate consumers. Use a multisig that cannot be
    /// misaddressed.
    /// @param newAdmin The new admin address. Cannot be zero.
    function setAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAdmin();
        MainStorage storage $ = _main();
        emit AdminSet($.admin, newAdmin);
        $.admin = newAdmin;
    }

    /// @dev Reverts if either pause condition is currently active. Manual
    /// pause is checked first because it is cheaper (single SLOAD) — when an
    /// admin has explicitly set the manual flag we want that error returned,
    /// not the corporate-action one.
    function _validateNotPaused() internal view {
        MainStorage storage $ = _main();
        if ($.paused) revert OraclePausedManual();
        (bool autoPaused, uint64 effectiveTime) = LibCorporateActionsPause.inPauseWindow(
            $.corporateActionsVault, $.actionTypeMask, $.pauseTimeBefore, $.pauseTimeAfter
        );
        if (autoPaused) revert OraclePausedCorporateAction(effectiveTime);
    }
}
