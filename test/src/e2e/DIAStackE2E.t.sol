// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.1/src/Test.sol";
import {IDIAOracleV2} from "../../../src/interface/IDIAOracleV2.sol";
import {
    DIAVaultOracle,
    DIAVaultOracleConfig,
    DIAPriceNotSet,
    DIAPriceStale
} from "../../../src/concrete/oracle/DIAVaultOracle.sol";
import {
    PausableOracleWrapper,
    CorporateActionPauseConfig,
    OraclePausedManual,
    OraclePausedCorporateAction
} from "../../../src/concrete/wrapper/PausableOracleWrapper.sol";
import {
    DIAVaultOracleBeaconSetDeployer,
    DIAVaultOracleBeaconSetDeployerConfig
} from "../../../src/concrete/deploy/DIAVaultOracleBeaconSetDeployer.sol";
import {
    PausableOracleWrapperBeaconSetDeployer,
    PausableOracleWrapperBeaconSetDeployerConfig
} from "../../../src/concrete/deploy/PausableOracleWrapperBeaconSetDeployer.sol";
import {
    DIAOracleUnifiedDeployer,
    DIAOracleUnifiedDeployerConstructorConfig,
    DIAOracleUnifiedDeployConfig
} from "../../../src/concrete/deploy/DIAOracleUnifiedDeployer.sol";
import {MockDIAOracle} from "../../mocks/MockDIAOracle.sol";
import {MockERC4626} from "../../mocks/MockERC4626.sol";
import {MockCorporateActions} from "../../mocks/MockCorporateActions.sol";
import {NODE_NONE} from "st0x-deploy-0.1.1/src/lib/LibCorporateActionNode.sol";

