// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {IDIAOracleV2} from "../../interface/IDIAOracleV2.sol";
import {AggregatorV2V3Interface} from "../../interface/IAggregatorV2V3.sol";
import {LibCorporateActionsPause} from "../../lib/LibCorporateActionsPause.sol";
import {ACTION_TYPE_INIT_V1} from "st0x-deploy-0.1.1/src/interface/ICorporateActionsV1.sol";
import {LibDecimalFloat, Float} from "rain-math-float-0.1.1/src/lib/LibDecimalFloat.sol";
import {IERC4626} from "@openzeppelin-contracts-5.6.1/interfaces/IERC4626.sol";
import {ICLONEABLE_V2_SUCCESS, ICloneableV2} from "rain-factory-0.1.1/src/interface/ICloneableV2.sol";
import {Initializable} from "@openzeppelin-contracts-upgradeable-5.6.1/proxy/utils/Initializable.sol";

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

/// @dev Error raised when `maxAge` exceeds `MAX_AGE_LIMIT`. The relative
/// invariant (`pauseTimeAfter > maxAge`) is SCALE-INVARIANT — a units
/// mistake (e.g. the reference config's "2 hours" and "3 hours" expressed in
/// MILLISECONDS) scales both operands equally and passes it cleanly, quietly
/// stretching the staleness window from hours to ~83 days. Only an absolute
/// bound catches that class of error.
/// @param maxAge The rejected max age value.
error MaxAgeTooLarge(uint256 maxAge);

/// @dev Error raised when a pause window (`pauseTimeBefore` or
/// `pauseTimeAfter`) exceeds `MAX_PAUSE_WINDOW`. Same scale-error rationale
/// as `MaxAgeTooLarge` — the relative pause invariant cannot see a
/// wrong-units config in which every term is uniformly oversized.
/// @param pauseTime The rejected window value.
error PauseWindowTooLarge(uint64 pauseTime);

/// @dev Error raised when the priced vault's `asset()` (the tStock that
/// carries `ICorporateActionsV1`) is the zero address — a broken / non-ST0x
/// vault. The auto-pause is mandatory, and a zero corporate-actions vault
/// would silently disable it (serving prices straight across a NAV-rebalance
/// boundary), so it fails loud at init instead.
error ZeroCorporateActionsVault();

/// @dev Error raised when the corporate-action pause mask is incoherent: the
/// mask must retain at least one REAL action bit after the library strips
/// `ACTION_TYPE_INIT_V1`, else the auto-pause never fires despite being
/// "configured".
error InvalidPauseConfig();

/// @dev Error raised when `pauseTimeBefore == 0`. The PRE-action window is as
/// mandatory as the post-action one, and is rejected with the same
/// strictness. The pre-window guards the mirror image of the cross-epoch
/// hazard the `pauseTimeAfter > maxAge` invariant closes: a stock split's
/// ex-date on the real market PRECEDES the on-chain `effectiveTime` (the
/// exchange sets the former, the operator schedules the latter), so the DIA
/// feed can publish the already-rebalanced (e.g. halved) equity price while
/// the vault's NAV ratio is still pre-action. Only the pre-window pauses
/// reads across that interval; with a zero pre-window nothing does, the
/// share is underpriced (~half on a 2:1 split), and the loss falls on
/// BORROWERS — every wtStock-collateralised position appears
/// undercollateralised and becomes liquidatable at a price the collateral
/// does not actually trade at. Note the residual the contract cannot
/// enforce: the upstream scheduler only requires `effectiveTime >
/// block.timestamp`, so an action scheduled at shorter notice than
/// `pauseTimeBefore` nullifies part of the pre-window regardless of its
/// size. A minimum scheduling notice (comfortably above `pauseTimeBefore`)
/// is therefore an OPERATIONAL requirement on the corporate-action
/// scheduler, recorded here because no on-chain check can carry it.
error ZeroPauseTimeBefore();

