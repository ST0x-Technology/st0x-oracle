// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {ICorporateActionsV1} from "st0x.deploy/src/interface/ICorporateActionsV1.sol";
import {CompletionFilter} from "st0x.deploy/src/lib/LibCorporateActionNode.sol";
import {LibCorporateActionsPause} from "src/lib/LibCorporateActionsPause.sol";
import {ACTION_TYPE_STOCK_SPLIT_V1} from "st0x.deploy/src/interface/ICorporateActionsV1.sol";

/// @dev Minimal mock of `ICorporateActionsV1` exposing only the two read paths
/// `LibCorporateActionsPause` consumes. Other interface methods revert so a
/// regression that calls them is caught loudly.
contract MockCorporateActions is ICorporateActionsV1 {
    struct StubAction {
        bool exists;
        uint256 cursor;
        uint256 actionType;
        uint64 effectiveTime;
    }

    StubAction private _earliestPending;
    StubAction private _latestCompleted;

    function setEarliestPending(uint256 cursor, uint256 actionType, uint64 effectiveTime) external {
        _earliestPending =
            StubAction({exists: cursor != 0, cursor: cursor, actionType: actionType, effectiveTime: effectiveTime});
    }

    function setLatestCompleted(uint256 cursor, uint256 actionType, uint64 effectiveTime) external {
        _latestCompleted =
            StubAction({exists: cursor != 0, cursor: cursor, actionType: actionType, effectiveTime: effectiveTime});
    }

    function earliestActionOfType(uint256 mask, CompletionFilter filter)
        external
        view
        override
        returns (uint256, uint256, uint64)
    {
        if (filter != CompletionFilter.PENDING) revert("mock: only PENDING supported");
        if (!_earliestPending.exists) return (0, 0, 0);
        if (_earliestPending.actionType & mask == 0) return (0, 0, 0);
        return (_earliestPending.cursor, _earliestPending.actionType, _earliestPending.effectiveTime);
    }

    function latestActionOfType(uint256 mask, CompletionFilter filter)
        external
        view
        override
        returns (uint256, uint256, uint64)
    {
        if (filter != CompletionFilter.COMPLETED) revert("mock: only COMPLETED supported");
        if (!_latestCompleted.exists) return (0, 0, 0);
        if (_latestCompleted.actionType & mask == 0) return (0, 0, 0);
        return (_latestCompleted.cursor, _latestCompleted.actionType, _latestCompleted.effectiveTime);
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

contract LibCorporateActionsPauseTest is Test {
    MockCorporateActions internal mock;
    uint64 internal constant BEFORE = 3600;
    uint64 internal constant AFTER = 3600;

    function setUp() public {
        mock = new MockCorporateActions();
        vm.warp(1_000_000);
    }

    // -------- Disable short-circuits --------

    function testZeroVaultAddressDisablesPause() external {
        // Even with a fully-armed mock, address(0) returns false without a call.
        mock.setEarliestPending(1, ACTION_TYPE_STOCK_SPLIT_V1, uint64(block.timestamp + 60));
        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(0), ACTION_TYPE_STOCK_SPLIT_V1, BEFORE, AFTER);
        assertEq(paused, false);
        assertEq(ts, 0);
    }

    function testZeroMaskDisablesPause() external {
        mock.setEarliestPending(1, ACTION_TYPE_STOCK_SPLIT_V1, uint64(block.timestamp + 60));
        (bool paused, uint64 ts) = LibCorporateActionsPause.inPauseWindow(address(mock), 0, BEFORE, AFTER);
        assertEq(paused, false);
        assertEq(ts, 0);
    }

    // -------- No actions --------

    function testNoPendingNoCompletedReturnsFalse() external {
        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_STOCK_SPLIT_V1, BEFORE, AFTER);
        assertEq(paused, false);
        assertEq(ts, 0);
    }

    // -------- Pending action / pre-window --------

    function testPendingOutsideBeforeWindowReturnsFalse() external {
        // Pending action 2h in the future, window is 1h before.
        mock.setEarliestPending(1, ACTION_TYPE_STOCK_SPLIT_V1, uint64(block.timestamp + 2 * BEFORE));
        (bool paused,) =
            LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_STOCK_SPLIT_V1, BEFORE, AFTER);
        assertEq(paused, false);
    }

    function testPendingExactlyAtBeforeWindowEdgeReturnsTrue() external {
        // now + before == effectiveTime: window is closed-open at the start.
        uint64 effectiveTime = uint64(block.timestamp + BEFORE);
        mock.setEarliestPending(1, ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);
        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_STOCK_SPLIT_V1, BEFORE, AFTER);
        assertEq(paused, true);
        assertEq(ts, effectiveTime);
    }

    function testPendingInsideBeforeWindowReturnsTrue() external {
        uint64 effectiveTime = uint64(block.timestamp + BEFORE / 2);
        mock.setEarliestPending(1, ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);
        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_STOCK_SPLIT_V1, BEFORE, AFTER);
        assertEq(paused, true);
        assertEq(ts, effectiveTime);
    }

    // -------- Completed action / post-window --------

    function testCompletedExactlyAtAfterWindowEdgeReturnsTrue() external {
        // now == effectiveTime + after: window is inclusive on both ends.
        uint64 effectiveTime = uint64(block.timestamp - AFTER);
        mock.setLatestCompleted(1, ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);
        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_STOCK_SPLIT_V1, BEFORE, AFTER);
        assertEq(paused, true);
        assertEq(ts, effectiveTime);
    }

    function testCompletedJustOutsideAfterWindowReturnsFalse() external {
        uint64 effectiveTime = uint64(block.timestamp - AFTER - 1);
        mock.setLatestCompleted(1, ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);
        (bool paused,) =
            LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_STOCK_SPLIT_V1, BEFORE, AFTER);
        assertEq(paused, false);
    }

    function testCompletedInsideAfterWindowReturnsTrue() external {
        uint64 effectiveTime = uint64(block.timestamp - AFTER / 2);
        mock.setLatestCompleted(1, ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);
        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_STOCK_SPLIT_V1, BEFORE, AFTER);
        assertEq(paused, true);
        assertEq(ts, effectiveTime);
    }

    // -------- Mask filtering --------

    function testMaskExcludesNonMatchingType() external {
        // Action exists but its type bit is not in the supplied mask.
        uint256 someOtherType = 1 << 5;
        mock.setEarliestPending(1, someOtherType, uint64(block.timestamp + 10));
        mock.setLatestCompleted(2, someOtherType, uint64(block.timestamp - 10));
        (bool paused,) =
            LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_STOCK_SPLIT_V1, BEFORE, AFTER);
        assertEq(paused, false);
    }

    function testWildcardMaskMatchesAnyType() external {
        uint256 someOtherType = 1 << 5;
        mock.setEarliestPending(1, someOtherType, uint64(block.timestamp + 10));
        (bool paused,) = LibCorporateActionsPause.inPauseWindow(address(mock), type(uint256).max, BEFORE, AFTER);
        assertEq(paused, true);
    }

    // -------- Pending takes precedence over completed --------

    function testPendingReportedWhenBothWindowsOpen() external {
        // Completed action 30min ago (post-window open).
        uint64 completedTime = uint64(block.timestamp - 1800);
        // Pending action 30min away (pre-window also open).
        uint64 pendingTime = uint64(block.timestamp + 1800);
        mock.setLatestCompleted(1, ACTION_TYPE_STOCK_SPLIT_V1, completedTime);
        mock.setEarliestPending(2, ACTION_TYPE_STOCK_SPLIT_V1, pendingTime);
        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_STOCK_SPLIT_V1, BEFORE, AFTER);
        assertEq(paused, true);
        assertEq(ts, pendingTime, "pending action's effectiveTime should be returned when both windows open");
    }

    // -------- Zero-window edge cases --------

    function testZeroBeforeWithExactPendingReturnsFalse() external {
        // pauseTimeBefore = 0 means no pre-window — pending action does not pause.
        mock.setEarliestPending(1, ACTION_TYPE_STOCK_SPLIT_V1, uint64(block.timestamp + 1));
        (bool paused,) = LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_STOCK_SPLIT_V1, 0, AFTER);
        assertEq(paused, false);
    }

    function testZeroAfterWithJustCompletedReturnsTrue() external {
        // Edge: effectiveTime == now, pauseTimeAfter == 0. Window is exactly
        // one block wide and includes that block.
        mock.setLatestCompleted(1, ACTION_TYPE_STOCK_SPLIT_V1, uint64(block.timestamp));
        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_STOCK_SPLIT_V1, BEFORE, 0);
        assertEq(paused, true);
        assertEq(ts, uint64(block.timestamp));
    }
}
