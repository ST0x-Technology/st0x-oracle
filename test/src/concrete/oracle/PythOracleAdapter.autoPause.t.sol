// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Vm} from "forge-std/Test.sol";
import {PythOracleAdapterTest} from "test/abstract/PythOracleAdapterTest.sol";
import {MockCorporateActions} from "test/mocks/MockCorporateActions.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPyth} from "pyth-sdk/IPyth.sol";
import {PythStructs} from "pyth-sdk/PythStructs.sol";
import {LibPyth} from "rain.pyth/src/lib/pyth/LibPyth.sol";
import {ACTION_TYPE_STOCK_SPLIT_V1} from "st0x.deploy/src/interface/ICorporateActionsV1.sol";
import {
    CorporateActionPauseConfig,
    OraclePausedManual,
    OraclePausedCorporateAction,
    HistoricalRoundDataUnsupported
} from "st0x.oracle/abstract/BasePythOracleAdapter.sol";
import {PythOracleAdapter} from "st0x.oracle/concrete/oracle/PythOracleAdapter.sol";

/// @dev Base chain ID.
uint256 constant BASE_CHAIN_ID = 8453;

/// @dev Arbitrary Pyth feed ID (response is fully mocked).
bytes32 constant MOCK_PRICE_ID = bytes32(uint256(0xdeadbeef));

/// @dev Pyth contract address on Base (from `LibPyth`). We mock at this
/// address so the runtime call resolves correctly regardless of fork state.
address constant PYTH_BASE = 0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a;