/// @dev Error raised when `pauseTimeAfter <= maxAge`. The post-action pause MUST
/// last STRICTLY longer than the DIA staleness window, otherwise a
/// stale-but-not-yet-`maxAge` pre-action DIA price can be served against the
/// already-rebalanced post-action vault ratio once the pause lifts — mispricing
/// collateral across a corporate-action boundary. Equality (`pauseTimeAfter ==
/// maxAge`) tolerates zero forward feed clock skew and is rejected; the margin
/// `pauseTimeAfter - maxAge` must exceed the DIA feed's worst-case forward skew.
/// See the contract NatSpec ("Cross-epoch safety invariant") for the full
/// argument.
/// @param pauseTimeAfter The configured post-action pause (seconds).
/// @param maxAge The configured DIA staleness window (seconds).
error PauseTimeAfterBelowMaxAge(uint256 pauseTimeAfter, uint256 maxAge);

/// @dev Error raised when the DIA feed has never been pushed (value or
/// timestamp == 0). Distinct from `DIAPriceStale` so integrators can
/// disambiguate "feed not yet active" from "feed active but late".
error DIAPriceNotSet();

/// @dev Error raised when the DIA reading is older than `maxAge` seconds.
/// @param timestamp The `block.timestamp` of the stale DIA push.
error DIAPriceStale(uint256 timestamp);

/// @dev Error raised on every read inside a corporate-action pause window.
/// @param effectiveTime The `effectiveTime` of the action whose window is
/// currently open. When a pending and a completed action's window overlap
/// `now`, the pending action's `effectiveTime` is reported — integrators see
/// the next event coming, not the last one done.
error OraclePausedCorporateAction(uint64 effectiveTime);

/// @dev Error raised when the vault has zero total supply (no shares minted).
/// Pricing one share of a zero-supply vault is undefined.
error ZeroVaultSupply();

/// @dev Error raised when the computed vault share price is zero. A zero
/// price is never a valid Chainlink-compatible answer.
error ZeroVaultSharePrice();

/// @dev Error raised when the vault share price, though it fits uint256,
/// exceeds `int256.max` and so cannot be returned as the signed Chainlink
/// answer. A price so large it overflows uint256 during the 8-decimal scaling
/// aborts EARLIER inside `LibDecimalFloat` with its own `FixedDecimalOverflow`
/// error, not this one — both are fail-closed, but only this int256-band case
/// carries the contract's own selector.
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
/// `block.timestamp - timestamp >= maxAge` reverts `DIAPriceStale` (the edge
/// instant fails closed — a push exactly `maxAge` old is stale). Immutable
/// after init — redeploy a fresh proxy to change. MUST be `< pauseTimeAfter`
/// STRICTLY (a positive margin is required — see `pauseTimeAfter`) and at
/// most `MAX_AGE_LIMIT` (`MaxAgeTooLarge` — an absolute scale guard the
/// relative invariant cannot provide; both pause windows are likewise capped
/// at `MAX_PAUSE_WINDOW`).
/// @param actionTypeMask Bitmap of action types that trigger the auto-pause.
/// `ACTION_TYPE_STOCK_SPLIT_V1` for splits only, or `type(uint256).max` for
/// every present and future action type. Must be non-zero.
/// @param pauseTimeBefore Seconds before a pending action's `effectiveTime` to
/// start pausing. Must be non-zero, sized above the worst-case ex-date →
/// `effectiveTime` lead — see `ZeroPauseTimeBefore`.
/// @param pauseTimeAfter Seconds after a completed action's `effectiveTime` to
/// keep pausing. Both windows are individually mandatory (each has its own
/// strict check), AND `pauseTimeAfter > maxAge` (STRICTLY) is REQUIRED and
/// enforced at init
/// (`PauseTimeAfterBelowMaxAge`) — the post-action pause must outlast the DIA
/// staleness window so a pre-action price can never be served against the
/// post-action ratio. The margin `pauseTimeAfter - maxAge` is the maximum
/// forward DIA feed clock skew this config tolerates: because staleness is aged
/// from the push's own (skewable) source timestamp, a feed running `skew`
/// seconds fast can present a pre-action observation stamped up to `skew` after
/// `effectiveTime`, and only a margin exceeding `skew` guarantees every
/// still-acceptable push at pause-lift was observed at or after `effectiveTime`.
/// Size the margin above the feed's worst-case forward skew (the prod config's
/// 1h margin over a 2h `maxAge` is the reference).
/// @dev The corporate-actions vault is NOT a config field: it is derived as
/// `IERC4626(vault).asset()` — the tStock the wtStock wraps, which is the
/// contract that implements `ICorporateActionsV1`. Deriving it removes a
/// mis-wiring surface (you can't point the auto-pause at the wrong token).
struct DIAVaultOracleConfig {
    IDIAOracleV2 diaOracle;
    string symbol;
    address vault;
    uint256 maxAge;
    uint256 actionTypeMask;
    uint64 pauseTimeBefore;
    uint64 pauseTimeAfter;
}

