// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.1/src/Test.sol";
import {CompletionFilter, NODE_NONE} from "st0x-deploy-0.1.1/src/lib/LibCorporateActionNode.sol";
import {LibCorporateActionsPause} from "../../../src/lib/LibCorporateActionsPause.sol";
import {
    ICorporateActionsV1,
    ACTION_TYPE_INIT_V1,
    ACTION_TYPE_STOCK_SPLIT_V1
} from "st0x-deploy-0.1.1/src/interface/ICorporateActionsV1.sol";
import {MockCorporateActions} from "../../mocks/MockCorporateActions.sol";
import {
    MockRevertingCorporateActions,
    CorporateActionsUnavailable
} from "../../mocks/MockRevertingCorporateActions.sol";
import {MockStringRevertingCorporateActions} from "../../mocks/MockStringRevertingCorporateActions.sol";
import {MockMalformedCorporateActions} from "../../mocks/MockMalformedCorporateActions.sol";

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

    /// The `effectiveMask == 0` short-circuit must fire BEFORE any vault call.
    /// A mask of 0 (or exactly `ACTION_TYPE_INIT_V1`, which strips to 0) means
    /// a real vault would revert `InvalidMask`, so the lib MUST NOT query it —
    /// it must return `(false, 0)` without touching the vault. Proven against a
    /// vault that reverts on every read: if the short-circuit is dropped, the
    /// call reaches the reverting vault and the whole call reverts instead of
    /// returning false. The `MockCorporateActions`-based tests can't catch this
    /// because that mock returns no-match (not a revert) on mask 0.
    function testEmptyEffectiveMaskShortCircuitsBeforeVaultCall() external {
        MockRevertingCorporateActions reverting = new MockRevertingCorporateActions();
        // mask == 0 → effectiveMask == 0 → must short-circuit.
        (bool paused, uint64 ts) = LibCorporateActionsPause.inPauseWindow(address(reverting), 0, BEFORE, AFTER);
        assertEq(paused, false, "mask 0 must short-circuit without querying the vault");
        assertEq(ts, 0);

        // mask == ACTION_TYPE_INIT_V1 → strips to 0 → must also short-circuit.
        (paused, ts) = LibCorporateActionsPause.inPauseWindow(address(reverting), ACTION_TYPE_INIT_V1, BEFORE, AFTER);
        assertEq(paused, false, "INIT-only mask must short-circuit without querying the vault");
        assertEq(ts, 0);
    }

    // -------- Reverting / bad vault on the read paths (audit #74) --------

    /// A non-zero vault that reverts on the read paths must propagate the
    /// underlying revert, not swallow it. `inPauseWindow` makes external calls
    /// to `earliestActionOfType` / `latestActionOfType`; if the vault reverts
    /// (paused impl, wrong ABI, etc.) the whole price read must revert with the
    /// underlying reason. This is the deliberate opposite of the mask-0
    /// short-circuit test (which proves the vault is NOT called): here a
    /// non-zero mask reaches a real read path against a reverting vault, so a
    /// regression adding a `try/catch` that returned `(false, 0)` would be
    /// caught. Closes audit #74.
    function testRevertingVaultPropagates() external {
        MockStringRevertingCorporateActions reverting = new MockStringRevertingCorporateActions();
        // Route through an external boundary so `vm.expectRevert` unambiguously
        // targets the `inPauseWindow` call rather than any inlined sub-call.
        vm.expectRevert("vault-reverts");
        this.callInPauseWindow(address(reverting), ACTION_TYPE_STOCK_SPLIT_V1, BEFORE, AFTER);
    }

    /// A custom-error-reverting vault (typed revert, no string) must likewise
    /// propagate the exact custom error selector. Complements the string-revert
    /// case above and pins that the propagation is reason-preserving for both
    /// revert encodings. #74.
    function testCustomErrorRevertingVaultPropagates() external {
        MockRevertingCorporateActions reverting = new MockRevertingCorporateActions();
        vm.expectRevert(CorporateActionsUnavailable.selector);
        this.callInPauseWindow(address(reverting), ACTION_TYPE_STOCK_SPLIT_V1, BEFORE, AFTER);
    }

    /// A NON-ZERO vault address with no deployed code must fail CLOSED. Only
    /// `address(0)` is the documented "auto-pause disabled" short-circuit; any
    /// other address is asserted to implement `ICorporateActionsV1`, and a
    /// high-level call expecting return data carries solc's extcodesize guard,
    /// so a codeless address reverts with EMPTY return data rather than being
    /// read as "no actions scheduled". A misconfigured (or self-destructed)
    /// vault must never silently degrade into a permanently un-pausable oracle.
    /// Asserted via a raw external-call failure (not `vm.expectRevert`), and
    /// only on the success FLAG: forge versions differ both on whether a call
    /// into a code-less address is classified as a plain revert and on what
    /// reason bytes the halt carries, but every version agrees the call does
    /// NOT succeed. Discriminating value: `ok == false`, versus a successful
    /// `(false, 0)` pause result if the disable short-circuit were widened to
    /// "no code".
    function testNonZeroVaultWithoutCodeFailsClosed() external {
        address codeless = address(0xDEAD);
        assertEq(codeless.code.length, 0, "the fixture address must genuinely have no code");
        (bool ok,) = address(this)
            .call(abi.encodeCall(this.callInPauseWindow, (codeless, ACTION_TYPE_STOCK_SPLIT_V1, BEFORE, AFTER)));
        assertFalse(ok, "a code-less corporate-actions vault must fail closed, never read as no actions");
    }

    /// The NatSpec states a gas contract: "each query is at most two view calls
    /// into the vault". That bound is what justifies the whole earliest-pending
    /// / latest-completed shape, and nothing else in the suite observes call
    /// COUNTS, so a refactor that always performed both reads (or added a third)
    /// would be invisible. This arm pins the cheap path: an open pending
    /// pre-window is decided by the FIRST read, so the completed read is never
    /// made at all — exactly ONE call into the vault.
    function testOpenPendingPreWindowMakesExactlyOneVaultCall() external {
        mock.setEarliestPending(1, ACTION_TYPE_STOCK_SPLIT_V1, uint64(block.timestamp + BEFORE / 2));
        vm.expectCall(address(mock), _pendingCalldata(), 1);
        vm.expectCall(address(mock), _completedCalldata(), 0);
        (bool paused,) =
            LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_STOCK_SPLIT_V1, BEFORE, AFTER);
        assertEq(paused, true, "the single pending read is enough to decide");
    }

    /// The other arm of the two-call bound: a pending action OUTSIDE its
    /// pre-window falls through, and the completed read is then made exactly
    /// once — two calls in total, never three.
    function testPendingFallThroughMakesExactlyTwoVaultCalls() external {
        mock.setEarliestPending(1, ACTION_TYPE_STOCK_SPLIT_V1, uint64(block.timestamp + 2 * BEFORE + 1));
        mock.setLatestCompleted(2, ACTION_TYPE_STOCK_SPLIT_V1, uint64(block.timestamp - AFTER / 2));
        vm.expectCall(address(mock), _pendingCalldata(), 1);
        vm.expectCall(address(mock), _completedCalldata(), 1);
        (bool paused,) =
            LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_STOCK_SPLIT_V1, BEFORE, AFTER);
        assertEq(paused, true, "the fall-through decides on exactly one completed read");
    }

    /// The exact calldata of the PENDING read the library is specified to make:
    /// `earliestActionOfType(mask, PENDING)`.
    function _pendingCalldata() internal pure returns (bytes memory) {
        return abi.encodeCall(
            ICorporateActionsV1.earliestActionOfType, (ACTION_TYPE_STOCK_SPLIT_V1, CompletionFilter.PENDING)
        );
    }

    /// The exact calldata of the COMPLETED read the library is specified to
    /// make: `latestActionOfType(mask, COMPLETED)`.
    function _completedCalldata() internal pure returns (bytes memory) {
        return abi.encodeCall(
            ICorporateActionsV1.latestActionOfType, (ACTION_TYPE_STOCK_SPLIT_V1, CompletionFilter.COMPLETED)
        );
    }

    /// External wrapper around the internal library call so revert-propagation
    /// tests can point `vm.expectRevert` at a single external call boundary.
    function callInPauseWindow(address vault, uint256 mask, uint64 pauseBefore, uint64 pauseAfter)
        external
        view
        returns (bool, uint64)
    {
        return LibCorporateActionsPause.inPauseWindow(vault, mask, pauseBefore, pauseAfter);
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

    /// Every other completed-branch test runs with `pauseTimeBefore ==
    /// pauseTimeAfter` (both `3600`), so swapping the two parameters inside the
    /// post-window predicate is invisible to them — only a fuzz run in the
    /// consumer suite happened to catch it, which is seed-dependent. This pins
    /// deterministically that the POST-window is sized by `pauseTimeAfter`
    /// alone, using deliberately asymmetric windows in BOTH directions:
    ///   (a) a short `before` and long `after` must still pause on a completed
    ///       action 100s old (the mutation `+ pauseTimeBefore` would compute
    ///       `now <= now - 100 + 10` and NOT pause), and
    ///   (b) a long `before` and short `after` must NOT pause on that same
    ///       action (the mutation would compute `now <= now - 100 + 3600` and
    ///       spuriously pause).
    function testPostWindowIsSizedByPauseTimeAfterNotBefore() external {
        uint64 effectiveTime = uint64(block.timestamp - 100);
        mock.setLatestCompleted(1, ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);

        // (a) after = 3600 covers the 100s-old action; before = 10 is irrelevant.
        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_STOCK_SPLIT_V1, 10, 3600);
        assertEq(paused, true, "post-window must be sized by pauseTimeAfter (3600 > 100)");
        assertEq(ts, effectiveTime);

        // (b) after = 10 does NOT cover it; the large before must not leak in.
        (paused, ts) = LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_STOCK_SPLIT_V1, 3600, 10);
        assertEq(paused, false, "pauseTimeBefore must not widen the post-window (10 < 100)");
        assertEq(ts, 0);
    }

    /// Mirror of the above for the PRE-window: it is sized by `pauseTimeBefore`
    /// alone. (a) before = 3600 opens on a pending action 100s out even when
    /// after = 10; (b) before = 10 does not, even when after = 3600.
    function testPreWindowIsSizedByPauseTimeBeforeNotAfter() external {
        uint64 effectiveTime = uint64(block.timestamp + 100);
        mock.setEarliestPending(1, ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);

        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_STOCK_SPLIT_V1, 3600, 10);
        assertEq(paused, true, "pre-window must be sized by pauseTimeBefore (3600 > 100)");
        assertEq(ts, effectiveTime);

        (paused, ts) = LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_STOCK_SPLIT_V1, 10, 3600);
        assertEq(paused, false, "pauseTimeAfter must not widen the pre-window (10 < 100)");
        assertEq(ts, 0);
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

    /// A PENDING action exists but its pre-window has NOT opened yet
    /// (`now + pauseTimeBefore < pendingEffective`), so the pending branch
    /// falls through WITHOUT returning. A COMPLETED action's post-window IS
    /// open, so the function must return `(true, completedEffective)` — the
    /// COMPLETED action's time, not the pending one. Guards the fall-through
    /// from the pending branch into the completed branch: a regression that
    /// `return`ed early on any present pending (regardless of window) would
    /// report the pending time and fail this.
    function testPendingPreWindowClosedFallsThroughToCompleted() external {
        // Pending action far in the future: now + BEFORE < pendingEffective.
        uint64 pendingTime = uint64(block.timestamp + 2 * BEFORE + 1);
        mock.setEarliestPending(1, ACTION_TYPE_STOCK_SPLIT_V1, pendingTime);
        // Completed action inside its post-window.
        uint64 completedTime = uint64(block.timestamp - AFTER / 2);
        mock.setLatestCompleted(2, ACTION_TYPE_STOCK_SPLIT_V1, completedTime);

        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_STOCK_SPLIT_V1, BEFORE, AFTER);
        assertEq(paused, true, "completed post-window must pause after pending falls through");
        assertEq(ts, completedTime, "fall-through must report the COMPLETED action's effectiveTime");
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

    /// Cursor `0` is a REAL node (the bootstrap slot), not the no-match
    /// sentinel — the sentinel is `NODE_NONE = type(uint256).max`. A COMPLETED
    /// matching action whose cursor happens to be `0` and whose post-window
    /// contains `now` MUST pause. Guards the completed-branch sentinel check
    /// `completedCursor != NODE_NONE`: a regression to `completedCursor != 0`
    /// would treat the legitimate bootstrap-slot node as no-match and fail to
    /// pause. Uses a real STOCK_SPLIT type (not INIT) so the strip is irrelevant.
    function testCompletedCursorZeroRealActionStillPauses() external {
        uint64 effectiveTime = uint64(block.timestamp - AFTER / 2);
        mock.setLatestCompleted(0, ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);
        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_STOCK_SPLIT_V1, BEFORE, AFTER);
        assertEq(paused, true, "completed action with cursor 0 (real bootstrap slot) must pause");
        assertEq(ts, effectiveTime);
    }

    /// Symmetric to the above for the PENDING branch: a matching pending action
    /// with cursor `0` inside its pre-window MUST pause. Guards
    /// `pendingCursor != NODE_NONE` against a regression to `!= 0`.
    function testPendingCursorZeroRealActionStillPauses() external {
        uint64 effectiveTime = uint64(block.timestamp + BEFORE / 2);
        mock.setEarliestPending(0, ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);
        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_STOCK_SPLIT_V1, BEFORE, AFTER);
        assertEq(paused, true, "pending action with cursor 0 (real bootstrap slot) must pause");
        assertEq(ts, effectiveTime);
    }

    // -------- Audit regression: NODE_NONE no-match sentinel --------

    /// `ICorporateActionsV1.{earliest,latest}ActionOfType` return `NODE_NONE`
    /// for no-match. The lib's pre-fix `cursor != 0` check entered the match
    /// branch and returned `(true, 0)`, bricking every oracle that had
    /// `corporateActionsVault` set. After fix, `cursor != NODE_NONE` correctly
    /// short-circuits to `(false, 0)`.
    function testNodeNoneSentinelOnBothSidesDoesNotPause() external {
        // Both branches explicitly set to no-match via NODE_NONE.
        mock.setEarliestPending(NODE_NONE, ACTION_TYPE_STOCK_SPLIT_V1, 0);
        mock.setLatestCompleted(NODE_NONE, ACTION_TYPE_STOCK_SPLIT_V1, 0);
        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_STOCK_SPLIT_V1, BEFORE, AFTER);
        assertEq(paused, false);
        assertEq(ts, 0);
    }

    // -------- Audit #200: cancelled-node effectiveTime==0 sentinel guard --------

    /// `effectiveTime == 0` is the documented sentinel for a cancelled
    /// (unlinked) node. Under the upstream unlinking contract such a node is
    /// never returned by the traversal API, but if a future regression leaked
    /// one through with a real (non-`NODE_NONE`) cursor, the naive predicate
    /// `now + before >= 0` would be trivially true and the library would return
    /// `(true, 0)` — a spurious pause reporting a zero effectiveTime. The
    /// defensive `pendingEffective != 0` guard rejects it. Closes audit #200
    /// (pending side).
    function testPendingCancelledSentinelEffectiveZeroDoesNotPause() external {
        // Leaked cancelled node: real cursor, effectiveTime unlinked to 0.
        mock.setEarliestPending(1, ACTION_TYPE_STOCK_SPLIT_V1, 0);
        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_STOCK_SPLIT_V1, BEFORE, AFTER);
        assertEq(paused, false, "cancelled-node sentinel (effectiveTime==0) must not pause on the pending branch");
        assertEq(ts, 0);
    }

    /// Symmetric to the above for the COMPLETED branch: a leaked cancelled node
    /// with a real cursor and `effectiveTime == 0` must not open a post-window.
    /// The predicate `now <= 0 + after` would otherwise be false only for
    /// `after < now`; at boot / low timestamps it could pause spuriously. Guard
    /// via `completedEffective != 0`. Closes audit #200 (completed side).
    function testCompletedCancelledSentinelEffectiveZeroDoesNotPause() external {
        mock.setLatestCompleted(1, ACTION_TYPE_STOCK_SPLIT_V1, 0);
        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_STOCK_SPLIT_V1, BEFORE, type(uint64).max);
        assertEq(paused, false, "cancelled-node sentinel (effectiveTime==0) must not pause on the completed branch");
        assertEq(ts, 0);
    }

    /// A leaked cancelled PENDING sentinel must be skipped WITHOUT swallowing a
    /// legitimately-open COMPLETED post-window — proves the pending guard
    /// degrades to "no pending action" and falls through. #200.
    function testPendingCancelledSentinelFallsThroughToCompleted() external {
        mock.setEarliestPending(1, ACTION_TYPE_STOCK_SPLIT_V1, 0);
        uint64 completedTime = uint64(block.timestamp - AFTER / 2);
        mock.setLatestCompleted(2, ACTION_TYPE_STOCK_SPLIT_V1, completedTime);
        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_STOCK_SPLIT_V1, BEFORE, AFTER);
        assertEq(paused, true, "cancelled pending sentinel must fall through to a real completed post-window");
        assertEq(ts, completedTime);
    }

    /// Under a wildcard mask the `ACTION_TYPE_INIT_V1` bootstrap node must NOT
    /// trigger a pause: it is a price-irrelevant bookkeeping entry that
    /// completes in the same block as the first `scheduleCorporateAction`, so
    /// matching it would spuriously auto-pause on routine vault setup (audit
    /// #41). The library strips the INIT bit before querying.
    function testWildcardMaskIgnoresBootstrapInitNode() external {
        uint64 effectiveTime = uint64(block.timestamp - 60);
        // The only "action" is the bootstrap INIT node, freshly completed and
        // well inside the post-window — yet the wildcard mask must not pause.
        mock.setLatestCompleted(0, ACTION_TYPE_INIT_V1, effectiveTime);
        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(mock), type(uint256).max, BEFORE, AFTER);
        assertEq(paused, false, "INIT bootstrap node must not pause");
        assertEq(ts, 0);
    }

    /// The INIT strip must be applied to the PENDING query too, not just the
    /// COMPLETED one. `testWildcardMaskIgnoresBootstrapInitNode` only exercises
    /// the completed side, so passing the raw (un-stripped) `mask` to
    /// `earliestActionOfType` while stripping it for `latestActionOfType` goes
    /// unnoticed. An INIT-typed node that is still PENDING is exactly the shape
    /// the strip exists to suppress — the bootstrap entry is a price-irrelevant
    /// bookkeeping row, so it must not open a pre-window under the recommended
    /// `type(uint256).max` mask either. Discriminating value: not paused with a
    /// zero effectiveTime, versus `(true, effectiveTime)` if the pending query
    /// forwards the unstripped mask.
    function testWildcardMaskIgnoresInitNodeOnPendingQuery() external {
        uint64 effectiveTime = uint64(block.timestamp + BEFORE / 2);
        // The only "action" is an INIT-typed node sitting squarely inside the
        // pre-window; the wildcard mask must still not pause on it.
        mock.setEarliestPending(1, ACTION_TYPE_INIT_V1, effectiveTime);
        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(mock), type(uint256).max, BEFORE, AFTER);
        assertEq(paused, false, "INIT node must not open a pre-window: the PENDING query must strip the INIT bit");
        assertEq(ts, 0);
    }

    /// The INIT strip must not disarm the wildcard mask for REAL actions: a
    /// completed stock split under `type(uint256).max` still pauses.
    function testWildcardMaskStillMatchesRealAction() external {
        uint64 effectiveTime = uint64(block.timestamp - 60);
        mock.setLatestCompleted(1, ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);
        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(mock), type(uint256).max, BEFORE, AFTER);
        assertEq(paused, true, "real action under wildcard mask still pauses");
        assertEq(ts, effectiveTime);
    }

    /// A mask of exactly `ACTION_TYPE_INIT_V1` reduces to the empty mask after
    /// the strip and short-circuits to not-paused.
    function testInitOnlyMaskShortCircuits() external {
        mock.setLatestCompleted(0, ACTION_TYPE_INIT_V1, uint64(block.timestamp - 60));
        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_INIT_V1, BEFORE, AFTER);
        assertEq(paused, false, "INIT-only mask short-circuits");
        assertEq(ts, 0);
    }

    // -------- Defensive boundary tests (audit #72) --------

    /// Defence-in-depth (audit #199): `pendingEffective > block.timestamp` is
    /// guaranteed server-side by the PENDING completion filter, and the library
    /// now re-asserts it locally. If a misbehaving upstream returned a "PENDING"
    /// action with `effectiveTime == now`, the pre-window predicate `now +
    /// before >= pendingEffective` would be trivially satisfied for any
    /// `pauseTimeBefore` and spuriously open a pre-window. The local guard skips
    /// such a phantom node and cleanly degrades to "no pending action" — it must
    /// NOT pause and must NOT revert. Closes audit #72 (a) / #199 (pending side).
    function testPendingEffectiveAtNowDoesNotPauseDefensive() external {
        // Upstream invariant violation: PENDING action with effective time at
        // exactly `now`.
        uint64 effectiveTime = uint64(block.timestamp);
        mock.setEarliestPending(1, ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);
        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_STOCK_SPLIT_V1, BEFORE, AFTER);
        assertEq(paused, false, "phantom PENDING (effectiveTime <= now) must be skipped, not paused");
        assertEq(ts, 0);
    }

    /// Symmetric to the above with a strictly-past effectiveTime: a "PENDING"
    /// action whose effectiveTime is well before `now` must be skipped by the
    /// local re-assertion rather than spuriously opening a pre-window. #199.
    function testPendingEffectiveInPastDoesNotPauseDefensive() external {
        uint64 effectiveTime = uint64(block.timestamp - 1);
        mock.setEarliestPending(1, ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);
        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_STOCK_SPLIT_V1, type(uint64).max, AFTER);
        assertEq(paused, false, "phantom PENDING with past effectiveTime must not open a pre-window");
        assertEq(ts, 0);
    }

    /// Symmetric post-window defence (#199): a "COMPLETED" action whose
    /// effectiveTime is in the future is a filter regression — the library must
    /// skip it rather than open a phantom post-window. Cleanly degrades to "no
    /// completed action", never reverts.
    function testCompletedEffectiveInFutureDoesNotPauseDefensive() external {
        uint64 effectiveTime = uint64(block.timestamp + 1);
        mock.setLatestCompleted(1, ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);
        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_STOCK_SPLIT_V1, BEFORE, type(uint64).max);
        assertEq(paused, false, "phantom COMPLETED with future effectiveTime must not open a post-window");
        assertEq(ts, 0);
    }

    /// A phantom PENDING (effectiveTime <= now) must be skipped WITHOUT
    /// swallowing a legitimately-open COMPLETED post-window. Proves the pending
    /// re-assertion degrades to "no pending action" and falls through to the
    /// completed branch rather than returning early. #199.
    function testPhantomPendingFallsThroughToCompleted() external {
        // Phantom PENDING at exactly now.
        mock.setEarliestPending(1, ACTION_TYPE_STOCK_SPLIT_V1, uint64(block.timestamp));
        // Real COMPLETED inside its post-window.
        uint64 completedTime = uint64(block.timestamp - AFTER / 2);
        mock.setLatestCompleted(2, ACTION_TYPE_STOCK_SPLIT_V1, completedTime);
        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_STOCK_SPLIT_V1, BEFORE, AFTER);
        assertEq(paused, true, "phantom pending must fall through to a real completed post-window");
        assertEq(ts, completedTime);
    }

    /// `pauseTimeAfter == type(uint64).max` must not overflow the post-window
    /// addition `completedEffective + pauseTimeAfter`. The addition is in
    /// uint256 space so it cannot overflow for any realistic timestamp; this
    /// test pins that guarantee against accidental narrowing to uint64. Closes
    /// audit #72 (b).
    function testMaxPauseTimeAfterDoesNotOverflow() external {
        uint64 effectiveTime = uint64(block.timestamp - 1);
        mock.setLatestCompleted(1, ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);
        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_STOCK_SPLIT_V1, BEFORE, type(uint64).max);
        assertEq(paused, true, "max pauseTimeAfter must not overflow");
        assertEq(ts, effectiveTime);
    }

    /// Symmetric before-side overflow guard (audit #255). The completed branch
    /// has `testMaxPauseTimeAfterDoesNotOverflow`; the pending pre-window
    /// arithmetic `block.timestamp + uint256(pauseTimeBefore)` must likewise be
    /// promoted to uint256 so `pauseTimeBefore == type(uint64).max` neither
    /// overflows nor wraps and silently flips the pre-window predicate. A
    /// regression narrowing the addition to uint64 would wrap and fail this.
    function testMaxPauseTimeBeforeDoesNotOverflow() external {
        uint64 effectiveTime = uint64(block.timestamp + 10 days);
        mock.setEarliestPending(1, ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);
        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_STOCK_SPLIT_V1, type(uint64).max, AFTER);
        assertEq(paused, true, "max pauseTimeBefore must not overflow and must open the pre-window");
        assertEq(ts, effectiveTime);
    }

    /// `pauseTimeBefore == 0` collapses the pre-window to a single instant:
    /// the predicate `block.timestamp + 0 >= pendingEffective` is true iff
    /// `pendingEffective <= now`. When the upstream honours the PENDING
    /// invariant (`pendingEffective > now`), the predicate is false and the
    /// oracle does not pause — already covered by
    /// `testZeroBeforeWithExactPendingReturnsFalse`. The symmetric boundary,
    /// where `pendingEffective` equals exactly `now`, is the upstream-
    /// invariant edge. Before audit #199 the naive predicate `now + 0 >= now`
    /// would have paused on this phantom; the local re-assertion of the PENDING
    /// filter (`effectiveTime > now`) now skips it, so the oracle does NOT
    /// pause. Closes audit #72 (c), tightened by #199.
    function testZeroBeforeWithPendingAtNowDoesNotPause() external {
        mock.setEarliestPending(1, ACTION_TYPE_STOCK_SPLIT_V1, uint64(block.timestamp));
        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_STOCK_SPLIT_V1, 0, AFTER);
        assertEq(paused, false, "phantom PENDING at exactly now must be skipped by the local filter re-assertion");
        assertEq(ts, 0);
    }

    // -------- Cursor is authoritative over effectiveTime --------

    /// The CURSOR is the no-match sentinel, not the effectiveTime. A vault that
    /// returned the incoherent pair `(NODE_NONE, type, futureTime)` — no-match
    /// cursor next to a live-looking pre-window effectiveTime — must be read as
    /// "no pending action". `MockCorporateActions` cannot express this pair (it
    /// derives no-match from the cursor and always zeroes the tuple), so a
    /// regression loosening the guard to `pendingCursor != NODE_NONE ||
    /// pendingEffective != 0` would enter the branch on a pure sentinel and
    /// pause on a phantom whose "effectiveTime" is really the traversal's
    /// zero-value padding. Discriminating value: `(false, 0)` rather than
    /// `(true, effectiveTime)`.
    function testNodeNoneCursorWithLiveEffectiveTimeIsNoMatchPending() external {
        MockMalformedCorporateActions malformed = new MockMalformedCorporateActions();
        uint64 effectiveTime = uint64(block.timestamp + BEFORE / 2);
        malformed.setEarliestRaw(NODE_NONE, ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);
        // Completed side left at the coherent no-match default (cursor 0 is a
        // real slot, so zero its effectiveTime to keep it inert).
        malformed.setLatestRaw(NODE_NONE, 0, 0);
        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(malformed), ACTION_TYPE_STOCK_SPLIT_V1, BEFORE, AFTER);
        assertEq(paused, false, "NODE_NONE pending cursor must be no-match even with a live-looking effectiveTime");
        assertEq(ts, 0);
    }

    /// Symmetric to the above on the COMPLETED branch: a `NODE_NONE` cursor
    /// paired with an effectiveTime whose post-window contains `now` is still
    /// no-match. Pins that the completed guard is a conjunction, so the cursor
    /// sentinel alone is sufficient to reject.
    function testNodeNoneCursorWithLiveEffectiveTimeIsNoMatchCompleted() external {
        MockMalformedCorporateActions malformed = new MockMalformedCorporateActions();
        uint64 effectiveTime = uint64(block.timestamp - AFTER / 2);
        malformed.setEarliestRaw(NODE_NONE, 0, 0);
        malformed.setLatestRaw(NODE_NONE, ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);
        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(malformed), ACTION_TYPE_STOCK_SPLIT_V1, BEFORE, AFTER);
        assertEq(paused, false, "NODE_NONE completed cursor must be no-match even with an in-window effectiveTime");
        assertEq(ts, 0);
    }

    /// Invariant: `effectiveTime` is zero iff `paused` is false. Fuzz the
    /// presence and timing of pending and completed actions and assert the
    /// invariant holds.
    function testFuzzPausedFalseImpliesEffectiveTimeZero(
        uint64 pauseBefore,
        uint64 pauseAfter,
        bool pendingPresent,
        uint64 pendingDelta,
        bool completedPresent,
        uint64 completedDelta
    ) external {
        // Warp into 2033 so 30-day deltas never underflow the timestamp.
        vm.warp(2_000_000_000);
        pauseBefore = uint64(bound(pauseBefore, 0, 10 days));
        pauseAfter = uint64(bound(pauseAfter, 0, 10 days));
        uint64 pendingEffective = uint64(block.timestamp) + uint64(bound(pendingDelta, 1, 30 days));
        uint64 completedEffective = uint64(block.timestamp) - uint64(bound(completedDelta, 0, 30 days));

        if (pendingPresent) {
            mock.setEarliestPending(1, ACTION_TYPE_STOCK_SPLIT_V1, pendingEffective);
        } else {
            mock.setEarliestPending(NODE_NONE, 0, 0);
        }
        if (completedPresent) {
            mock.setLatestCompleted(2, ACTION_TYPE_STOCK_SPLIT_V1, completedEffective);
        } else {
            mock.setLatestCompleted(NODE_NONE, 0, 0);
        }

        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_STOCK_SPLIT_V1, pauseBefore, pauseAfter);

        if (!paused) {
            assertEq(ts, 0, "paused=false must imply effectiveTime=0");
        } else {
            assertGt(ts, 0, "paused=true must report a non-zero effectiveTime");
        }
    }
}
