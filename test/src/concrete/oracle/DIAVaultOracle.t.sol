// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.1/src/Test.sol";
import {Initializable} from "@openzeppelin-contracts-5.6.1/proxy/utils/Initializable.sol";
import {ICLONEABLE_V2_SUCCESS, ICloneableV2} from "rain-factory-0.1.1/src/interface/ICloneableV2.sol";
import {IDIAOracleV2} from "../../../../src/interface/IDIAOracleV2.sol";
import {
    DIAVaultOracle,
    DIAVaultOracleConfig,
    ZeroDIAOracle,
    ZeroVault,
    ZeroMaxAge,
    ZeroCorporateActionsVault,
    InvalidPauseConfig,
    ZeroPauseTimeBefore,
    MaxAgeTooLarge,
    PauseWindowTooLarge,
    PauseTimeAfterBelowMaxAge,
    OraclePausedCorporateAction,
    EmptySymbol,
    DIAPriceNotSet,
    DIAPriceStale,
    ZeroVaultSupply,
    ZeroVaultSharePrice,
    VaultSharePriceOverflow,
    HistoricalRoundDataUnsupported
} from "../../../../src/concrete/oracle/DIAVaultOracle.sol";
import {MockDIAOracle} from "../../../mocks/MockDIAOracle.sol";
import {MockERC4626} from "../../../mocks/MockERC4626.sol";
import {MockCorporateActions} from "../../../mocks/MockCorporateActions.sol";
import {
    MockRevertingCorporateActions,
    CorporateActionsUnavailable
} from "../../../mocks/MockRevertingCorporateActions.sol";
import {CorporateActionsListHarness} from "../../../mocks/CorporateActionsListHarness.sol";
import {TestERC1967Proxy} from "../../../mocks/TestERC1967Proxy.sol";
import {ACTION_TYPE_STOCK_SPLIT_V1, ACTION_TYPE_INIT_V1} from "st0x-deploy-0.1.1/src/interface/ICorporateActionsV1.sol";
import {InvalidMask} from "st0x-deploy-0.1.1/src/error/ErrCorporateAction.sol";
import {FixedDecimalOverflow} from "rain-math-float-0.1.1/src/error/ErrDecimalFloat.sol";

