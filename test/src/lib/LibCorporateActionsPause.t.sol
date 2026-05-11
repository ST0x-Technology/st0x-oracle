// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {NODE_NONE} from "st0x.deploy/src/lib/LibCorporateActionNode.sol";
import {LibCorporateActionsPause} from "st0x.oracle/lib/LibCorporateActionsPause.sol";
import {ACTION_TYPE_STOCK_SPLIT_V1} from "st0x.deploy/src/interface/ICorporateActionsV1.sol";
import {MockCorporateActions} from "test/mocks/MockCorporateActions.sol";

/// @dev A vault that reverts on any call. Exercises the "vault implements
/// `ICorporateActionsV1` but throws" path so consumers see the underlying
/// revert verbatim rather than a swallowed failure.
contract RevertingCorporateActions {
    fallback() external payable {
        revert("vault-reverts");
    }
}

/// @dev Wrapper that calls `inPauseWindow` through an external function so
/// `vm.expectRevert` is the cheatcode immediately before a real (non-inlined)
/// external call — its depth bookkeeping treats library-internal subcalls as
/// "current depth" otherwise. Mirrors the pattern used by tests for other
/// `internal` library functions in this repo.
contract InPauseWindowCaller {
    function call(address vault, uint256 mask, uint64 before, uint64 afterT) external view returns (bool, uint64) {
        return LibCorporateActionsPause.inPauseWindow(vault, mask, before, afterT);
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

    /// Wildcard-mask deployment must accept the bootstrap node at cursor 0
    /// (`ACTION_TYPE_INIT_V1 = 1 << 0`) as a real match. Pre-fix the
    /// `cursor != 0` check silently dropped it.
    function testWildcardMaskAcceptsBootstrapCursorZero() external {
        uint256 INIT = 1 << 0;
        uint64 effectiveTime = uint64(block.timestamp - 60);
        // No pending; completed is the bootstrap node at cursor 0.
        mock.setLatestCompleted(0, INIT, effectiveTime);
        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(mock), type(uint256).max, BEFORE, AFTER);
        assertEq(paused, true);
        assertEq(ts, effectiveTime);
    }

    // -------- Defensive boundary tests (audit #72) --------

    /// Per the library's comment, `pendingEffective > block.timestamp` is
    /// guaranteed by the PENDING completion filter on the upstream vault, not
    /// re-validated here. If a misbehaving upstream returned a pending action
    /// with `effectiveTime <= now`, the pre-window predicate `now + before >=
    /// pendingEffective` is trivially satisfied for any non-negative
    /// `pauseTimeBefore`, so the oracle would pause. Pin this behaviour so a
    /// future refactor that adds a local guard surfaces as a deliberate test
    /// update. Closes audit #72 (a).
    function testPendingEffectiveAtNowStillPausesDefensive() external {
        // Upstream invariant violation: PENDING action with effective time at
        // exactly `now`.
        uint64 effectiveTime = uint64(block.timestamp);
        mock.setEarliestPending(1, ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);
        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_STOCK_SPLIT_V1, BEFORE, AFTER);
        // Current behaviour: pauses because `now + BEFORE >= now`.
        assertEq(paused, true, "current lib pauses when upstream returns pendingEffective <= now");
        assertEq(ts, effectiveTime);
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

    /// `pauseTimeBefore == 0` collapses the pre-window to a single instant:
    /// the predicate `block.timestamp + 0 >= pendingEffective` is true iff
    /// `pendingEffective <= now`. When the upstream honours the PENDING
    /// invariant (`pendingEffective > now`), the predicate is false and the
    /// oracle does not pause — already covered by
    /// `testZeroBeforeWithExactPendingReturnsFalse`. The symmetric boundary,
    /// where `pendingEffective` equals exactly `now`, is the upstream-
    /// invariant edge: lib trusts the filter, but if the filter ever
    /// included an `effectiveTime == now` action as PENDING, the oracle
    /// would pause. Closes audit #72 (c).
    function testZeroBeforeWithPendingAtNowPauses() external {
        mock.setEarliestPending(1, ACTION_TYPE_STOCK_SPLIT_V1, uint64(block.timestamp));
        (bool paused, uint64 ts) =
            LibCorporateActionsPause.inPauseWindow(address(mock), ACTION_TYPE_STOCK_SPLIT_V1, 0, AFTER);
        // `now + 0 >= now` is true, so the pre-window matches at the instant.
        assertEq(paused, true);
        assertEq(ts, uint64(block.timestamp));
    }

    /// A non-zero vault address whose external call reverts MUST propagate
    /// the underlying revert verbatim — the lib trusts the vault as an
    /// immutable post-init field and does not `try/catch`. A future refactor
    /// that swallowed reverts (silently `(false, 0)`) would be a security
    /// regression; pin the propagation here. Closes audit #74.
    function testRevertingVaultPropagates() external {
        RevertingCorporateActions reverting = new RevertingCorporateActions();
        InPauseWindowCaller caller = new InPauseWindowCaller();
        vm.expectRevert(bytes("vault-reverts"));
        caller.call(address(reverting), ACTION_TYPE_STOCK_SPLIT_V1, BEFORE, AFTER);
    }

    // Note: a `testEoaVaultPropagatesNoCodeBehaviour` covering "vault is
    // an EOA with no code → abi.decode failure propagates as empty revert"
    // was originally proposed for #74. It's been omitted because
    // foundry-nightly panics decoding the empty revert payload under -vvv
    // trace verbosity (alloy-dyn-abi-1.5.2 `decode_error` bug); the
    // `testRevertingVaultPropagates` test above is sufficient coverage
    // for the propagation contract that #74 asked for, and the EOA path
    // is foundry-runtime-specific rather than a Solidity invariant worth
    // pinning. Restore once foundry upgrades alloy-dyn-abi.

    /// SPEC §16.3: `effectiveTime` is zero iff `paused` is false. Fuzz the
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
            assertEq(ts, 0, "SPEC 16.3: paused=false must imply effectiveTime=0");
        } else {
            assertGt(ts, 0, "paused=true must report a non-zero effectiveTime");
        }
    }
}