/// @title DIAVaultOracle
/// @notice Prices ERC-4626 (`wtStock`) vault shares by reading the underlying
/// equity price from a DIA Data Association feed and multiplying by the
/// vault's assets-per-share ratio, and auto-pauses reads around scheduled
/// corporate actions. Exposes prices via Chainlink's `AggregatorV2V3Interface`
/// so consumers (Euler, Aave-style lending protocols) can target the same
/// surface they already use for Chainlink feeds.
///
/// Math: `vaultSharePrice = diaPrice * totalAssets / totalSupply` scaled to 8
/// decimals — i.e. the equity's USD price times the vault's raw assets-per-share
/// ratio (≈ `convertToAssets(1 share)`, up to OZ ERC-4626 virtual-offset
/// rounding), so the price tracks any NAV change inside the vault (most
/// importantly the post-split rebalance in the underlying `tStock`). Uses the
/// RAW `totalAssets / totalSupply` — see the trust-model note below. Performed
/// in Rain float
/// space throughout so neither operand can overflow uint256; the conversion to
/// fixed-point 8dp happens only at the final return.
///
/// Vault trust model (donation / share-price inflation): the priced `vault` is
/// a `wtStock` wrapper whose `totalAssets()` IS raw
/// `IERC20(asset()).balanceOf(vault)` — `StoxWrappedTokenVault` overrides only
/// `name()`/`symbol()` and inherits the OZ ERC-4626 default. Direct transfers
/// into the vault ("donations") therefore DO move the share ratio, and the
/// transfer path is permissionless: the upstream authorizer allows any
/// `TRANSFER_SHARES` while certification is valid (it only fails closed on a
/// system-wide certification lapse), so anyone holding tStock can donate.
///
/// This is deliberate and is NOT a manipulation surface, because a donation is
/// value-additive and irreversible:
///
/// - The assets are really in the vault. Every share genuinely redeems for
///   more. A borrower's collateral is not phantom — it is worth what the
///   oracle says it is worth. NAV bumps (dividend reinvestment, post-action
///   rebalances) are delivered as exactly such transfers, so this is the
///   normal mechanism, not an attack.
/// - A donor gets nothing back. A bare ERC-20 transfer mints no shares, so the
///   value spreads pro-rata across existing holders and cannot be withdrawn.
///   Donating `D` buys at most `LTV * yourShareOfSupply * D` of extra
///   borrowing power against a cost of `D` — strictly negative-EV unless you
///   already own essentially the whole supply, in which case it is circular.
///
/// The classic ERC-4626 donation attack is a ROUNDING attack on depositors (a
/// near-empty vault plus a donation makes the next depositor's shares round to
/// zero). It lives in the vault's own share accounting, harms depositors
/// rather than price consumers, and is not addressable from an oracle — no
/// check here would prevent it. It is out of scope for this contract.
///
/// Deliberately NOT mitigated here: no sanity band, drift limit or ratio
/// anchor gates reads. Such a gate would fail closed on a legitimate NAV move
/// (a large dividend or redemption), and an oracle that stops answering is
/// strictly worse for a lending market than one that answers correctly —
/// liquidations halt while positions keep moving, which accrues bad debt. The
/// real stale-ratio risk is the corporate-action rebalance, and that is
/// handled by the mandatory auto-pause below.
///
/// Pointing this oracle at an arbitrary third-party ERC-4626 remains
/// unsupported, for TWO reasons. First, nothing outside the ST0x stack
/// guarantees the corporate-action wiring the auto-pause depends on. Second,
/// `_vaultSharePrice` uses the RAW `totalAssets/totalSupply` as assets-per-
/// share, which only holds when the vault's share decimals equal its asset
/// decimals (a zero ERC-4626 decimals offset, as the production `wtStock`
/// has). A vault with a non-zero decimals offset is mispriced by `10^offset`
/// in one orientation and bricks (`ZeroVaultSharePrice`) in the other — so
/// "unsupported" here means mispriced, not merely un-pausable. See
/// `_vaultSharePrice` for the per-function note.
///
/// Auto-pause: on every read the oracle consults `ICorporateActionsV1` on the
/// corporate-actions vault — derived as the priced vault's `asset()`, i.e. the
/// tStock the wtStock wraps — via `LibCorporateActionsPause`, and reverts
/// `OraclePausedCorporateAction` inside the pre/post window of any matching
/// scheduled or completed action, so lending markets can't borrow or liquidate
/// against a stale-by-construction share price mid-rebalance. The auto-pause is
/// MANDATORY — every ST0x token implements corporate actions, so there is no
/// disabled path and no separate wrapper. There is no manual pause and no
/// admin: config is immutable, set once at initialize; to change anything,
/// deploy a fresh proxy and migrate consumers.
///
/// Cross-epoch safety invariant (`pauseTimeAfter > maxAge` STRICTLY, enforced at
/// init): the share price multiplies a DIA equity price by the vault's LIVE
/// `totalAssets/totalSupply` ratio. Those two inputs must belong to the same
/// corporate-action epoch. When an action completes, the vault ratio rebalances
/// atomically, but DIA keeps serving the pre-action equity price until its next
/// push — up to `maxAge` seconds. The post-window pause is the only barrier
/// between the two epochs. If the pause lifts while a pre-action DIA price is
/// still within `maxAge` (hence accepted by the staleness check), that stale
/// price pairs with the already-rebalanced ratio: on a 2:1 split the share is
/// valued at ~2x, letting a borrower draw against phantom collateral (bad debt).
///
/// The PRE-action window closes the mirror-image hazard — the market's
/// ex-date revaluation precedes the on-chain `effectiveTime` — so
/// `pauseTimeBefore` is equally mandatory: see `ZeroPauseTimeBefore` for
/// the full argument and the scheduling-notice requirement.
///
/// The subtlety is which CLOCK ages the push. Staleness is measured from the
/// push's own DIA SOURCE timestamp, not from when it landed on chain, and that
/// source clock is outside our control. A feed running `skew` seconds fast
/// stamps a pre-action observation as far as `skew` AFTER `effectiveTime`, so at
/// the pause-lift instant `t = effectiveTime + pauseTimeAfter` a served push is
/// only guaranteed timestamped `> t - maxAge`, i.e. `> effectiveTime +
/// (pauseTimeAfter - maxAge)` in source time — which corresponds to a real
/// OBSERVATION at or after `effectiveTime` only when the margin `pauseTimeAfter
/// - maxAge` exceeds the feed's forward skew. Equality (`pauseTimeAfter ==
/// maxAge`) leaves a zero margin: a feed even one second fast reopens the
/// window (a 2s skew serves the pre-split price at 2x — verified). Init
/// therefore REQUIRES a strictly positive margin (`pauseTimeAfter > maxAge`),
/// and operators MUST size that margin above their feed's worst-case forward
/// clock skew — the strict check is the enforceable floor, not a guarantee that
/// any positive margin suffices. The staleness check alone is NOT sufficient —
/// it bounds age, not epoch; the invariant, the edge-rejecting staleness, and a
/// skew-covering margin together are what close the window.
///
/// Deployed as a beacon-proxy clone via `ICloneableV2.initialize`.
contract DIAVaultOracle is AggregatorV2V3Interface, ICloneableV2, Initializable {
    /// @notice Absolute upper bound on `maxAge`. A pure SCALE guard: the
    /// production reference is 2 hours, and the only realistic way to land
    /// above a week is a wrong-units config (2 hours in milliseconds is ~83
    /// days), which the scale-invariant relative checks cannot catch.
    /// Deliberately below `MAX_PAUSE_WINDOW` so `pauseTimeAfter > maxAge`
    /// remains satisfiable at this bound.
    uint256 public constant MAX_AGE_LIMIT = 7 days;

    /// @notice Absolute upper bound on each pause window. Generous — a
    /// deliberately long post-action pause is legitimate — while still
    /// catching the milliseconds-for-seconds class (the reference 1-hour
    /// pre-window in ms is ~41 days).
    uint64 public constant MAX_PAUSE_WINDOW = 30 days;

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
        // The ICorporateActionsV1 vault gating the auto-pause.
        address corporateActionsVault;
        // Bitmap of action types that trigger the auto-pause.
        uint256 actionTypeMask;
        // Seconds before a pending action's effectiveTime to start pausing.
        uint64 pauseTimeBefore;
        // Seconds after a completed action's effectiveTime to keep pausing.
        uint64 pauseTimeAfter;
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

    /// @notice The `ICorporateActionsV1` vault gating the auto-pause.
    function corporateActionsVault() public view returns (address) {
        return _main().corporateActionsVault;
    }

    /// @notice Bitmap of action types that trigger the auto-pause.
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
    function initialize(DIAVaultOracleConfig memory config) external pure returns (bytes32) {
        (config);
        revert InitializeSignatureFn();
    }

    /// @dev Static field validation for `initialize`: zero/empty checks on
    /// the externally-supplied fields plus the absolute `maxAge` scale
    /// guard. Pure — everything that needs an external call stays in
    /// `initialize`, which calls this first.
    function _validateStaticConfig(DIAVaultOracleConfig memory config) private pure {
        if (address(config.diaOracle) == address(0)) revert ZeroDIAOracle();
        if (bytes(config.symbol).length == 0) revert EmptySymbol();
        if (config.vault == address(0)) revert ZeroVault();
        if (config.maxAge == 0) revert ZeroMaxAge();
        // Absolute scale guard: the relative `pauseTimeAfter > maxAge`
        // invariant (checked in `_validatePauseConfig`) is scale-invariant,
        // so a uniformly wrong-units config passes it — only an absolute
        // bound fails it closed.
        if (config.maxAge > MAX_AGE_LIMIT) revert MaxAgeTooLarge(config.maxAge);
    }

    /// @dev Pause-config validation for `initialize`, called after the
    /// corporate-actions vault derivation: mask coherence, the mandatory
    /// pre-window, both absolute window caps, and the relative cross-epoch
    /// invariant.
    function _validatePauseConfig(DIAVaultOracleConfig memory config) private pure {
        // Auto-pause is mandatory and must be coherently configured. The mask
        // must retain a real action bit AFTER the library strips
        // `ACTION_TYPE_INIT_V1` (the bootstrap node is not a real action) — a
        // mask of exactly `ACTION_TYPE_INIT_V1` would pass a bare `!= 0` check
        // yet the library short-circuits it to "never pauses", silently
        // defeating the mandatory auto-pause.
        if ((config.actionTypeMask & ~ACTION_TYPE_INIT_V1) == 0) {
            revert InvalidPauseConfig();
        }

        // The PRE-action window is rejected at zero with the same strictness
        // as the post-action side below — see `ZeroPauseTimeBefore`.
        if (config.pauseTimeBefore == 0) {
            revert ZeroPauseTimeBefore();
        }

        // Same absolute scale guard for both windows (see `MaxAgeTooLarge` /
        // `PauseWindowTooLarge`): each field is bounded individually so the
        // revert names the offending value.
        if (config.pauseTimeBefore > MAX_PAUSE_WINDOW) {
            revert PauseWindowTooLarge(config.pauseTimeBefore);
        }
        if (config.pauseTimeAfter > MAX_PAUSE_WINDOW) {
            revert PauseWindowTooLarge(config.pauseTimeAfter);
        }

        // Cross-epoch safety invariant: the post-action pause must STRICTLY
        // outlast the DIA staleness window. The vault's NAV ratio rebalances the
        // instant a corporate action completes, but DIA may still serve the
        // pre-action equity price for up to `maxAge` seconds afterwards. The
        // pause is the only thing separating those two epochs; if it lifts while
        // a pre-action price is still "fresh" that price pairs with the
        // post-action ratio and misprices the share (e.g. ~2x on a 2:1 split →
        // over-borrow → bad debt).
        //
        // The staleness age is measured from the DIA push's OWN source
        // timestamp, NOT from when it landed on chain, so a feed whose clock
        // runs forward by `skew` stamps a pre-action observation as far as
        // `skew` seconds AFTER `effectiveTime` — and that push is then accepted
        // for the whole `maxAge` window past its (skewed) timestamp. The margin
        // `pauseTimeAfter - maxAge` is exactly the forward feed skew this config
        // tolerates: at pause-lift the oldest still-acceptable push was OBSERVED
        // at or after `effectiveTime` only if that margin exceeds the feed's max
        // forward skew. `>=` (equality) tolerates ZERO skew and is therefore
        // rejected — a strictly positive margin is required, and operators MUST
        // size it above their feed's worst-case forward clock error (the prod
        // config's 1h margin over a 2h maxAge is the reference). See the
        // contract NatSpec ("Cross-epoch safety invariant") for the full
        // argument.
        if (config.pauseTimeAfter <= config.maxAge) {
            revert PauseTimeAfterBelowMaxAge(config.pauseTimeAfter, config.maxAge);
        }
    }

    /// @inheritdoc ICloneableV2
    function initialize(bytes calldata data) external initializer returns (bytes32) {
        DIAVaultOracleConfig memory config = abi.decode(data, (DIAVaultOracleConfig));

        _validateStaticConfig(config);

        // The corporate-actions vault is the tStock the wtStock wraps — the
        // priced vault's own `asset()`. Deriving it (rather than taking a
        // separate config field) removes a mis-wiring surface.
        address derivedCorporateActionsVault = IERC4626(config.vault).asset();
        if (derivedCorporateActionsVault == address(0)) revert ZeroCorporateActionsVault();

        _validatePauseConfig(config);

        // Probe the corporate-actions vault once so an incompatible wiring — a
        // missing facet (ABI-decode revert) or a mask with no bits in the
        // upstream VALID_ACTION_TYPES_MASK (InvalidMask) — reverts THIS deploy
        // transaction rather than every future consumer read against immutable
        // config. Result discarded; only reachability is asserted.
        // slither-disable-next-line unused-return
        LibCorporateActionsPause.inPauseWindow(
            derivedCorporateActionsVault, config.actionTypeMask, config.pauseTimeBefore, config.pauseTimeAfter
        );

        MainStorage storage $ = _main();
        $.diaOracle = config.diaOracle;
        $.symbol = config.symbol;
        $.vault = config.vault;
        $.maxAge = config.maxAge;
        $.corporateActionsVault = derivedCorporateActionsVault;
        $.actionTypeMask = config.actionTypeMask;
        $.pauseTimeBefore = config.pauseTimeBefore;
        $.pauseTimeAfter = config.pauseTimeAfter;

        emit DIAVaultOracleInitialized(msg.sender, config);

        return ICLONEABLE_V2_SUCCESS;
    }

    /// @inheritdoc AggregatorV2V3Interface
    /// @dev Deliberate deviation from the Chainlink-style pair-string
    /// convention: this returns the BARE DIA feed symbol (e.g. `"COIN"`), NOT
    /// a `"SYMBOL / USD"` pair string, because DIA keys its feeds by the bare
    /// symbol and that is the single source of truth here. Integrators that
    /// expect a Chainlink-formatted pair string must adjust. The interface
    /// NatSpec is worded so it does not contradict this.
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
        _validateNotPaused();
        (uint128 diaPrice,) = _readDIAChecked();
        return _vaultSharePrice(diaPrice);
    }

    /// @inheritdoc AggregatorV2V3Interface
    /// @dev `roundId` and `answeredInRound` are derived from the DIA push
    /// `timestamp` (truncated to `uint80`) so they change whenever DIA produces
    /// a new push, without adding storage. They are a FRESHNESS token, not a
    /// strictly monotonic counter: if DIA ever republishes a lower source
    /// timestamp (a corrected push, a source-clock regression) the id moves
    /// backwards, so integrators should diff for inequality — NOT assert
    /// `roundId > lastSeen`. The `uint80` window covers every plausible
    /// deployment lifetime.
    ///
    /// `startedAt`/`updatedAt` are the push's source timestamp CLAMPED to
    /// `block.timestamp`. `_readDIAChecked` deliberately accepts a future-dated
    /// push (a feed running slightly ahead) as fresh; returning that raw
    /// future timestamp here would make a Chainlink-style consumer computing
    /// `block.timestamp - updatedAt` underflow-revert. Clamping reports such a
    /// fresh push as age 0 — which is what "fresh" means — and never emits a
    /// timestamp ahead of the block clock.
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        _validateNotPaused();
        (uint128 diaPrice, uint128 timestamp) = _readDIAChecked();
        int256 scaledPrice = _vaultSharePrice(diaPrice);

        uint80 round = uint80(timestamp);
        // Slither `timestamp` FALSE POSITIVE: block.timestamp is used only to
        // CLAMP the reported push time to the local clock (so a future-dated
        // push never reports an age below zero to a consumer), not for any value
        // or authorisation decision. Proposer drift on block.timestamp only
        // shifts the clamp point by seconds.
        // slither-disable-next-line timestamp
        uint256 reportedAt = uint256(timestamp) > block.timestamp ? block.timestamp : uint256(timestamp);
        return (round, scaledPrice, reportedAt, reportedAt, round);
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

    /// @dev Reverts `OraclePausedCorporateAction` if the current block is
    /// inside the pre/post window of any matching scheduled or completed
    /// action on the configured corporate-actions vault.
    function _validateNotPaused() internal view {
        MainStorage storage $ = _main();
        (bool paused, uint64 effectiveTime) = LibCorporateActionsPause.inPauseWindow(
            $.corporateActionsVault, $.actionTypeMask, $.pauseTimeBefore, $.pauseTimeAfter
        );
        if (paused) revert OraclePausedCorporateAction(effectiveTime);
    }

    /// @dev Read DIA and revert on either "never pushed" (DIAPriceNotSet) or
    /// "too old" (DIAPriceStale). DIA's `getValue` returns `(0, 0)` for an
    /// unset feed rather than reverting — we must check explicitly.
    function _readDIAChecked() internal view returns (uint128 value, uint128 timestamp) {
        MainStorage storage $ = _main();
        (value, timestamp) = $.diaOracle.getValue($.symbol);
        if (value == 0 || timestamp == 0) revert DIAPriceNotSet();
        // Slither `timestamp` is a FALSE POSITIVE here: the detector flags
        // block.timestamp comparisons because miner-influenceable time can be
        // gamed for value or authorisation. Neither applies — block.timestamp
        // is used purely as the local clock to age a DIA push, which is the
        // entire purpose of a staleness check, and the seconds of drift a
        // proposer can induce are immaterial against a maxAge measured in
        // hours. No value or permission decision reads the clock.
        //
        // A push timestamped at or before `now` applies the `maxAge` window. A
        // push timestamped in the FUTURE (a feed running slightly ahead, or a
        // chain-time regression / reorg) is treated as fresh (age 0), never
        // stale: the `<= block.timestamp` guard short-circuits the subtraction
        // so it can never underflow into a bare `Panic(0x11)` that integrators
        // cannot disambiguate from `DIAPriceStale` / `DIAPriceNotSet`.
        //
        // The staleness edge fails closed (`>=`): a push exactly `maxAge` old is
        // STALE. This is deliberate — it tightens the cross-epoch invariant by
        // one second (see the contract NatSpec) and matches the fail-closed
        // staleness convention (the edge counts as stale). It does NOT on its
        // own make the invariant "airtight" — the margin `pauseTimeAfter -
        // maxAge` must still cover the feed's forward source-clock skew, which
        // is why init requires that margin to be strictly positive.
        // slither-disable-next-line timestamp
        if (uint256(timestamp) <= block.timestamp && block.timestamp - uint256(timestamp) >= $.maxAge) {
            revert DIAPriceStale(uint256(timestamp));
        }
    }

    /// @dev Compute vault share price from a DIA reading via Rain float math
    /// so neither operand can overflow uint256. DIA prices are 18-decimal
    /// `uint128`. The vault ratio is `totalAssets / totalSupply`. Output is
    /// 8-decimal `int256` per Chainlink `latestAnswer` convention.
    ///
    /// Donation / share-inflation: this reads `totalAssets()` directly, and on
    /// the production `wtStock` that IS raw `IERC20(asset()).balanceOf(vault)`,
    /// so a direct transfer into the vault does move the ratio. That is
    /// intentional and not a manipulation surface — a donation adds real assets
    /// the shares genuinely redeem for, mints the donor nothing, and cannot be
    /// withdrawn, so it is value-additive and negative-EV for the donor. No
    /// sanity band gates this read; halting the oracle on an unexpected ratio
    /// would stop liquidations, which is worse for a lending market than
    /// pricing the (real) NAV. See the contract NatSpec ("Vault trust model")
    /// for the full argument and for what IS mitigated — the corporate-action
    /// rebalance, via the mandatory auto-pause.
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
