// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {PythOracleAdapterTest} from "test/abstract/PythOracleAdapterTest.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPyth} from "pyth-sdk/IPyth.sol";
import {PythStructs} from "pyth-sdk/PythStructs.sol";
import {LibPyth} from "rain.pyth/src/lib/pyth/LibPyth.sol";
import {ICorporateActionsV1, ACTION_TYPE_STOCK_SPLIT_V1} from "st0x.deploy/src/interface/ICorporateActionsV1.sol";
import {CompletionFilter} from "st0x.deploy/src/lib/LibCorporateActionNode.sol";
import {
    CorporateActionPauseConfig,
    OraclePausedManual,
    OraclePausedCorporateAction
} from "src/abstract/BasePythOracleAdapter.sol";
import {PythOracleAdapter} from "src/concrete/oracle/PythOracleAdapter.sol";

/// @dev Base chain ID.
uint256 constant BASE_CHAIN_ID = 8453;

/// @dev Arbitrary Pyth feed ID (response is fully mocked).
bytes32 constant MOCK_PRICE_ID = bytes32(uint256(0xdeadbeef));

/// @dev Pyth contract address on Base (from `LibPyth`). We mock at this
/// address so the runtime call resolves correctly regardless of fork state.
address constant PYTH_BASE = 0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a;

/// @dev Minimal `ICorporateActionsV1` mock exposing the two read paths
/// `LibCorporateActionsPause` consumes. Other interface methods revert so a
/// regression that calls them is caught loudly.
contract MockCorporateActions is ICorporateActionsV1 {
    struct Stub {
        bool exists;
        uint256 actionType;
        uint64 effectiveTime;
    }

    Stub private _earliestPending;
    Stub private _latestCompleted;

    function setEarliestPending(uint256 actionType, uint64 effectiveTime) external {
        _earliestPending = Stub({exists: true, actionType: actionType, effectiveTime: effectiveTime});
    }

    function setLatestCompleted(uint256 actionType, uint64 effectiveTime) external {
        _latestCompleted = Stub({exists: true, actionType: actionType, effectiveTime: effectiveTime});
    }

    function earliestActionOfType(uint256 mask, CompletionFilter filter)
        external
        view
        override
        returns (uint256, uint256, uint64)
    {
        if (filter != CompletionFilter.PENDING) revert("mock: only PENDING expected");
        if (!_earliestPending.exists) return (0, 0, 0);
        if (_earliestPending.actionType & mask == 0) return (0, 0, 0);
        return (1, _earliestPending.actionType, _earliestPending.effectiveTime);
    }

    function latestActionOfType(uint256 mask, CompletionFilter filter)
        external
        view
        override
        returns (uint256, uint256, uint64)
    {
        if (filter != CompletionFilter.COMPLETED) revert("mock: only COMPLETED expected");
        if (!_latestCompleted.exists) return (0, 0, 0);
        if (_latestCompleted.actionType & mask == 0) return (0, 0, 0);
        return (1, _latestCompleted.actionType, _latestCompleted.effectiveTime);
    }

    function scheduleCorporateAction(bytes32, uint64, bytes calldata) external pure override returns (uint256) {
        revert("mock: not implemented");
    }

    function cancelCorporateAction(uint256) external pure override {
        revert("mock: not implemented");
    }

    function completedActionCount() external pure override returns (uint256) {
        revert("mock: not implemented");
    }

    function nextOfType(uint256, uint256, CompletionFilter) external pure override returns (uint256, uint256, uint64) {
        revert("mock: not implemented");
    }

    function prevOfType(uint256, uint256, CompletionFilter) external pure override returns (uint256, uint256, uint64) {
        revert("mock: not implemented");
    }

    function getActionParameters(uint256) external pure override returns (bytes memory) {
        revert("mock: not implemented");
    }
}

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
        mock.setEarliestPending(ACTION_TYPE_STOCK_SPLIT_V1, uint64(block.timestamp + 60));
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
        mock.setEarliestPending(ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);
        PythOracleAdapter oracle = _config(_stockSplitConfig());
        vm.expectRevert(abi.encodeWithSelector(OraclePausedCorporateAction.selector, effectiveTime));
        oracle.latestAnswer();
    }

    /// @notice Same window also reverts `latestRoundData` (parity test).
    function testPendingInsideWindowRevertsLatestRoundData() external {
        uint64 effectiveTime = uint64(block.timestamp + PAUSE_BEFORE / 2);
        mock.setEarliestPending(ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);
        PythOracleAdapter oracle = _config(_stockSplitConfig());
        vm.expectRevert(abi.encodeWithSelector(OraclePausedCorporateAction.selector, effectiveTime));
        oracle.latestRoundData();
    }

    /// @notice Completed action inside the post-window → revert.
    function testCompletedInsideWindowReverts() external {
        uint64 effectiveTime = uint64(block.timestamp - PAUSE_AFTER / 2);
        mock.setLatestCompleted(ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);
        PythOracleAdapter oracle = _config(_stockSplitConfig());
        vm.expectRevert(abi.encodeWithSelector(OraclePausedCorporateAction.selector, effectiveTime));
        oracle.latestAnswer();
    }

    /// @notice Action exists but outside the window → no revert.
    function testPendingOutsideWindowSucceeds() external {
        // Twice the window away — pre-window cannot reach it.
        mock.setEarliestPending(ACTION_TYPE_STOCK_SPLIT_V1, uint64(block.timestamp + 2 * PAUSE_BEFORE));
        PythOracleAdapter oracle = _config(_stockSplitConfig());
        int256 answer = oracle.latestAnswer();
        assertGt(answer, 0);
    }

    /// @notice Manual pause set + auto-pause window also open → manual error
    /// reported (cheaper SLOAD wins precedence).
    function testManualPauseTakesPrecedenceOverAuto() external {
        uint64 effectiveTime = uint64(block.timestamp + PAUSE_BEFORE / 2);
        mock.setEarliestPending(ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);
        PythOracleAdapter oracle = _config(_stockSplitConfig());
        oracle.setPaused(true);
        vm.expectRevert(abi.encodeWithSelector(OraclePausedManual.selector));
        oracle.latestAnswer();
    }

    /// @notice Lifting the manual pause while a corporate-action window is
    /// still open surfaces the auto error — they're independent.
    function testAutoPauseStillFiresAfterManualUnpaused() external {
        uint64 effectiveTime = uint64(block.timestamp + PAUSE_BEFORE / 2);
        mock.setEarliestPending(ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);
        PythOracleAdapter oracle = _config(_stockSplitConfig());
        oracle.setPaused(true);
        oracle.setPaused(false);
        vm.expectRevert(abi.encodeWithSelector(OraclePausedCorporateAction.selector, effectiveTime));
        oracle.latestAnswer();
    }
}