/// @title DIAStackE2ETest
/// @notice End-to-end happy-path + pause-path exercise of the production
/// deploy graph for the DIA oracle stack. Mints a `(oracle, wrapper)` pair
/// through `DIAOracleUnifiedDeployer` (composed over the two beacon-set
/// deployers) and drives scenarios entirely through the wrapper surface —
/// no shortcut into manually-constructed wrappers or oracles.
///
/// Complements the per-component unit tests under
/// `test/src/concrete/{oracle,wrapper,deploy}/` by proving the full graph
/// wires up correctly and behaves as a coherent whole.
contract DIAStackE2ETest is Test {
    MockDIAOracle internal diaOracle;
    MockERC4626 internal vault;
    MockCorporateActions internal corporateActions;
    DIAVaultOracle internal oracle;
    PausableOracleWrapper internal wrapper;
    address internal admin = address(0xA11CE);

    string internal constant SYMBOL = "COIN";
    uint256 internal constant MAX_AGE = 2 hours;
    uint64 internal constant PAUSE_BEFORE = 1 hours;
    uint64 internal constant PAUSE_AFTER = 1 hours;

    function setUp() public {
        diaOracle = new MockDIAOracle();
        vault = new MockERC4626();
        corporateActions = new MockCorporateActions();

        DIAVaultOracleBeaconSetDeployer oracleBSD = new DIAVaultOracleBeaconSetDeployer(
            DIAVaultOracleBeaconSetDeployerConfig({
                initialOwner: address(this), initialDIAVaultOracleImplementation: address(new DIAVaultOracle())
            })
        );
        PausableOracleWrapperBeaconSetDeployer wrapperBSD = new PausableOracleWrapperBeaconSetDeployer(
            PausableOracleWrapperBeaconSetDeployerConfig({
                initialOwner: address(this),
                initialPausableOracleWrapperImplementation: address(new PausableOracleWrapper())
            })
        );
        DIAOracleUnifiedDeployer unifiedDeployer = new DIAOracleUnifiedDeployer(
            DIAOracleUnifiedDeployerConstructorConfig({
                diaVaultOracleBeaconSetDeployer: oracleBSD, pausableOracleWrapperBeaconSetDeployer: wrapperBSD
            })
        );

        // Warp far enough in that `block.timestamp - maxAge` and the various
        // pre/post pause windows can be exercised without underflow.
        vm.warp(1_000_000);

        (oracle, wrapper) = unifiedDeployer.newOracleWithWrapper(
            DIAOracleUnifiedDeployConfig({
                admin: admin,
                oracleConfig: DIAVaultOracleConfig({
                    diaOracle: IDIAOracleV2(address(diaOracle)), symbol: SYMBOL, vault: address(vault), maxAge: MAX_AGE
                }),
                pauseConfig: CorporateActionPauseConfig({
                    corporateActionsVault: address(corporateActions),
                    actionTypeMask: type(uint256).max,
                    pauseTimeBefore: PAUSE_BEFORE,
                    pauseTimeAfter: PAUSE_AFTER
                })
            })
        );
    }

    /// @dev Scripts DIA to a fresh $100 reading at the current block.
    function _freshDIAAt100() internal {
        diaOracle.setValue(SYMBOL, 100e18, uint128(block.timestamp));
    }

    /// @dev Vault with 1:1 assets-per-share — `latestAnswer` mirrors the
    /// DIA price scaled to 8 decimals.
    function _flatVault() internal {
        vault.setTotalAssets(1e18);
        vault.setTotalSupply(1e18);
    }

    // -------- Scenario 1: happy path single price read --------

    function testHappyPathSinglePriceRead() external {
        _freshDIAAt100();
        _flatVault();

        assertEq(wrapper.latestAnswer(), int256(100e8), "wrapper latestAnswer");
        assertEq(wrapper.decimals(), uint8(8), "wrapper decimals delegated from oracle");
        assertEq(wrapper.description(), SYMBOL, "wrapper description delegated from oracle (DIA symbol)");
        assertEq(wrapper.version(), uint256(1), "wrapper version delegated from oracle");
    }

    // -------- Scenario 2: wtStock NAV bump propagates --------

    function testWtStockNavBumpPropagates() external {
        _freshDIAAt100();
        _flatVault();

        // Baseline read: $100 underlying * 1.0 assets-per-share = $100.
        assertEq(wrapper.latestAnswer(), int256(100e8), "pre-bump");

        // Corporate action lands and wtStock NAV doubles — same shares now
        // claim 2× the underlying. The vault's `totalAssets` doubles while
        // `totalSupply` stays put.
        vault.setTotalAssets(2e18);

        assertEq(wrapper.latestAnswer(), int256(200e8), "post-bump");
    }

    // -------- Scenario 3: DIA timestamp appears in roundData --------

    function testDIATimestampAppearsInRoundData() external {
        // Pick a wall-clock and a slightly older DIA push; the timestamp must
        // surface through every relevant field of `latestRoundData`.
        uint256 t = 2_000_000;
        vm.warp(t);
        uint128 diaTs = uint128(t - 100);
        diaOracle.setValue(SYMBOL, 100e18, diaTs);
        _flatVault();

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            wrapper.latestRoundData();

        assertEq(roundId, uint80(diaTs), "roundId == timestamp");
        assertEq(answer, int256(100e8), "answer");
        assertEq(startedAt, uint256(diaTs), "startedAt == timestamp");
        assertEq(updatedAt, uint256(diaTs), "updatedAt == timestamp");
        assertEq(answeredInRound, uint80(diaTs), "answeredInRound == timestamp");
    }

    // -------- Scenario 4: manual pause blocks reads, unpause restores --------

    function testManualPauseBlocksReadsAndUnpauseRestores() external {
        _freshDIAAt100();
        _flatVault();

        // Sanity: reads work before pause.
        assertEq(wrapper.latestAnswer(), int256(100e8));

        vm.prank(admin);
        wrapper.setPaused(true);

        vm.expectRevert(OraclePausedManual.selector);
        wrapper.latestAnswer();

        vm.expectRevert(OraclePausedManual.selector);
        wrapper.latestRoundData();

        vm.prank(admin);
        wrapper.setPaused(false);

        // Reads should be back, with the same values.
        assertEq(wrapper.latestAnswer(), int256(100e8), "post-unpause latestAnswer");
        (, int256 answer,,,) = wrapper.latestRoundData();
        assertEq(answer, int256(100e8), "post-unpause latestRoundData answer");
    }

    // -------- Scenario 5: corporate-action auto-pause propagates --------

    function testCorporateActionAutoPausePropagatesFullStack() external {
        _freshDIAAt100();
        _flatVault();

        // No scheduled action — reads work cleanly.
        assertEq(wrapper.latestAnswer(), int256(100e8), "pre-schedule reads");

        // Schedule a pending action 30 minutes out. Pre-window is 1 hour, so
        // we're squarely inside it.
        uint64 effectiveTime = uint64(block.timestamp + 30 minutes);
        corporateActions.setEarliestPending(1, type(uint256).max, effectiveTime);

        vm.expectRevert(abi.encodeWithSelector(OraclePausedCorporateAction.selector, effectiveTime));
        wrapper.latestAnswer();

        // Warp past `effectiveTime` but stay inside the 1-hour post-window.
        // Transition the mock from "pending" to "completed" — that mirrors
        // what the real corporate-actions vault would do once the action's
        // effective time passes and the operator marks it complete.
        vm.warp(uint256(effectiveTime) + 15 minutes);
        // Keep DIA fresh against the new wall-clock so a staleness revert
        // can't mask the pause-window assertion below.
        _freshDIAAt100();
        corporateActions.setEarliestPending(NODE_NONE, 0, 0);
        corporateActions.setLatestCompleted(1, type(uint256).max, effectiveTime);

        vm.expectRevert(abi.encodeWithSelector(OraclePausedCorporateAction.selector, effectiveTime));
        wrapper.latestAnswer();

        // Warp past the 1-hour post-window. Reads work again.
        vm.warp(uint256(effectiveTime) + uint256(PAUSE_AFTER) + 1);
        _freshDIAAt100();

        assertEq(wrapper.latestAnswer(), int256(100e8), "post-window reads restored");
    }

    // -------- Scenario 6: manual pause takes precedence over corp action --------

    function testManualPauseTakesPrecedenceOverCorporateAction() external {
        _freshDIAAt100();
        _flatVault();

        uint64 effectiveTime = uint64(block.timestamp + 30 minutes);
        corporateActions.setEarliestPending(1, type(uint256).max, effectiveTime);

        vm.prank(admin);
        wrapper.setPaused(true);

        // Both conditions are true — the manual selector wins because it's
        // checked first (cheaper SLOAD, and the admin-set flag is the more
        // explicit signal).
        vm.expectRevert(OraclePausedManual.selector);
        wrapper.latestAnswer();
    }

    // -------- Scenario 7a: DIA never pushed propagates --------

    function testDIAPriceNotSetPropagates() external {
        _flatVault();

        // DIA was never poked for SYMBOL — the mock returns (0, 0) and the
        // adapter's never-pushed check fires. Wrapper passes the revert
        // straight through without catching.
        vm.expectRevert(DIAPriceNotSet.selector);
        wrapper.latestAnswer();
    }

    // -------- Scenario 7b: stale DIA propagates through wrapper --------

    function testStaleDIAPropagatesToCaller() external {
        _flatVault();

        // DIA was last pushed just over `maxAge` ago — the adapter's
        // staleness check fires and the wrapper passes the revert straight
        // through without catching.
        uint128 staleTimestamp = uint128(block.timestamp - MAX_AGE - 1);
        diaOracle.setValue(SYMBOL, 100e18, staleTimestamp);

        vm.expectRevert(abi.encodeWithSelector(DIAPriceStale.selector, uint256(staleTimestamp)));
        wrapper.latestAnswer();
    }
}
