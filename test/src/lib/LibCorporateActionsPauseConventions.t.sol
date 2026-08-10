// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.1/src/Test.sol";
import {CompletionFilter, NODE_NONE} from "st0x-deploy-0.1.1/src/lib/LibCorporateActionNode.sol";
import {
    ACTION_TYPE_INIT_V1,
    ACTION_TYPE_STOCK_SPLIT_V1,
    ACTION_TYPE_STABLES_DIVIDEND_V1
} from "st0x-deploy-0.1.1/src/interface/ICorporateActionsV1.sol";
import {InvalidMask} from "st0x-deploy-0.1.1/src/error/ErrCorporateAction.sol";
import {CorporateActionsListHarness} from "../../mocks/CorporateActionsListHarness.sol";
import {LibCorporateActionsPause} from "../../../src/lib/LibCorporateActionsPause.sol";

/// @title LibCorporateActionsPauseConventions
/// @notice Enumeration test (audit #216) pinning every `ICorporateActionsV1`
/// convention `LibCorporateActionsPause` silently depends on, against the REAL
/// upstream list primitives rather than a hand-mock. Fires on `st0x-deploy`
/// submodule bumps — the exact moment a wire-format convention could shift
/// unnoticed. The live `cursor != 0` vs `NODE_NONE` bug proved this hazard
/// surface is non-empty.
///
/// COVERED against the real upstream `LibCorporateAction` / `LibCorporateActionNode`:
///   1. No-match sentinel is `NODE_NONE == type(uint256).max` (not 0).
///   2. Filter shape: a mask of 0 (`mask & VALID_ACTION_TYPES_MASK == 0`)
///      reverts `InvalidMask`, so the lib's mask-0 short-circuit is load-bearing.
///   3. Earliest/latest pending & completed monotonicity across a multi-node list.
///   4. `cancel` unlinks a node so it disappears from earliest/latest traversal.
///
/// NOT covered here (see return notes): the facet's `onlyDelegatecalled` guard
/// and authorizer permissioning are not exercised — this harness intentionally
/// bypasses the facet wrapper to reach the same list logic the facet delegates
/// to. The stock-split parameter validation in `resolveActionType` is also out
/// of scope (list-shape, not param-schema, is what the pause lib depends on).
contract LibCorporateActionsPauseConventionsTest is Test {
    CorporateActionsListHarness internal harness;

    function setUp() public {
        harness = new CorporateActionsListHarness();
        // Warp far enough forward that scheduling actions at now+delta and
        // completing them by warping never underflows.
        vm.warp(1_000_000);
    }

    /// Convention 1: the no-match sentinel is `NODE_NONE` (`type(uint256).max`),
    /// NOT `0`. `LibCorporateActionsPause` compares `cursor != NODE_NONE`; a real
    /// query for a valid action type that has never been scheduled must return
    /// exactly `NODE_NONE`, proving the sentinel value the lib hard-codes.
    function testNoMatchReturnsNodeNoneSentinel() external {
        // Query a valid-but-unscheduled type (dividend) on a fresh list.
        (uint256 pendingCursor,,) =
            harness.earliestActionOfType(ACTION_TYPE_STABLES_DIVIDEND_V1, CompletionFilter.PENDING);
        assertEq(pendingCursor, NODE_NONE, "no-match PENDING sentinel must be NODE_NONE");

        (uint256 completedCursor,,) =
            harness.latestActionOfType(ACTION_TYPE_STABLES_DIVIDEND_V1, CompletionFilter.COMPLETED);
        assertEq(completedCursor, NODE_NONE, "no-match COMPLETED sentinel must be NODE_NONE");
    }

    /// Convention 1b: even with actions present, a mask that matches none of
    /// them returns `NODE_NONE` (not the bootstrap index 0). Schedules a split,
    /// then queries the dividend bit.
    function testNonMatchingMaskReturnsNodeNoneNotZero() external {
        harness.schedule(ACTION_TYPE_STOCK_SPLIT_V1, uint64(block.timestamp + 1 days));
        (uint256 cursor,,) = harness.earliestActionOfType(ACTION_TYPE_STABLES_DIVIDEND_V1, CompletionFilter.PENDING);
        assertEq(cursor, NODE_NONE, "unmatched mask must return NODE_NONE, never the bootstrap slot 0");
    }

    /// Convention 2: the filter shape. A mask that reduces to empty against
    /// `VALID_ACTION_TYPES_MASK` reverts `InvalidMask` upstream — this is
    /// exactly why `LibCorporateActionsPause` MUST short-circuit on
    /// `effectiveMask == 0` before ever querying the vault. Pins that reliance.
    function testEmptyMaskRevertsInvalidMaskUpstream() external {
        vm.expectRevert(InvalidMask.selector);
        harness.earliestActionOfType(0, CompletionFilter.PENDING);
    }

    /// Convention 2b: a mask of exactly `ACTION_TYPE_INIT_V1` is a *valid* mask
    /// upstream (INIT is in `VALID_ACTION_TYPES_MASK`), so it does NOT revert —
    /// it matches the bootstrap node. This is why the pause lib strips the INIT
    /// bit itself rather than relying on the vault to reject it. After a
    /// schedule, the bootstrap init node is present and completed.
    function testInitMaskMatchesBootstrapNodeUpstream() external {
        harness.schedule(ACTION_TYPE_STOCK_SPLIT_V1, uint64(block.timestamp + 1 days));
        // Bootstrap (index 0) is INIT-typed, effectiveTime == schedule-time now,
        // hence already completed.
        (uint256 cursor, uint256 actionType,) =
            harness.latestActionOfType(ACTION_TYPE_INIT_V1, CompletionFilter.COMPLETED);
        assertEq(cursor, 0, "bootstrap INIT node lives at index 0 and matches the INIT mask");
        assertEq(actionType, ACTION_TYPE_INIT_V1, "bootstrap node is INIT-typed");
    }

    /// Convention 3: earliest-pending monotonicity. Schedule three splits out of
    /// time order; `earliestActionOfType(PENDING)` must return the one with the
    /// SMALLEST effectiveTime regardless of insertion order — the property the
    /// pause lib's "earliest pending is closest to now" reasoning relies on.
    function testEarliestPendingIsSmallestEffectiveTime() external {
        uint64 nowTs = uint64(block.timestamp);
        harness.schedule(ACTION_TYPE_STOCK_SPLIT_V1, nowTs + 30 days);
        harness.schedule(ACTION_TYPE_STOCK_SPLIT_V1, nowTs + 10 days);
        harness.schedule(ACTION_TYPE_STOCK_SPLIT_V1, nowTs + 20 days);

        (,, uint64 earliestEffective) =
            harness.earliestActionOfType(ACTION_TYPE_STOCK_SPLIT_V1, CompletionFilter.PENDING);
        assertEq(earliestEffective, nowTs + 10 days, "earliest pending must be the smallest effectiveTime");
    }

    /// Convention 3b: latest-completed monotonicity. Schedule three splits at
    /// distinct future times, then warp past all of them so they complete;
    /// `latestActionOfType(COMPLETED)` must return the LARGEST effectiveTime —
    /// the property the pause lib's "latest completed is closest to now" post-
    /// window reasoning relies on.
    function testLatestCompletedIsLargestEffectiveTime() external {
        uint64 nowTs = uint64(block.timestamp);
        harness.schedule(ACTION_TYPE_STOCK_SPLIT_V1, nowTs + 10 days);
        harness.schedule(ACTION_TYPE_STOCK_SPLIT_V1, nowTs + 30 days);
        harness.schedule(ACTION_TYPE_STOCK_SPLIT_V1, nowTs + 20 days);

        vm.warp(nowTs + 40 days);
        (,, uint64 latestEffective) = harness.latestActionOfType(ACTION_TYPE_STOCK_SPLIT_V1, CompletionFilter.COMPLETED);
        assertEq(latestEffective, nowTs + 30 days, "latest completed must be the largest effectiveTime");
    }

    /// Convention 4: `cancel` unlinking. `LibCorporateActionsPause` documents
    /// that cancelled nodes are unlinked from traversal so "no explicit filter
    /// required here". Schedule two pending splits, cancel the earlier one, and
    /// assert `earliestActionOfType(PENDING)` now returns the SURVIVOR — the
    /// cancelled node no longer appears in traversal.
    function testCancelUnlinksActionFromTraversal() external {
        uint64 nowTs = uint64(block.timestamp);
        uint256 earlier = harness.schedule(ACTION_TYPE_STOCK_SPLIT_V1, nowTs + 5 days);
        harness.schedule(ACTION_TYPE_STOCK_SPLIT_V1, nowTs + 15 days);

        // Before cancel: earliest pending is the earlier one.
        (uint256 cursorBefore,, uint64 effBefore) =
            harness.earliestActionOfType(ACTION_TYPE_STOCK_SPLIT_V1, CompletionFilter.PENDING);
        assertEq(cursorBefore, earlier, "earliest pending is the earlier node before cancel");
        assertEq(effBefore, nowTs + 5 days);

        harness.cancel(earlier);

        // After cancel: the cancelled node is gone; earliest pending is the survivor.
        (uint256 cursorAfter,, uint64 effAfter) =
            harness.earliestActionOfType(ACTION_TYPE_STOCK_SPLIT_V1, CompletionFilter.PENDING);
        assertTrue(cursorAfter != earlier, "cancelled node must be unlinked from traversal");
        assertEq(effAfter, nowTs + 15 days, "earliest pending after cancel is the surviving node");
    }

    /// End-to-end window semantics against the REAL upstream list, not a mock.
    /// Every other `inPauseWindow` test drives `MockCorporateActions`, which
    /// re-encodes beliefs about the traversal; this one schedules a real action
    /// and walks `block.timestamp` across every boundary instant the NatSpec
    /// specifies, asserting the exact `(paused, effectiveTime)` pair at each:
    ///
    ///   E-before-1 : not paused          (pre-window not yet open)
    ///   E-before   : paused, ts == E     (pre-window lower bound INCLUSIVE)
    ///   E-1        : paused, ts == E     (still pending)
    ///   E          : paused, ts == E     (HANDOVER — upstream flips the action
    ///                                     from PENDING to COMPLETED exactly
    ///                                     here, and the post-window's lower
    ///                                     bound is inclusive, so there is no
    ///                                     one-second hole at the single most
    ///                                     price-sensitive instant)
    ///   E+after    : paused, ts == E     (post-window upper bound INCLUSIVE)
    ///   E+after+1  : not paused          (post-window closed)
    ///
    /// The handover instant is the load-bearing one: the library's defensive
    /// `pendingEffective > now` re-assertion means the pending branch stops
    /// matching at exactly `E`, so coverage there depends entirely on upstream
    /// classifying `effectiveTime == now` as COMPLETED (`effectiveTime <= now`).
    /// A mock cannot prove that; this does.
    function testInPauseWindowBoundariesAgainstRealList() external {
        uint64 pauseBefore = 1 hours;
        uint64 pauseAfter = 2 hours;
        uint64 effectiveTime = uint64(block.timestamp) + 1 days;
        harness.schedule(ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);

        bool paused;
        uint64 ts;

        vm.warp(effectiveTime - pauseBefore - 1);
        (paused, ts) = LibCorporateActionsPause.inPauseWindow(
            address(harness), ACTION_TYPE_STOCK_SPLIT_V1, pauseBefore, pauseAfter
        );
        assertEq(paused, false, "one second before the pre-window opens: not paused");
        assertEq(ts, 0);

        vm.warp(effectiveTime - pauseBefore);
        (paused, ts) = LibCorporateActionsPause.inPauseWindow(
            address(harness), ACTION_TYPE_STOCK_SPLIT_V1, pauseBefore, pauseAfter
        );
        assertEq(paused, true, "pre-window lower bound is inclusive");
        assertEq(ts, effectiveTime, "pre-window reports the pending action's effectiveTime");

        vm.warp(uint256(effectiveTime) - 1);
        (paused, ts) = LibCorporateActionsPause.inPauseWindow(
            address(harness), ACTION_TYPE_STOCK_SPLIT_V1, pauseBefore, pauseAfter
        );
        assertEq(paused, true, "still inside the pre-window one second before effect");
        assertEq(ts, effectiveTime);

        vm.warp(effectiveTime);
        (paused, ts) = LibCorporateActionsPause.inPauseWindow(
            address(harness), ACTION_TYPE_STOCK_SPLIT_V1, pauseBefore, pauseAfter
        );
        assertEq(paused, true, "handover instant: PENDING->COMPLETED must leave no coverage gap");
        assertEq(ts, effectiveTime);

        vm.warp(uint256(effectiveTime) + pauseAfter);
        (paused, ts) = LibCorporateActionsPause.inPauseWindow(
            address(harness), ACTION_TYPE_STOCK_SPLIT_V1, pauseBefore, pauseAfter
        );
        assertEq(paused, true, "post-window upper bound is inclusive");
        assertEq(ts, effectiveTime);

        vm.warp(uint256(effectiveTime) + pauseAfter + 1);
        (paused, ts) = LibCorporateActionsPause.inPauseWindow(
            address(harness), ACTION_TYPE_STOCK_SPLIT_V1, pauseBefore, pauseAfter
        );
        assertEq(paused, false, "one second after the post-window closes: not paused");
        assertEq(ts, 0);
    }

    /// The library's NatSpec claims cancelled nodes need no explicit filter
    /// because upstream unlinks them from traversal. `testCancelUnlinksActionFromTraversal`
    /// proves the unlink at the primitive level; this proves the CONSEQUENCE the
    /// library actually relies on — an action inside its pre-window pauses, and
    /// after `cancel` the very same instant does not. End-to-end, real list.
    function testCancelStopsPauseThroughInPauseWindow() external {
        uint64 pauseBefore = 1 hours;
        uint64 effectiveTime = uint64(block.timestamp) + 1 days;
        uint256 actionId = harness.schedule(ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);

        vm.warp(uint256(effectiveTime) - 30 minutes);
        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(harness), ACTION_TYPE_STOCK_SPLIT_V1, pauseBefore, 1 hours);
        assertEq(paused, true, "scheduled action inside its pre-window pauses");
        assertEq(ts, effectiveTime);

        harness.cancel(actionId);

        (paused, ts) =
            LibCorporateActionsPause.inPauseWindow(address(harness), ACTION_TYPE_STOCK_SPLIT_V1, pauseBefore, 1 hours);
        assertEq(paused, false, "a cancelled action must stop pausing at the same instant");
        assertEq(ts, 0, "cancelled action must not leak an effectiveTime");
    }

    /// Convention 4b: cancelling the ONLY pending node returns the list to a
    /// no-pending state — earliest pending is `NODE_NONE` again, confirming a
    /// cancelled node neither triggers a pause nor lingers as a phantom.
    function testCancelSolePendingReturnsNodeNone() external {
        uint256 only = harness.schedule(ACTION_TYPE_STOCK_SPLIT_V1, uint64(block.timestamp + 5 days));
        harness.cancel(only);
        (uint256 cursor,,) = harness.earliestActionOfType(ACTION_TYPE_STOCK_SPLIT_V1, CompletionFilter.PENDING);
        assertEq(cursor, NODE_NONE, "cancelling the sole pending node returns the no-match sentinel");
    }
}