/// @title PythOracleAdapterAutoPauseTest
/// @notice Adapter-level tests verifying that `BasePythOracleAdapter` wires
/// the corporate-action auto-pause through to `latestAnswer` and
/// `latestRoundData`. The lib's algorithmic correctness is covered in
/// `test/src/lib/LibCorporateActionsPause.t.sol`; here we check the
/// integration: error selectors, precedence with manual pause, and that
/// `corporateActionsVault == address(0)` short-circuits the read entirely.
contract PythOracleAdapterAutoPauseTest is PythOracleAdapterTest {
    MockCorporateActions internal mock;
    address internal mockVault;

    uint64 internal constant PAUSE_BEFORE = 3600;
    uint64 internal constant PAUSE_AFTER = 3600;

    function setUp() external {
        vm.chainId(BASE_CHAIN_ID);
        vm.warp(1_700_000_000);
        mock = new MockCorporateActions();
        mockVault = address(uint160(uint256(keccak256("vault.autopause"))));
        // Vault ratio mocks — every test exercises the same 1:1 vault.
        vm.mockCall(mockVault, abi.encodeWithSelector(IERC4626.totalAssets.selector), abi.encode(1000e18));
        vm.mockCall(mockVault, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(1000e18));
        // Pyth response — non-stale, positive price. The exact magnitude
        // doesn't matter; tests only assert pause behaviour, not values.
        PythStructs.Price memory p =
            PythStructs.Price({price: 100e8, conf: 1e6, expo: -8, publishTime: uint64(block.timestamp)});
        vm.mockCall(PYTH_BASE, abi.encodeWithSelector(IPyth.getPriceNoOlderThan.selector), abi.encode(p));
    }

    function _config(CorporateActionPauseConfig memory pauseConfig) internal returns (PythOracleAdapter) {
        return createOracleWithPause(mockVault, MOCK_PRICE_ID, 3600, address(this), pauseConfig);
    }

    function _stockSplitConfig() internal view returns (CorporateActionPauseConfig memory) {
        return CorporateActionPauseConfig({
            corporateActionsVault: address(mock),
            actionTypeMask: ACTION_TYPE_STOCK_SPLIT_V1,
            pauseTimeBefore: PAUSE_BEFORE,
            pauseTimeAfter: PAUSE_AFTER
        });
    }

    /// @notice Auto-pause disabled (zero vault) → `latestAnswer` succeeds.
    function testNoAutoPauseWhenVaultIsZero() external {
        // Arm the mock with an in-window pending action; it should be
        // ignored because corporateActionsVault == address(0).
        mock.setEarliestPending(1, ACTION_TYPE_STOCK_SPLIT_V1, uint64(block.timestamp + 60));
        PythOracleAdapter oracle = _config(
            CorporateActionPauseConfig({
                corporateActionsVault: address(0),
                actionTypeMask: ACTION_TYPE_STOCK_SPLIT_V1,
                pauseTimeBefore: PAUSE_BEFORE,
                pauseTimeAfter: PAUSE_AFTER
            })
        );
        int256 answer = oracle.latestAnswer();
        assertGt(answer, 0);
    }

    /// @notice Pending action inside the pre-window → revert with
    /// `OraclePausedCorporateAction(effectiveTime)`.
    function testPendingInsideWindowRevertsLatestAnswer() external {
        uint64 effectiveTime = uint64(block.timestamp + PAUSE_BEFORE / 2);
        mock.setEarliestPending(1, ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);
        PythOracleAdapter oracle = _config(_stockSplitConfig());
        vm.expectRevert(abi.encodeWithSelector(OraclePausedCorporateAction.selector, effectiveTime));
        oracle.latestAnswer();
    }

    /// @notice Same window also reverts `latestRoundData` (parity test).
    function testPendingInsideWindowRevertsLatestRoundData() external {
        uint64 effectiveTime = uint64(block.timestamp + PAUSE_BEFORE / 2);
        mock.setEarliestPending(1, ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);
        PythOracleAdapter oracle = _config(_stockSplitConfig());
        vm.expectRevert(abi.encodeWithSelector(OraclePausedCorporateAction.selector, effectiveTime));
        oracle.latestRoundData();
    }

    /// @notice Completed action inside the post-window → revert.
    function testCompletedInsideWindowReverts() external {
        uint64 effectiveTime = uint64(block.timestamp - PAUSE_AFTER / 2);
        mock.setLatestCompleted(1, ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);
        PythOracleAdapter oracle = _config(_stockSplitConfig());
        vm.expectRevert(abi.encodeWithSelector(OraclePausedCorporateAction.selector, effectiveTime));
        oracle.latestAnswer();
    }

    /// @notice Action exists but outside the window → no revert.
    function testPendingOutsideWindowSucceeds() external {
        // Twice the window away — pre-window cannot reach it.
        mock.setEarliestPending(1, ACTION_TYPE_STOCK_SPLIT_V1, uint64(block.timestamp + 2 * PAUSE_BEFORE));
        PythOracleAdapter oracle = _config(_stockSplitConfig());
        int256 answer = oracle.latestAnswer();
        assertGt(answer, 0);
    }

    /// @notice Manual pause set + auto-pause window also open → manual error
    /// reported (cheaper SLOAD wins precedence).
    function testManualPauseTakesPrecedenceOverAuto() external {
        uint64 effectiveTime = uint64(block.timestamp + PAUSE_BEFORE / 2);
        mock.setEarliestPending(1, ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);
        PythOracleAdapter oracle = _config(_stockSplitConfig());
        oracle.setPaused(true);
        vm.expectRevert(abi.encodeWithSelector(OraclePausedManual.selector));
        oracle.latestAnswer();
    }

    /// @notice Lifting the manual pause while a corporate-action window is
    /// still open surfaces the auto error — they're independent.
    function testAutoPauseStillFiresAfterManualUnpaused() external {
        uint64 effectiveTime = uint64(block.timestamp + PAUSE_BEFORE / 2);
        mock.setEarliestPending(1, ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);
        PythOracleAdapter oracle = _config(_stockSplitConfig());
        oracle.setPaused(true);
        oracle.setPaused(false);
        vm.expectRevert(abi.encodeWithSelector(OraclePausedCorporateAction.selector, effectiveTime));
        oracle.latestAnswer();
    }

    /// `getRoundData` always reverts on Pyth-backed adapters — Pyth has no
    /// historical round storage exposed via this interface. Integrators
    /// needing point-in-time data must read Pyth directly or via an indexer.
    function testGetRoundDataAlwaysReverts(uint80 requestedRound) external {
        PythOracleAdapter oracle = _config(
            CorporateActionPauseConfig({
                corporateActionsVault: address(0), actionTypeMask: 0, pauseTimeBefore: 0, pauseTimeAfter: 0
            })
        );
        vm.expectRevert(abi.encodeWithSelector(HistoricalRoundDataUnsupported.selector, requestedRound));
        oracle.getRoundData(requestedRound);
    }

    /// `latestRoundData` MUST encode `uint80(uint64(publishTime))` into both
    /// `roundId` and `answeredInRound` so Chainlink consumers that diff round
    /// ids across blocks see a fresh round whenever Pyth has produced one.
    /// Pre-fix the values were hardcoded to `1`. Closes audit #43.
    function testLatestRoundDataIdIsPublishTime() external {
        // Re-mock Pyth so publishTime is a fixed sentinel, not block.timestamp.
        uint256 sentinel = 1_234_567_890;
        PythStructs.Price memory p = PythStructs.Price({price: 100e8, conf: 1e6, expo: -8, publishTime: sentinel});
        vm.mockCall(PYTH_BASE, abi.encodeWithSelector(IPyth.getPriceNoOlderThan.selector), abi.encode(p));

        PythOracleAdapter oracle = _config(
            CorporateActionPauseConfig({
                corporateActionsVault: address(0), actionTypeMask: 0, pauseTimeBefore: 0, pauseTimeAfter: 0
            })
        );
        (uint80 roundId,, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = oracle.latestRoundData();

        assertEq(roundId, uint80(uint64(sentinel)), "roundId should be uint80(uint64(publishTime))");
        assertEq(answeredInRound, uint80(uint64(sentinel)), "answeredInRound should equal roundId");
        assertEq(startedAt, sentinel);
        assertEq(updatedAt, sentinel);
        assertEq(roundId, answeredInRound, "Chainlink: a fresh round is answered in itself");
    }

    /// Calling `latestRoundData` twice with two different Pyth publishTimes
    /// must return two different roundIds — proving the metadata advances
    /// monotonically across reads, not stuck at the pre-fix constant `1`.
    /// Closes audit #43.
    function testLatestRoundDataIdAdvancesAcrossUpdates() external {
        PythOracleAdapter oracle = _config(
            CorporateActionPauseConfig({
                corporateActionsVault: address(0), actionTypeMask: 0, pauseTimeBefore: 0, pauseTimeAfter: 0
            })
        );

        uint256 t1 = 1_000_000_000;
        vm.mockCall(
            PYTH_BASE,
            abi.encodeWithSelector(IPyth.getPriceNoOlderThan.selector),
            abi.encode(PythStructs.Price({price: 100e8, conf: 1e6, expo: -8, publishTime: t1}))
        );
        (uint80 round1,,,,) = oracle.latestRoundData();

        uint256 t2 = 1_000_000_777;
        vm.mockCall(
            PYTH_BASE,
            abi.encodeWithSelector(IPyth.getPriceNoOlderThan.selector),
            abi.encode(PythStructs.Price({price: 101e8, conf: 1e6, expo: -8, publishTime: t2}))
        );
        (uint80 round2,,,,) = oracle.latestRoundData();

        assertGt(round2, round1, "roundId must advance when publishTime advances");
        assertEq(round1, uint80(uint64(t1)));
        assertEq(round2, uint80(uint64(t2)));
    }

    /// `_setCorporateActionPauseConfig` is called by every subclass initializer
    /// and must emit `CorporateActionPauseConfigSet` so off-chain indexers can
    /// reconstruct the four corporate-action governance slots from logs alone.
    /// Closes audit #149.
    function testInitializeEmitsCorporateActionPauseConfigSet() external {
        CorporateActionPauseConfig memory cfg = _stockSplitConfig();

        vm.recordLogs();
        _config(cfg);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("CorporateActionPauseConfigSet(address,uint256,uint64,uint64)")) {
                (address evVault, uint256 evMask, uint64 evBefore, uint64 evAfter) =
                    abi.decode(logs[i].data, (address, uint256, uint64, uint64));
                assertEq(evVault, cfg.corporateActionsVault);
                assertEq(evMask, cfg.actionTypeMask);
                assertEq(evBefore, cfg.pauseTimeBefore);
                assertEq(evAfter, cfg.pauseTimeAfter);
                found = true;
            }
        }
        assertTrue(found, "CorporateActionPauseConfigSet event missing");
    }
}