contract DIAVaultOracleTest is Test {
    DIAVaultOracle internal implementation;
    MockDIAOracle internal diaOracle;
    MockERC4626 internal vault;
    MockCorporateActions internal actions;
    string internal constant SYMBOL = "COIN";
    uint256 internal constant MAX_AGE = 1 hours;
    uint64 internal constant PAUSE_BEFORE = 3600;
    // Strictly greater than MAX_AGE: the cross-epoch invariant now requires a
    // positive margin (`pauseTimeAfter > maxAge`) to cover DIA feed forward
    // clock skew, so the default config carries a 1h margin over the 1h maxAge.
    uint64 internal constant PAUSE_AFTER = 2 hours;

    event DIAVaultOracleInitialized(address indexed sender, DIAVaultOracleConfig config);

    function setUp() public {
        implementation = new DIAVaultOracle();
        diaOracle = new MockDIAOracle();
        vault = new MockERC4626();
        actions = new MockCorporateActions();
        // The oracle derives its corporate-actions vault from the priced
        // vault's `asset()` (the tStock the wtStock wraps).
        vault.setAsset(address(actions));
        // Warp far enough in that `block.timestamp - maxAge` doesn't underflow.
        vm.warp(1_000_000);
    }

    function _deployUninit() internal returns (DIAVaultOracle) {
        // Bare ERC1967 proxy is enough — beacon semantics are irrelevant for
        // unit tests of the implementation surface.
        TestERC1967Proxy proxy = new TestERC1967Proxy(address(implementation));
        return DIAVaultOracle(address(proxy));
    }

    function _deployProxy(DIAVaultOracleConfig memory config) internal returns (DIAVaultOracle) {
        DIAVaultOracle oracle = _deployUninit();
        bytes32 ok = oracle.initialize(abi.encode(config));
        assertEq(ok, ICLONEABLE_V2_SUCCESS);
        return oracle;
    }

    function _defaultConfig() internal view returns (DIAVaultOracleConfig memory) {
        return DIAVaultOracleConfig({
            diaOracle: IDIAOracleV2(address(diaOracle)),
            symbol: SYMBOL,
            vault: address(vault),
            maxAge: MAX_AGE,
            actionTypeMask: ACTION_TYPE_STOCK_SPLIT_V1,
            pauseTimeBefore: PAUSE_BEFORE,
            pauseTimeAfter: PAUSE_AFTER
        });
    }

    // -------- corporate-action auto-pause (mandatory) --------

    /// @notice A vault whose `asset()` is zero (broken / non-ST0x) would leave
    /// the derived corporate-actions vault zero and silently disable the
    /// auto-pause — rejected at init.
    function testInitRevertsWhenVaultAssetIsZero() external {
        MockERC4626 vaultNoAsset = new MockERC4626(); // asset() defaults to 0
        DIAVaultOracleConfig memory config = _defaultConfig();
        config.vault = address(vaultNoAsset);
        DIAVaultOracle oracle = _deployUninit();
        vm.expectRevert(ZeroCorporateActionsVault.selector);
        oracle.initialize(abi.encode(config));
    }

    function testInitRevertsZeroMask() external {
        DIAVaultOracleConfig memory config = _defaultConfig();
        config.actionTypeMask = 0;
        DIAVaultOracle oracle = _deployUninit();
        vm.expectRevert(InvalidPauseConfig.selector);
        oracle.initialize(abi.encode(config));
    }

    /// @notice A mask of exactly `ACTION_TYPE_INIT_V1` is non-zero but the
    /// library strips that bit, so it would never pause. Init must reject it
    /// (else a "coherently configured" oracle silently never auto-pauses).
    function testInitRevertsInitOnlyMask() external {
        DIAVaultOracleConfig memory config = _defaultConfig();
        config.actionTypeMask = ACTION_TYPE_INIT_V1;
        DIAVaultOracle oracle = _deployUninit();
        vm.expectRevert(InvalidPauseConfig.selector);
        oracle.initialize(abi.encode(config));
    }

    /// @notice Both windows zero reverts `ZeroPauseTimeBefore` — the
    /// pre-window check precedes the relative post-window invariant, so the
    /// pre side is named first.
    function testInitRevertsBothWindowsZero() external {
        DIAVaultOracleConfig memory config = _defaultConfig();
        config.pauseTimeBefore = 0;
        config.pauseTimeAfter = 0;
        DIAVaultOracle oracle = _deployUninit();
        vm.expectRevert(ZeroPauseTimeBefore.selector);
        oracle.initialize(abi.encode(config));
    }

    /// @notice A pre-window-ONLY config (`pauseTimeAfter == 0`) is REJECTED: it
    /// violates the cross-epoch invariant `pauseTimeAfter > maxAge`. With no
    /// post-window, the oracle would resume serving the instant a split
    /// completes, pairing a still-fresh pre-split DIA price with the
    /// already-rebalanced post-split ratio — the exact mispricing the invariant
    /// exists to prevent. (Guards against a regression that treated a single
    /// pre-window as sufficient.)
    function testInitRevertsPreWindowOnlyBelowMaxAge() external {
        DIAVaultOracleConfig memory config = _defaultConfig();
        config.pauseTimeBefore = PAUSE_BEFORE;
        config.pauseTimeAfter = 0;
        DIAVaultOracle oracle = _deployUninit();
        vm.expectRevert(abi.encodeWithSelector(PauseTimeAfterBelowMaxAge.selector, uint256(0), MAX_AGE));
        oracle.initialize(abi.encode(config));
    }

    /// @notice A post-window-only config (`pauseTimeBefore == 0`) is
    /// REJECTED. The pre-window guards the ex-date → `effectiveTime`
    /// interval (the market revalues before the on-chain action), and with a
    /// zero pre-window the already-rebalanced DIA price pairs with the
    /// pre-action vault ratio, underpricing the share against borrowers.
    function testInitRevertsZeroPauseTimeBefore() external {
        DIAVaultOracleConfig memory config = _defaultConfig();
        config.pauseTimeBefore = 0;
        config.pauseTimeAfter = PAUSE_AFTER;
        DIAVaultOracle oracle = _deployUninit();
        vm.expectRevert(ZeroPauseTimeBefore.selector);
        oracle.initialize(abi.encode(config));
    }

    /// @notice The minimum viable pre-window (one second) is accepted — the
    /// strict check rejects exactly zero, it does not impose a floor beyond
    /// non-zero (sizing the window against the ex-date lead is the
    /// operator's job, documented as such).
    function testInitAcceptsOneSecondPreWindow() external {
        DIAVaultOracleConfig memory config = _defaultConfig();
        config.pauseTimeBefore = 1;
        config.pauseTimeAfter = PAUSE_AFTER;
        DIAVaultOracle oracle = _deployUninit();
        bytes32 ok = oracle.initialize(abi.encode(config));
        assertEq(ok, ICLONEABLE_V2_SUCCESS, "one-second pre-window must be accepted");
        assertEq(oracle.pauseTimeBefore(), 1);
        assertEq(oracle.pauseTimeAfter(), PAUSE_AFTER);
    }

    /// @notice The relative `pauseTimeAfter > maxAge` invariant is
    /// scale-invariant, so the reference config expressed in MILLISECONDS
    /// (maxAge 7_200_000, pauseTimeAfter 10_800_000 — "2 hours" and "3
    /// hours" with the wrong units) passes it cleanly, stretching the
    /// staleness window to ~83 days. The absolute `MAX_AGE_LIMIT` bound is
    /// what rejects it, naming the offending value.
    function testInitRevertsMillisecondScaleConfig() external {
        DIAVaultOracleConfig memory config = _defaultConfig();
        config.maxAge = 7_200_000;
        config.pauseTimeBefore = 3_600_000;
        config.pauseTimeAfter = 10_800_000;
        DIAVaultOracle oracle = _deployUninit();
        vm.expectRevert(abi.encodeWithSelector(MaxAgeTooLarge.selector, uint256(7_200_000)));
        oracle.initialize(abi.encode(config));
    }

    /// @notice `maxAge` exactly at `MAX_AGE_LIMIT` is accepted (with a
    /// coherent pauseTimeAfter above it); one second over is rejected. The
    /// cap is deliberately below `MAX_PAUSE_WINDOW` so the relative
    /// invariant stays satisfiable at the bound.
    function testInitMaxAgeCapEdges() external {
        DIAVaultOracleConfig memory config = _defaultConfig();
        config.maxAge = 7 days;
        config.pauseTimeAfter = 7 days + 1 hours;
        DIAVaultOracle atCap = _deployUninit();
        assertEq(atCap.initialize(abi.encode(config)), ICLONEABLE_V2_SUCCESS, "maxAge at the cap must be accepted");

        config.maxAge = 7 days + 1;
        DIAVaultOracle overCap = _deployUninit();
        vm.expectRevert(abi.encodeWithSelector(MaxAgeTooLarge.selector, uint256(7 days + 1)));
        overCap.initialize(abi.encode(config));
    }

    /// @notice Each pause window is individually capped at
    /// `MAX_PAUSE_WINDOW`, and the revert carries the offending value so an
    /// operator can tell WHICH window was mis-scaled.
    function testInitRevertsPauseWindowOverCap() external {
        DIAVaultOracleConfig memory config = _defaultConfig();
        config.pauseTimeBefore = uint64(30 days) + 1;
        DIAVaultOracle oracle = _deployUninit();
        vm.expectRevert(abi.encodeWithSelector(PauseWindowTooLarge.selector, uint64(30 days) + 1));
        oracle.initialize(abi.encode(config));

        DIAVaultOracleConfig memory config2 = _defaultConfig();
        config2.pauseTimeAfter = uint64(30 days) + 1;
        DIAVaultOracle oracle2 = _deployUninit();
        vm.expectRevert(abi.encodeWithSelector(PauseWindowTooLarge.selector, uint64(30 days) + 1));
        oracle2.initialize(abi.encode(config2));
    }

    /// @notice Both pause windows exactly at `MAX_PAUSE_WINDOW` are accepted
    /// — the caps reject only what lies beyond them.
    function testInitAcceptsPauseWindowsAtCap() external {
        DIAVaultOracleConfig memory config = _defaultConfig();
        config.pauseTimeBefore = uint64(30 days);
        config.pauseTimeAfter = uint64(30 days);
        DIAVaultOracle oracle = _deployUninit();
        assertEq(oracle.initialize(abi.encode(config)), ICLONEABLE_V2_SUCCESS, "windows at the cap must be accepted");
    }

    /// @notice The cross-epoch invariant is enforced at init: `pauseTimeAfter`
    /// below `maxAge` reverts `PauseTimeAfterBelowMaxAge`, and one second above
    /// `maxAge` (the minimum positive margin) is accepted.
    function testInitRevertsWhenPauseAfterBelowMaxAge() external {
        DIAVaultOracleConfig memory config = _defaultConfig();
        config.maxAge = 2 hours;
        config.pauseTimeAfter = uint64(2 hours) - 1; // one second short
        DIAVaultOracle oracle = _deployUninit();
        vm.expectRevert(
            abi.encodeWithSelector(PauseTimeAfterBelowMaxAge.selector, uint256(2 hours) - 1, uint256(2 hours))
        );
        oracle.initialize(abi.encode(config));

        // One second of margin over maxAge is the minimum init accepts.
        config.pauseTimeAfter = uint64(2 hours) + 1;
        DIAVaultOracle ok = _deployUninit();
        assertEq(ok.initialize(abi.encode(config)), ICLONEABLE_V2_SUCCESS, "strictly-positive margin is accepted");
    }

    /// @notice `pauseTimeAfter == maxAge` (zero margin) is REJECTED. A zero
    /// margin tolerates zero forward feed clock skew, so a feed running even one
    /// second fast could serve a pre-action price at pause-lift — the exact
    /// cross-epoch mispricing this invariant closes. Init requires a strictly
    /// positive margin.
    function testInitRejectsPauseAfterEqualToMaxAge() external {
        DIAVaultOracleConfig memory config = _defaultConfig();
        config.maxAge = 2 hours;
        config.pauseTimeAfter = uint64(2 hours); // exactly on the boundary — now rejected
        DIAVaultOracle oracle = _deployUninit();
        vm.expectRevert(abi.encodeWithSelector(PauseTimeAfterBelowMaxAge.selector, uint256(2 hours), uint256(2 hours)));
        oracle.initialize(abi.encode(config));
    }

    /// @notice A corporate-actions vault whose facet reverts must fail the
    /// DEPLOY transaction (via the init probe), not every future read.
    function testInitProbesVaultRevertsOnBrokenFacet() external {
        MockRevertingCorporateActions broken = new MockRevertingCorporateActions();
        // Point the priced vault's asset() at the broken facet so the derived
        // corporate-actions vault is the reverting one.
        MockERC4626 vaultBroken = new MockERC4626();
        vaultBroken.setAsset(address(broken));
        DIAVaultOracleConfig memory config = _defaultConfig();
        config.vault = address(vaultBroken);
        DIAVaultOracle oracle = _deployUninit();
        vm.expectRevert(CorporateActionsUnavailable.selector);
        oracle.initialize(abi.encode(config));
    }

    /// @notice The init probe must query the CONFIGURED `actionTypeMask`, not a
    /// wildcard. Per the init NatSpec the probe exists so an incompatible wiring
    /// — including "a mask with no bits in the upstream `VALID_ACTION_TYPES_MASK`
    /// (`InvalidMask`)" — reverts THIS deploy transaction rather than every
    /// future consumer read against immutable config.
    ///
    /// Driven against the REAL upstream traversal (`CorporateActionsListHarness`
    /// wraps `LibCorporateActionNode` verbatim), which is what actually raises
    /// `InvalidMask`; the hand-mock returns `NODE_NONE` instead and so cannot
    /// pin this. A mask of `1 << 200` is non-zero and survives the INIT-bit
    /// strip (so `InvalidPauseConfig` does NOT fire) yet matches no valid action
    /// type, so the probe must surface `InvalidMask` at init. A regression that
    /// probed with `type(uint256).max` — or with any mask other than the
    /// configured one — would let this deploy succeed and brick every later
    /// read.
    function testInitProbeUsesConfiguredMaskNotWildcard() external {
        CorporateActionsListHarness realActions = new CorporateActionsListHarness();
        MockERC4626 vaultReal = new MockERC4626();
        vaultReal.setAsset(address(realActions));

        DIAVaultOracleConfig memory config = _defaultConfig();
        config.vault = address(vaultReal);
        // Non-zero, not the INIT bit, but matches nothing in
        // `VALID_ACTION_TYPES_MASK`.
        config.actionTypeMask = 1 << 200;

        DIAVaultOracle oracle = _deployUninit();
        vm.expectRevert(InvalidMask.selector);
        oracle.initialize(abi.encode(config));

        // Positive control: the same wiring with a VALID configured mask
        // initializes, so the revert above is the mask reaching the probe and
        // not the harness being unusable.
        config.actionTypeMask = ACTION_TYPE_STOCK_SPLIT_V1;
        DIAVaultOracle ok = _deployUninit();
        assertEq(ok.initialize(abi.encode(config)), ICLONEABLE_V2_SUCCESS, "valid mask must initialize");
    }

    /// @notice Config fields are validated in DECLARATION order, so the FIRST
    /// offending field is the one reported. An integrator debugging a bad
    /// deploy config fixes one field at a time and expects the next error to
    /// advance; a reordered check would report a later field first and send
    /// them after the wrong config entry. Pins the whole ladder in one test
    /// (each step fixes exactly the field the previous step named).
    function testInitValidatesConfigFieldsInDeclarationOrder() external {
        DIAVaultOracleConfig memory config = _defaultConfig();
        config.diaOracle = IDIAOracleV2(address(0));
        config.symbol = "";
        config.vault = address(0);
        config.maxAge = 0;

        DIAVaultOracle oracle = _deployUninit();
        vm.expectRevert(ZeroDIAOracle.selector);
        oracle.initialize(abi.encode(config));

        config.diaOracle = IDIAOracleV2(address(diaOracle));
        vm.expectRevert(EmptySymbol.selector);
        oracle.initialize(abi.encode(config));

        config.symbol = SYMBOL;
        vm.expectRevert(ZeroVault.selector);
        oracle.initialize(abi.encode(config));

        config.vault = address(vault);
        vm.expectRevert(ZeroMaxAge.selector);
        oracle.initialize(abi.encode(config));

        // Beyond the four zero-checks the pause-coherence check precedes the
        // cross-epoch invariant: with BOTH broken (empty mask AND
        // `pauseTimeAfter < maxAge`) it is `InvalidPauseConfig` that surfaces.
        config.maxAge = MAX_AGE;
        config.actionTypeMask = 0;
        config.pauseTimeAfter = 0;
        vm.expectRevert(InvalidPauseConfig.selector);
        oracle.initialize(abi.encode(config));

        // ...and once the mask is coherent, the invariant check speaks.
        config.actionTypeMask = ACTION_TYPE_STOCK_SPLIT_V1;
        vm.expectRevert(abi.encodeWithSelector(PauseTimeAfterBelowMaxAge.selector, uint256(0), MAX_AGE));
        oracle.initialize(abi.encode(config));
    }

    /// @notice Inside a matching action's window, every price read reverts
    /// `OraclePausedCorporateAction` with that action's effectiveTime.
    function testAutoPauseRevertsInsideWindow() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        diaOracle.setValue(SYMBOL, 100e18, uint64(block.timestamp));
        vault.setTotalAssets(1e18);
        vault.setTotalSupply(1e18);

        // Completed split half a post-window ago → inside the pause window.
        uint64 effectiveTime = uint64(block.timestamp - PAUSE_AFTER / 2);
        actions.setLatestCompleted(1, ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);

        vm.expectRevert(abi.encodeWithSelector(OraclePausedCorporateAction.selector, effectiveTime));
        oracle.latestAnswer();
        vm.expectRevert(abi.encodeWithSelector(OraclePausedCorporateAction.selector, effectiveTime));
        oracle.latestRoundData();
    }

    /// @notice The pause gate runs BEFORE the DIA read on BOTH entry points, so
    /// inside a pause window the reported error is always
    /// `OraclePausedCorporateAction` — never a DIA error that happens to fire
    /// first. Ordering is observable and load-bearing: `DIAPriceStale` tells an
    /// integrator "retry when the feed updates" (minutes), while
    /// `OraclePausedCorporateAction` carries the `effectiveTime` that tells them
    /// when the market reopens, and the two entry points must not disagree about
    /// which condition dominates.
    ///
    /// The overlap is not contrived: it is the normal state late in a post-action
    /// window, since `pauseTimeAfter > maxAge` guarantees every push predating
    /// the action has gone stale before the pause lifts. Here the push sits
    /// exactly on the staleness edge (`age == maxAge`) while the completed action
    /// is still mid-window.
    function testPauseTakesPrecedenceOverStaleDIA() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        vault.setTotalAssets(1e18);
        vault.setTotalSupply(1e18);

        // Stale by the contract's own fail-closed edge: age == maxAge.
        uint128 staleTimestamp = uint128(block.timestamp - MAX_AGE);
        diaOracle.setValue(SYMBOL, 100e18, staleTimestamp);

        // Sanity: with no action in window the very same state reverts
        // `DIAPriceStale`, so the assertions below are about precedence, not
        // about the push being fresh.
        vm.expectRevert(abi.encodeWithSelector(DIAPriceStale.selector, uint256(staleTimestamp)));
        oracle.latestAnswer();
        vm.expectRevert(abi.encodeWithSelector(DIAPriceStale.selector, uint256(staleTimestamp)));
        oracle.latestRoundData();

        // Now open a post-action window over that same instant.
        uint64 effectiveTime = uint64(block.timestamp - PAUSE_AFTER / 2);
        actions.setLatestCompleted(1, ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);

        vm.expectRevert(abi.encodeWithSelector(OraclePausedCorporateAction.selector, effectiveTime));
        oracle.latestAnswer();
        vm.expectRevert(abi.encodeWithSelector(OraclePausedCorporateAction.selector, effectiveTime));
        oracle.latestRoundData();
    }

    /// @notice With no action in-window the oracle prices normally — the
    /// auto-pause gate is off the happy path.
    function testNoPauseOutsideWindowPricesNormally() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        diaOracle.setValue(SYMBOL, 100e18, uint64(block.timestamp));
        vault.setTotalAssets(1e18);
        vault.setTotalSupply(1e18);
        // Completed split well outside the post-window.
        actions.setLatestCompleted(1, ACTION_TYPE_STOCK_SPLIT_V1, uint64(block.timestamp - PAUSE_AFTER - 1));
        assertEq(oracle.latestAnswer(), 100e8, "prices normally outside the pause window");
    }

    /// @notice PRE-window twin of `testAutoPauseRevertsInsideWindow`: a
    /// PENDING action whose `effectiveTime` is within `pauseTimeBefore` of
    /// now pauses BOTH read entry points. The pre-window predicate itself is
    /// covered in LibCorporateActionsPause.t.sol; what this pins is the
    /// ORACLE's wiring of `pauseTimeBefore` into that call — the interval the
    /// zero-pre-window rejection exists to guard (the market's ex-date
    /// revaluation precedes the on-chain `effectiveTime`).
    function testAutoPauseRevertsInsidePreWindow() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        diaOracle.setValue(SYMBOL, 100e18, uint64(block.timestamp));
        vault.setTotalAssets(1e18);
        vault.setTotalSupply(1e18);

        // Pending split half a pre-window ahead → inside the pause window.
        uint64 effectiveTime = uint64(block.timestamp + PAUSE_BEFORE / 2);
        actions.setEarliestPending(1, ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);

        vm.expectRevert(abi.encodeWithSelector(OraclePausedCorporateAction.selector, effectiveTime));
        oracle.latestAnswer();
        vm.expectRevert(abi.encodeWithSelector(OraclePausedCorporateAction.selector, effectiveTime));
        oracle.latestRoundData();
    }

    // -------- ERC-7201 storage-layout pin (beacon-upgrade safety) --------

    /// @notice The `MainStorage` slot constant is a hardcoded hex literal with
    /// no getter. Pin it to the normative ERC-7201 derivation by proving
    /// storage actually lands there: after `initialize`, the first field
    /// (`diaOracle`) must be readable at the recomputed slot. If a future v2
    /// re-namespaces or drifts the layout, this fails — do not "fix" the test,
    /// fix the layout (a drift corrupts every live proxy on beacon upgrade).
    function testMainStorageLocationMatchesErc7201Derivation() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        bytes32 derived =
            keccak256(abi.encode(uint256(keccak256("st0x.diavaultoracle.main")) - 1)) & ~bytes32(uint256(0xff));
        // diaOracle is the first member of MainStorage → sits exactly at the slot.
        address storedDIAOracle = address(uint160(uint256(vm.load(address(oracle), derived))));
        assertEq(
            storedDIAOracle, address(oracle.diaOracle()), "MainStorage must be namespaced at the ERC-7201 derived slot"
        );
    }

    /// @notice The namespace base is not enough: the ORDER of `MainStorage`'s
    /// members is itself part of the layout contract, because a beacon upgrade
    /// keeps every live proxy's storage. Reordering two members in a v2 leaves
    /// the base slot intact (so the test above still passes) while every proxy
    /// silently reinterprets one field as another — e.g. `vault` read out of the
    /// `maxAge` word. Pin every member to its exact slot offset, read raw.
    ///
    /// Expected layout, one slot per member except the two `uint64` windows
    /// which pack into a single word (before in the low 64 bits, after next):
    ///   +0 diaOracle, +1 symbol, +2 vault, +3 maxAge,
    ///   +4 corporateActionsVault, +5 actionTypeMask, +6 pauseTimeBefore|After.
    /// If this fails, do NOT renumber the expectations — fix the struct.
    function testMainStorageFieldOrderIsPinned() external {
        // Distinct values per field (in particular before != after) so a swap of
        // any two members is observable rather than masked by equal defaults.
        DIAVaultOracleConfig memory config = _defaultConfig();
        config.pauseTimeBefore = 1234;
        config.pauseTimeAfter = 7200;
        DIAVaultOracle oracle = _deployProxy(config);
        uint256 base = uint256(
            keccak256(abi.encode(uint256(keccak256("st0x.diavaultoracle.main")) - 1)) & ~bytes32(uint256(0xff))
        );

        assertEq(
            address(uint160(uint256(vm.load(address(oracle), bytes32(base + 0))))),
            address(diaOracle),
            "slot +0 must be diaOracle"
        );
        // Short strings store their bytes left-aligned with `2 * length` in the
        // lowest byte, all in the head slot.
        assertEq(
            vm.load(address(oracle), bytes32(base + 1)),
            bytes32(bytes(SYMBOL)) | bytes32(uint256(2 * bytes(SYMBOL).length)),
            "slot +1 must be the symbol string head"
        );
        assertEq(
            address(uint160(uint256(vm.load(address(oracle), bytes32(base + 2))))),
            address(vault),
            "slot +2 must be vault"
        );
        assertEq(uint256(vm.load(address(oracle), bytes32(base + 3))), MAX_AGE, "slot +3 must be maxAge");
        assertEq(
            address(uint160(uint256(vm.load(address(oracle), bytes32(base + 4))))),
            address(actions),
            "slot +4 must be corporateActionsVault"
        );
        assertEq(
            uint256(vm.load(address(oracle), bytes32(base + 5))),
            ACTION_TYPE_STOCK_SPLIT_V1,
            "slot +5 must be actionTypeMask"
        );
        uint256 packedWindows = uint256(vm.load(address(oracle), bytes32(base + 6)));
        assertEq(uint256(uint64(packedWindows)), uint256(1234), "slot +6 low word must be pauseTimeBefore");
        assertEq(uint256(uint64(packedWindows >> 64)), uint256(7200), "slot +6 second word must be pauseTimeAfter");
    }

    // -------- Init validation --------

    function testInitRevertsZeroDIAOracle() external {
        DIAVaultOracle oracle = _deployUninit();
        DIAVaultOracleConfig memory config = _defaultConfig();
        config.diaOracle = IDIAOracleV2(address(0));
        vm.expectRevert(ZeroDIAOracle.selector);
        oracle.initialize(abi.encode(config));
    }

    function testInitRevertsZeroVault() external {
        DIAVaultOracle oracle = _deployUninit();
        DIAVaultOracleConfig memory config = _defaultConfig();
        config.vault = address(0);
        vm.expectRevert(ZeroVault.selector);
        oracle.initialize(abi.encode(config));
    }

    function testInitRevertsZeroMaxAge() external {
        DIAVaultOracle oracle = _deployUninit();
        DIAVaultOracleConfig memory config = _defaultConfig();
        config.maxAge = 0;
        vm.expectRevert(ZeroMaxAge.selector);
        oracle.initialize(abi.encode(config));
    }

    function testInitRevertsEmptySymbol() external {
        DIAVaultOracle oracle = _deployUninit();
        DIAVaultOracleConfig memory config = _defaultConfig();
        config.symbol = "";
        vm.expectRevert(EmptySymbol.selector);
        oracle.initialize(abi.encode(config));
    }

    // -------- Init success --------

    function testInitSuccessSetsStorageEmitsAndReturnsSuccess() external {
        DIAVaultOracle oracle = _deployUninit();
        DIAVaultOracleConfig memory config = _defaultConfig();

        vm.expectEmit(true, false, false, true, address(oracle));
        emit DIAVaultOracleInitialized(address(this), config);

        bytes32 ok = oracle.initialize(abi.encode(config));
        assertEq(ok, ICLONEABLE_V2_SUCCESS);
        assertEq(address(oracle.diaOracle()), address(diaOracle));
        assertEq(oracle.symbol(), SYMBOL);
        assertEq(oracle.vault(), address(vault));
        assertEq(oracle.maxAge(), MAX_AGE);
        // The auto-pause config must be persisted verbatim — a stored mask or
        // window that drifts from config silently changes the pause behaviour.
        assertEq(
            oracle.corporateActionsVault(), address(actions), "corporate-actions vault must be the derived asset()"
        );
        assertEq(oracle.actionTypeMask(), ACTION_TYPE_STOCK_SPLIT_V1, "actionTypeMask must be stored verbatim");
        assertEq(oracle.pauseTimeBefore(), PAUSE_BEFORE, "pauseTimeBefore must be stored verbatim");
        assertEq(oracle.pauseTimeAfter(), PAUSE_AFTER, "pauseTimeAfter must be stored verbatim");
    }

    /// @notice The stored `actionTypeMask` must be the ONE applied to the
    /// auto-pause: a completed action whose type is NOT in the configured mask
    /// must NOT pause the oracle, even inside its post-window. Guards against a
    /// stored mask that silently broadens to the wildcard (`type(uint256).max`)
    /// — under which an unrelated action type would spuriously pause reads.
    function testConfiguredMaskExcludesNonMatchingActionType() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        diaOracle.setValue(SYMBOL, 100e18, uint64(block.timestamp));
        vault.setTotalAssets(1e18);
        vault.setTotalSupply(1e18);
        // A completed action of a DIFFERENT type, squarely inside its
        // post-window. The configured mask is STOCK_SPLIT only, so this must
        // NOT pause — the oracle prices normally.
        uint256 unrelatedType = 1 << 5;
        actions.setLatestCompleted(1, unrelatedType, uint64(block.timestamp - PAUSE_AFTER / 2));
        assertEq(oracle.latestAnswer(), 100e8, "action outside the configured mask must not pause");
    }

    // -------- Typed overload reverts --------

    function testTypedInitializeAlwaysReverts() external {
        // The typed overload is `pure` and MUST always revert per
        // `ICloneableV2`. Call against the implementation directly so we
        // don't burn an initializer slot on a real proxy.
        DIAVaultOracleConfig memory config = _defaultConfig();
        vm.expectRevert(ICloneableV2.InitializeSignatureFn.selector);
        implementation.initialize(config);
    }

    // -------- Constants --------

    function testConstants() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        assertEq(oracle.decimals(), 8);
        assertEq(oracle.description(), SYMBOL);
        assertEq(oracle.version(), 1);
    }

    /// @notice `description()` deliberately returns the BARE DIA feed symbol
    /// (e.g. `"COIN"`), NOT a Chainlink-style `"SYMBOL / USD"` pair string
    /// (issue #274). This pins that intentional deviation: the value must be
    /// the raw configured symbol byte-for-byte, and must NOT equal the
    /// pair-formatted `"COIN / USD"` a Chainlink consumer might assume. A
    /// regression that pair-formatted the description would fail here, and the
    /// interface NatSpec is worded to permit this so the two don't clash.
    function testDescriptionReturnsBareSymbolNotPairString() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        string memory desc = oracle.description();
        assertEq(desc, SYMBOL, "description must be the bare DIA symbol");
        assertTrue(
            keccak256(bytes(desc)) != keccak256(bytes(string.concat(SYMBOL, " / USD"))),
            "description must NOT be a Chainlink-style pair string"
        );
    }

    // -------- latestAnswer happy path --------

    function testLatestAnswerHappyPath() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        // DIA: $100 at 18dp.
        diaOracle.setValue(SYMBOL, 100e18, uint128(block.timestamp));
        // Vault: 2 assets per share.
        vault.setTotalAssets(2e18);
        vault.setTotalSupply(1e18);

        // 100 * 2 / 1 = 200, scaled to 8dp = 200e8.
        int256 answer = oracle.latestAnswer();
        assertEq(answer, int256(200e8));
    }

    /// @notice A share price that is not exactly representable at 8 decimals is
    /// TRUNCATED toward zero, never rounded up. Expected value derived from the
    /// spec, not from the implementation: `vaultSharePrice = diaPrice *
    /// totalAssets / totalSupply` = `$1 * 1e18 / 3e18` = `$0.3333...`, and 8dp
    /// floor of that is `33333333` (a round-half-up implementation would give
    /// `33333334`).
    ///
    /// Direction is the assertion. Truncation makes the oracle report slightly
    /// LESS than the true NAV, which is the conservative side for a lending
    /// market pricing collateral; rounding up would over-report collateral by up
    /// to 1 wei of price on every read. The existing happy-path tests all use
    /// exact powers of ten, so none of them can see this.
    function testLatestAnswerTruncatesFractionalSharePrice() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        diaOracle.setValue(SYMBOL, 1e18, uint128(block.timestamp));
        vault.setTotalAssets(1e18);
        vault.setTotalSupply(3e18);

        assertEq(oracle.latestAnswer(), int256(33333333), "1/3 of a dollar must truncate down at 8dp");

        // The same read path through latestRoundData agrees on the direction.
        (, int256 roundAnswer,,,) = oracle.latestRoundData();
        assertEq(roundAnswer, int256(33333333), "latestRoundData must truncate identically");
    }

    /// @notice Donations move the ratio and ARE served — the decided behaviour
    /// for issue #262, pinned so it cannot be silently reverted.
    ///
    /// The production `wtStock`'s `totalAssets()` is raw
    /// `IERC20(asset()).balanceOf(vault)`, so a direct transfer in moves the
    /// share ratio. Here `setTotalAssets` stands in for that balance growing.
    /// The oracle must price the new ratio straight through: a donation adds
    /// real assets the shares genuinely redeem for, so the higher price is
    /// CORRECT, not inflated — there is no phantom collateral to defend
    /// against, and the donor cannot withdraw what they gave.
    ///
    /// The assertion that matters is the absence of a gate. Any sanity band,
    /// drift limit or ratio anchor added to the read path would reject this
    /// jump and fail this test. That is deliberate: halting the oracle on an
    /// unexpected-but-real ratio stops liquidations while positions keep
    /// moving, which is worse for a lending market than pricing the true NAV.
    /// See the contract NatSpec ("Vault trust model").
    function testDonationMovesRatioAndIsServed() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        diaOracle.setValue(SYMBOL, 100e18, uint128(block.timestamp));
        vault.setTotalAssets(1e18);
        vault.setTotalSupply(1e18);
        assertEq(oracle.latestAnswer(), int256(100e8), "baseline 1 asset per share");

        // A donation doubles the vault's holdings against an unchanged supply.
        // Supply is unchanged because a bare transfer mints the donor nothing.
        vault.setTotalAssets(2e18);

        // Served, not rejected, and priced at the true new ratio.
        assertEq(oracle.latestAnswer(), int256(200e8), "donation must be priced through, not gated");

        // The same read path through latestRoundData agrees.
        (, int256 roundAnswer,,,) = oracle.latestRoundData();
        assertEq(roundAnswer, int256(200e8), "latestRoundData must agree with latestAnswer");
    }

    /// @notice DOWNWARD twin of `testDonationMovesRatioAndIsServed`, pinning
    /// the accepted risk the "Vault trust model" NatSpec documents: the same
    /// raw-`balanceOf` `totalAssets()` also moves DOWN when the upstream
    /// confiscation role seizes tStock from the wrapper — a bare transfer
    /// that burns no shares and creates no corporate-action node, so no pause
    /// window opens. The lower price is arithmetically CORRECT (the vault
    /// genuinely backs fewer assets per share) and must be served straight
    /// through. Any drift limit or ratio anchor added to the read path would
    /// reject this jump and fail this test — that is deliberate: halting the
    /// oracle stops liquidations while positions keep moving, which is worse
    /// for a lending market than pricing the true NAV.
    function testConfiscationDropsRatioAndIsServed() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        diaOracle.setValue(SYMBOL, 100e18, uint128(block.timestamp));
        vault.setTotalAssets(1e18);
        vault.setTotalSupply(1e18);
        assertEq(oracle.latestAnswer(), int256(100e8), "baseline 1 asset per share");

        // A confiscation halves the vault's holdings against an unchanged
        // supply — a bare transfer out mints and burns nothing.
        vault.setTotalAssets(0.5e18);

        // Served, not rejected, and priced at the true new ratio.
        assertEq(oracle.latestAnswer(), int256(50e8), "confiscation must be priced through, not gated");

        // The same read path through latestRoundData agrees.
        (, int256 roundAnswer,,,) = oracle.latestRoundData();
        assertEq(roundAnswer, int256(50e8), "latestRoundData must agree with latestAnswer");
    }

    // -------- latestAnswer DIA not set --------

    function testLatestAnswerRevertsDIAPriceNotSet() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        // Mock returns (0, 0) for an unset key by default.
        vault.setTotalAssets(1e18);
        vault.setTotalSupply(1e18);

        vm.expectRevert(DIAPriceNotSet.selector);
        oracle.latestAnswer();
    }

    // -------- latestAnswer stale --------

    function testLatestAnswerRevertsWhenStale() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        uint128 staleTimestamp = uint128(block.timestamp - MAX_AGE - 1);
        diaOracle.setValue(SYMBOL, 100e18, staleTimestamp);
        vault.setTotalAssets(1e18);
        vault.setTotalSupply(1e18);

        vm.expectRevert(abi.encodeWithSelector(DIAPriceStale.selector, uint256(staleTimestamp)));
        oracle.latestAnswer();
    }

    /// @notice A DIA push timestamped in the FUTURE (feed running ahead, or a
    /// chain-time regression / reorg) must NOT underflow-panic in the staleness
    /// subtraction. A future timestamp is fresh by construction (age 0), so the
    /// read resolves to the priced value, never a bare `Panic(0x11)`. Guards
    /// the `uint256(timestamp) <= block.timestamp` short-circuit in
    /// `_readDIAChecked`; a regression dropping that guard would revert here
    /// with an arithmetic panic instead of returning `100e8`.
    function testLatestAnswerFutureTimestampNotStale() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        // Timestamp 100s in the future relative to `now`.
        diaOracle.setValue(SYMBOL, 100e18, uint128(block.timestamp + 100));
        vault.setTotalAssets(1e18);
        vault.setTotalSupply(1e18);

        int256 answer = oracle.latestAnswer();
        assertEq(answer, int256(100e8), "future-timestamped push is fresh, not stale");
    }

    /// @notice The staleness edge fails closed: a push aged EXACTLY `maxAge`
    /// reverts `DIAPriceStale` (`age >= maxAge` is stale). This edge-rejection
    /// tightens the cross-epoch invariant by one second; the invariant itself is
    /// closed by the strict `pauseTimeAfter > maxAge` init margin — see the
    /// contract NatSpec.
    function testLatestAnswerAtMaxAgeBoundaryIsStale() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        uint128 boundary = uint128(block.timestamp - MAX_AGE);
        diaOracle.setValue(SYMBOL, 100e18, boundary);
        vault.setTotalAssets(1e18);
        vault.setTotalSupply(1e18);

        vm.expectRevert(abi.encodeWithSelector(DIAPriceStale.selector, uint256(boundary)));
        oracle.latestAnswer();
    }

    /// @notice One second inside the window (`age == maxAge - 1`) is still
    /// fresh and prices normally — pins the just-inside side of the edge.
    function testLatestAnswerJustInsideMaxAgeNotStale() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        uint128 justFresh = uint128(block.timestamp - MAX_AGE + 1);
        diaOracle.setValue(SYMBOL, 100e18, justFresh);
        vault.setTotalAssets(1e18);
        vault.setTotalSupply(1e18);

        assertEq(oracle.latestAnswer(), int256(100e8));
    }

    /// @notice The composed cross-epoch invariant: the pause and staleness
    /// guards hand over with no gap, so a PRE-action DIA push is never served
    /// once the pause lifts.
    ///
    /// The two guards are pinned independently above; this drives the real
    /// `MockCorporateActions` through the handover instant and proves the
    /// windows abut rather than leaving a servable instant between them. With a
    /// completed split at `effectiveTime` and the last pre-action push
    /// timestamped at `effectiveTime`:
    /// - at `effectiveTime + pauseTimeAfter` (the last paused instant — the
    ///   post-window is inclusive) the pause gate rejects the read;
    /// - at `effectiveTime + pauseTimeAfter + 1` (the first unpaused instant)
    ///   the pause is off, but the push is now aged `pauseTimeAfter + 1`, which
    ///   under the enforced `pauseTimeAfter > maxAge` exceeds `maxAge`, so the
    ///   staleness check rejects it.
    ///
    /// A gap here is exactly the HIGH this file's fix addresses: serving a
    /// pre-split price after a 2:1 split reads 2x the true value and mints bad
    /// debt in downstream lending markets.
    ///
    /// This concrete case pins pushes stamped at or before `effectiveTime`;
    /// the all-config version is fuzzed in `testFuzzPreActionPriceNeverServed`,
    /// and the forward-skew case in `testForwardSkewIsRejectedWithinMargin`.
    function testPreActionPriceNeverServedAcrossPauseHandover() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        vault.setTotalAssets(1e18);
        vault.setTotalSupply(1e18);

        uint64 effectiveTime = uint64(block.timestamp);
        actions.setLatestCompleted(1, ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);
        // The last push of the OLD epoch, timestamped exactly at the action.
        diaOracle.setValue(SYMBOL, 100e18, effectiveTime);

        // Last paused instant — the pause gate rejects, ahead of any DIA read.
        vm.warp(uint256(effectiveTime) + PAUSE_AFTER);
        vm.expectRevert(abi.encodeWithSelector(OraclePausedCorporateAction.selector, effectiveTime));
        oracle.latestAnswer();

        // First unpaused instant — pause is off, so staleness must catch it.
        vm.warp(uint256(effectiveTime) + PAUSE_AFTER + 1);
        vm.expectRevert(abi.encodeWithSelector(DIAPriceStale.selector, uint256(effectiveTime)));
        oracle.latestAnswer();

        // Positive control: at that same instant a strictly POST-action push is
        // served normally, so the handover rejects only genuinely pre-action
        // data rather than bricking the oracle outright.
        diaOracle.setValue(SYMBOL, 50e18, uint64(block.timestamp - MAX_AGE + 1));
        assertEq(oracle.latestAnswer(), int256(50e8), "post-action price prices normally once the pause lifts");
    }

    /// @notice The cross-epoch invariant in its strongest form: for ANY config
    /// accepted by `initialize` and at ANY instant from the action onward, a DIA
    /// push timestamped at or before a completed action's `effectiveTime` is
    /// never served — the read always reverts, either paused or stale.
    ///
    /// This is the property the `pauseTimeAfter > maxAge` init check exists to
    /// buy for pushes observed no later than the action. Fuzzing it sweeps the
    /// read across the whole paused-to-stale transition at a tight positive
    /// margin, so any widening of the staleness edge or narrowing of the pause
    /// window opens a servable instant and fails this test.
    ///
    /// Scope: the push here is stamped at or BEFORE `effectiveTime`. A push
    /// stamped AFTER `effectiveTime` by forward feed clock skew is a separate
    /// case whose tolerance is the config margin — see
    /// `testForwardSkewIsRejectedWithinMargin`.
    ///
    /// Reverting is the whole assertion: a returned price at any point in this
    /// range is a pre-action equity price paired with a post-action NAV ratio.
    function testFuzzPreActionPriceNeverServed(
        uint64 maxAgeSeconds,
        uint64 extraPause,
        uint64 pauseBefore,
        uint64 pushOffset,
        uint64 elapsed
    ) external {
        maxAgeSeconds = uint64(bound(maxAgeSeconds, 1, 7 days));
        // `pauseTimeAfter > maxAge` (strict) is the enforced invariant, so the
        // margin is at least 1. Keep it TIGHT: the property can only break where
        // the two windows meet, and a wide margin is the trivially-safe case the
        // fuzzer would waste runs on.
        extraPause = uint64(bound(extraPause, 1, 4));
        uint64 pauseAfter = maxAgeSeconds + extraPause;
        pauseBefore = uint64(bound(pauseBefore, 1, 30 days));
        // The push is pre-action: at or just before `effectiveTime`. Pushes far
        // earlier are strictly staler, so the tight offsets are the hard cases.
        pushOffset = uint64(bound(pushOffset, 0, 3));
        // Sweep a tight neighbourhood of the pause-lift instant. Outside it the
        // read is trivially paused (earlier) or trivially stale (later — age
        // only grows), so widening this only dilutes the runs that matter.
        uint256 lift = uint256(pauseAfter);
        elapsed = uint64(bound(elapsed, lift > 4 ? lift - 4 : 0, lift + 4));

        // Base far enough in that no timestamp arithmetic underflows.
        uint64 effectiveTime = uint64(365 days * 10);
        vm.warp(effectiveTime);

        DIAVaultOracleConfig memory config = _defaultConfig();
        config.maxAge = maxAgeSeconds;
        config.pauseTimeBefore = pauseBefore;
        config.pauseTimeAfter = pauseAfter;
        DIAVaultOracle oracle = _deployProxy(config);

        vault.setTotalAssets(1e18);
        vault.setTotalSupply(1e18);
        actions.setLatestCompleted(1, ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);
        diaOracle.setValue(SYMBOL, 100e18, effectiveTime - pushOffset);

        vm.warp(uint256(effectiveTime) + elapsed);

        (bool served, bytes memory ret) = address(oracle).staticcall(abi.encodeCall(DIAVaultOracle.latestAnswer, ()));
        assertFalse(served, "pre-action DIA push must never be served after the action");
        // And it must fail for one of the two intended reasons, not incidentally
        // (e.g. an arithmetic revert), which would mask a real gap.
        bytes4 reason = bytes4(ret);
        assertTrue(
            reason == OraclePausedCorporateAction.selector || reason == DIAPriceStale.selector,
            "must revert paused or stale, not incidentally"
        );
    }

    /// @notice The cross-epoch fix in its precise form: the config margin
    /// (`pauseTimeAfter - maxAge`) is exactly the forward feed clock skew the
    /// deployment tolerates. A pre-action push stamped up to `margin` seconds
    /// AFTER `effectiveTime` (as a fast feed would stamp a last pre-split
    /// observation) is rejected at pause-lift; a push skewed BEYOND the margin
    /// is the residual the operator must size the margin against.
    ///
    /// This is what enforcing a strictly-positive margin buys, and why equality
    /// (zero margin, zero skew tolerance) is rejected at init. With margin M, a
    /// push stamped `E + δ` has age `pauseTimeAfter + 1 - δ` at the first
    /// unpaused instant, which is `>= maxAge` (stale) exactly while `δ <= M + 1`.
    function testForwardSkewIsRejectedWithinMargin() external {
        // maxAge 1h, pauseAfter 1h + 10s: this config tolerates ~10s of skew.
        uint64 maxAge = 1 hours;
        uint64 margin = 10;
        DIAVaultOracleConfig memory config = _defaultConfig();
        config.maxAge = maxAge;
        config.pauseTimeAfter = maxAge + margin;

        uint64 E = uint64(block.timestamp);

        // A pre-action observation stamped `margin` seconds ahead by a fast
        // feed. Within tolerance -> must be rejected (stale) at pause-lift.
        DIAVaultOracle o1 = _deployProxy(config);
        vault.setTotalAssets(1e18);
        vault.setTotalSupply(1e18);
        actions.setLatestCompleted(1, ACTION_TYPE_STOCK_SPLIT_V1, E);
        diaOracle.setValue(SYMBOL, 100e18, uint128(uint256(E) + margin));
        vault.setTotalAssets(2e18); // 2:1 split
        vm.warp(uint256(E) + uint256(config.pauseTimeAfter) + 1);
        (bool served,) = address(o1).staticcall(abi.encodeCall(DIAVaultOracle.latestAnswer, ()));
        assertFalse(served, "a push skewed within the margin must be rejected, not served at 2x");

        // Skewed BEYOND the margin (margin + 2): this is the documented residual
        // — the operator's margin was too small for this feed's skew, so the
        // stale pre-split price IS served. Pinning it keeps the tolerance
        // boundary honest rather than implying any positive margin is safe.
        vm.warp(E);
        DIAVaultOracle o2 = _deployProxy(config);
        vault.setTotalAssets(1e18);
        vault.setTotalSupply(1e18);
        actions.setLatestCompleted(1, ACTION_TYPE_STOCK_SPLIT_V1, E);
        diaOracle.setValue(SYMBOL, 100e18, uint128(uint256(E) + margin + 2));
        vault.setTotalAssets(2e18);
        vm.warp(uint256(E) + uint256(config.pauseTimeAfter) + 1);
        assertEq(o2.latestAnswer(), int256(200e8), "skew beyond the margin is the operator-owned residual");
    }

    /// @notice `_readDIAChecked` reverts `DIAPriceNotSet` when the DIA value is
    /// zero even if the timestamp is non-zero — the value-zero and timestamp-zero
    /// terms of the not-set check are independent, so a mutant dropping the
    /// value-zero term would price off a zero value.
    function testLatestAnswerRevertsDIAValueZeroTimestampNonZero() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        diaOracle.setValue(SYMBOL, 0, uint128(block.timestamp)); // value 0, ts non-zero
        vault.setTotalAssets(1e18);
        vault.setTotalSupply(1e18);
        vm.expectRevert(DIAPriceNotSet.selector);
        oracle.latestAnswer();
    }

    /// @notice Symmetric to the above: a zero timestamp reverts `DIAPriceNotSet`
    /// (never-published), NOT `DIAPriceStale`, even when the value is non-zero.
    function testLatestAnswerRevertsDIAValueNonZeroTimestampZero() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        diaOracle.setValue(SYMBOL, 100e18, 0); // value non-zero, ts 0
        vault.setTotalAssets(1e18);
        vault.setTotalSupply(1e18);
        vm.expectRevert(DIAPriceNotSet.selector);
        oracle.latestAnswer();
    }

    /// @notice A very large but in-range 8dp price (5e76 < int256.max ~5.79e76)
    /// is RETURNED, not rejected by the overflow guard — pins the non-revert
    /// side of the `price8 > int256.max` boundary.
    function testLatestAnswerLargePriceBelowIntMaxReturns() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        diaOracle.setValue(SYMBOL, 1e38, uint128(block.timestamp));
        vault.setTotalAssets(5e48);
        vault.setTotalSupply(1);
        assertEq(oracle.latestAnswer(), int256(5e76));
    }

    // -------- latestAnswer zero supply --------

    function testLatestAnswerRevertsZeroSupply() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        diaOracle.setValue(SYMBOL, 100e18, uint128(block.timestamp));
        vault.setTotalAssets(2e18);
        vault.setTotalSupply(0);

        vm.expectRevert(ZeroVaultSupply.selector);
        oracle.latestAnswer();
    }

    // -------- latestAnswer zero share price --------

    function testLatestAnswerRevertsZeroSharePrice() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        // diaPrice = 1 (raw uint with 18dp = 1e-18 USD).
        // totalAssets = 1, totalSupply = 1e18 → ratio = 1e-18.
        // Final = 1e-18 * 1e-18 = 1e-36, scaled to 8dp -> 0.
        diaOracle.setValue(SYMBOL, 1, uint128(block.timestamp));
        vault.setTotalAssets(1);
        vault.setTotalSupply(1e18);

        vm.expectRevert(ZeroVaultSharePrice.selector);
        oracle.latestAnswer();
    }

    // -------- latestAnswer overflow --------

    /// @notice Drive the computed 8-decimal share price above `int256.max` so
    /// the `int256(price8)` cast would be unsafe, and assert the contract
    /// reverts `VaultSharePriceOverflow` instead of returning a wrapped
    /// negative price. A regression that dropped the overflow guard (returning
    /// `int256(price8)` directly) would produce a garbage negative answer and
    /// fail this test.
    ///
    /// Magnitude: the 8dp share price must land strictly BETWEEN int256.max
    /// (~5.79e76) and uint256.max (~1.16e77) — below the lower bound the value
    /// fits an int256 and no revert fires; above the upper bound the earlier
    /// `toFixedDecimalLossy(_, 8)` step itself reverts `FixedDecimalOverflow`
    /// before the guard is reached. diaPrice raw = 1e38 (natural 1e20 at 18dp),
    /// totalAssets = 7e48, totalSupply = 1 → natural 7e68 → 8dp 7e76, which sits
    /// in that window. All operands are clean powers-of-ten so BOTH the
    /// intermediate `fromFixedDecimalLosslessPacked` and the final 8dp
    /// conversion are lossless, giving an exact `price8 == 7e76` — so we assert
    /// the full selector + args rather than the bare selector.
    function testLatestAnswerRevertsVaultSharePriceOverflow() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        diaOracle.setValue(SYMBOL, 1e38, uint128(block.timestamp));
        vault.setTotalAssets(7e48);
        vault.setTotalSupply(1);

        vm.expectRevert(abi.encodeWithSelector(VaultSharePriceOverflow.selector, uint256(7e76)));
        oracle.latestAnswer();
    }

    /// @notice The UPPER overflow band the NatSpec distinguishes: a share price
    /// so large it exceeds uint256 during the 8-decimal scaling aborts EARLIER,
    /// inside `LibDecimalFloat`, with its own `FixedDecimalOverflow` — before the
    /// contract's own int256-band `VaultSharePriceOverflow` guard is reached.
    /// Pins that this fails CLOSED (reverts) rather than wrapping to a wrong
    /// positive answer. diaPrice raw 1e38 (natural 1e20) * totalAssets 1e60 /
    /// totalSupply 1 = natural 1e80 → 8dp 1e88, past uint256.max (~1.16e77).
    /// Selector-only: the library error's args are internal.
    function testLatestAnswerRevertsFixedDecimalOverflowAboveUintMax() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        diaOracle.setValue(SYMBOL, 1e38, uint128(block.timestamp));
        vault.setTotalAssets(1e60);
        vault.setTotalSupply(1);

        // Assert the exact selector (not a bare revert). The library error
        // carries internal args (coefficient/exponent/decimals), so match on
        // the selector to stay robust to those while still pinning that this
        // fails closed as FixedDecimalOverflow rather than wrapping.
        (bool ok, bytes memory ret) = address(oracle).staticcall(abi.encodeCall(DIAVaultOracle.latestAnswer, ()));
        assertFalse(ok, "must revert, not return a wrapped answer");
        assertEq(bytes4(ret), FixedDecimalOverflow.selector, "upper overflow band must revert FixedDecimalOverflow");
    }

    // -------- latestRoundData --------

    function testLatestRoundData() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        uint128 timestamp = uint128(block.timestamp - 5);
        diaOracle.setValue(SYMBOL, 100e18, timestamp);
        vault.setTotalAssets(2e18);
        vault.setTotalSupply(1e18);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            oracle.latestRoundData();

        assertEq(answer, int256(200e8));
        assertEq(uint256(roundId), uint256(timestamp));
        assertEq(uint256(answeredInRound), uint256(timestamp));
        assertEq(startedAt, uint256(timestamp));
        assertEq(updatedAt, uint256(timestamp));
    }

    /// @notice A future-dated DIA push (a feed running ahead — accepted as fresh
    /// by `_readDIAChecked`) must NOT propagate a future `updatedAt`/`startedAt`
    /// through `latestRoundData`: they are clamped to `block.timestamp` so a
    /// Chainlink-style consumer computing `block.timestamp - updatedAt` reads
    /// age 0 instead of underflow-reverting. `roundId` still reflects the raw
    /// push timestamp (freshness token). Issue: C3.
    function testLatestRoundDataClampsFutureTimestamp() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        uint128 futureTs = uint128(block.timestamp + 100);
        diaOracle.setValue(SYMBOL, 100e18, futureTs);
        vault.setTotalAssets(1e18);
        vault.setTotalSupply(1e18);

        (uint80 roundId,, uint256 startedAt, uint256 updatedAt,) = oracle.latestRoundData();
        assertEq(updatedAt, block.timestamp, "updatedAt clamped to now, never ahead of the block clock");
        assertEq(startedAt, block.timestamp, "startedAt clamped identically");
        assertLe(updatedAt, block.timestamp, "updatedAt must never exceed block.timestamp");
        assertEq(uint256(roundId), uint256(futureTs), "roundId still tracks the raw push timestamp");
    }

    function testLatestRoundDataMatchesLatestAnswer() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        diaOracle.setValue(SYMBOL, 123e18, uint128(block.timestamp));
        vault.setTotalAssets(7e18);
        vault.setTotalSupply(3e18);

        int256 expected = oracle.latestAnswer();
        (, int256 answer,,,) = oracle.latestRoundData();
        assertEq(answer, expected);
    }

    // -------- getRoundData always reverts --------

    function testGetRoundDataAlwaysReverts(uint80 roundId) external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        vm.expectRevert(abi.encodeWithSelector(HistoricalRoundDataUnsupported.selector, roundId));
        oracle.getRoundData(roundId);
    }

    // -------- initializer modifier --------

    function testCannotInitializeTwice() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        oracle.initialize(abi.encode(_defaultConfig()));
    }

    function testImplementationCannotBeInitialized() external {
        // Constructor calls `_disableInitializers()` — direct calls to the
        // implementation must revert.
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(abi.encode(_defaultConfig()));
    }
}
