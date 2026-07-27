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
import {TestERC1967Proxy} from "../../../mocks/TestERC1967Proxy.sol";
import {ACTION_TYPE_STOCK_SPLIT_V1, ACTION_TYPE_INIT_V1} from "st0x-deploy-0.1.1/src/interface/ICorporateActionsV1.sol";

contract DIAVaultOracleTest is Test {
    DIAVaultOracle internal implementation;
    MockDIAOracle internal diaOracle;
    MockERC4626 internal vault;
    MockCorporateActions internal actions;
    string internal constant SYMBOL = "COIN";
    uint256 internal constant MAX_AGE = 1 hours;
    uint64 internal constant PAUSE_BEFORE = 3600;
    uint64 internal constant PAUSE_AFTER = 3600;

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

    function testInitRevertsBothWindowsZero() external {
        DIAVaultOracleConfig memory config = _defaultConfig();
        config.pauseTimeBefore = 0;
        config.pauseTimeAfter = 0;
        DIAVaultOracle oracle = _deployUninit();
        vm.expectRevert(InvalidPauseConfig.selector);
        oracle.initialize(abi.encode(config));
    }

    /// @notice A pre-window-ONLY config (`pauseTimeAfter == 0`) is REJECTED: it
    /// violates the cross-epoch invariant `pauseTimeAfter >= maxAge`. With no
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

    /// @notice A post-window-only config (`pauseTimeBefore == 0`) is valid as
    /// long as `pauseTimeAfter >= maxAge`. The default `PAUSE_AFTER == MAX_AGE`
    /// sits exactly on the boundary, which init accepts.
    function testInitSucceedsWithOnlyPostWindow() external {
        DIAVaultOracleConfig memory config = _defaultConfig();
        config.pauseTimeBefore = 0;
        config.pauseTimeAfter = PAUSE_AFTER;
        DIAVaultOracle oracle = _deployUninit();
        bytes32 ok = oracle.initialize(abi.encode(config));
        assertEq(ok, ICLONEABLE_V2_SUCCESS, "post-window-only config must be accepted");
        assertEq(oracle.pauseTimeBefore(), 0);
        assertEq(oracle.pauseTimeAfter(), PAUSE_AFTER);
    }

    /// @notice The cross-epoch invariant is enforced at init: `pauseTimeAfter`
    /// strictly below `maxAge` reverts `PauseTimeAfterBelowMaxAge`, and the
    /// exact boundary `pauseTimeAfter == maxAge` is accepted.
    function testInitRevertsWhenPauseAfterBelowMaxAge() external {
        DIAVaultOracleConfig memory config = _defaultConfig();
        config.maxAge = 2 hours;
        config.pauseTimeAfter = uint64(2 hours) - 1; // one second short
        DIAVaultOracle oracle = _deployUninit();
        vm.expectRevert(
            abi.encodeWithSelector(PauseTimeAfterBelowMaxAge.selector, uint256(2 hours) - 1, uint256(2 hours))
        );
        oracle.initialize(abi.encode(config));
    }

    function testInitAcceptsPauseAfterEqualToMaxAge() external {
        DIAVaultOracleConfig memory config = _defaultConfig();
        config.maxAge = 2 hours;
        config.pauseTimeAfter = uint64(2 hours); // exactly on the boundary
        DIAVaultOracle oracle = _deployUninit();
        bytes32 ok = oracle.initialize(abi.encode(config));
        assertEq(ok, ICLONEABLE_V2_SUCCESS, "pauseTimeAfter == maxAge is on the safe boundary");
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

    function testLatestAnswerAtMaxAgeBoundaryNotStale() external {
        // `block.timestamp - timestamp > maxAge` reverts — equal is OK.
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        uint128 boundary = uint128(block.timestamp - MAX_AGE);
        diaOracle.setValue(SYMBOL, 100e18, boundary);
        vault.setTotalAssets(1e18);
        vault.setTotalSupply(1e18);

        int256 answer = oracle.latestAnswer();
        assertEq(answer, int256(100e8));
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
