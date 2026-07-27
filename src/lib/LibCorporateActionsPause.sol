// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity ^0.8.25;

import {ICorporateActionsV1, ACTION_TYPE_INIT_V1} from "st0x-deploy-0.1.1/src/interface/ICorporateActionsV1.sol";
import {CompletionFilter, NODE_NONE} from "st0x-deploy-0.1.1/src/lib/LibCorporateActionNode.sol";

/// @title LibCorporateActionsPause
/// @notice Helper for oracle adapters that decide whether to auto-pause based
/// on a vault's `ICorporateActionsV1` schedule. Stateless, view-only.
///
/// The decision is the disjunction of two windows around any matching action:
///
/// 1. **Pre-window**: The earliest pending action `A` matching the mask, where
///    `effectiveTime - pauseTimeBefore <= block.timestamp < effectiveTime`.
///    Earliest pending is the one closest to `now`; if its window doesn't
///    open yet, no later pending's will either (their effectiveTimes are
///    strictly larger).
///
/// 2. **Post-window**: The latest completed action `A` matching the mask,
///    where `effectiveTime <= block.timestamp <= effectiveTime + pauseTimeAfter`.
///    Latest completed is the one closest to `now`; if its window has closed,
///    no earlier completed's is open (their effectiveTimes are strictly
///    smaller).
///
/// Each query is at most two view calls into the vault. Cancelled action
/// nodes are unlinked from the traversal API in `LibCorporateAction.cancel`,
/// so neither `earliestActionOfType` nor `latestActionOfType` will return
/// them — no explicit filter required here.
library LibCorporateActionsPause {
    /// @notice Whether the oracle should auto-pause right now.
    /// @param corporateActionsVault Address implementing `ICorporateActionsV1`.
    /// `address(0)` short-circuits to `false` (auto-pause disabled).
    /// @param mask Bitmap of action types to consider. The
    /// `ACTION_TYPE_INIT_V1` bit is always stripped before querying — the
    /// vault's bootstrap node is a price-irrelevant bookkeeping entry created
    /// (and completed) by the first `scheduleCorporateAction`, so matching it
    /// would spuriously open a post-window on a non-event. A mask that is `0`
    /// or exactly `ACTION_TYPE_INIT_V1` therefore short-circuits to `false`.
    /// `type(uint256).max` matches every present and future real action type.
    /// @param pauseTimeBefore Seconds before a pending action's `effectiveTime`
    /// to start pausing.
    /// @param pauseTimeAfter Seconds after a completed action's `effectiveTime`
    /// to keep pausing.
    /// @return paused True if the current block is inside any pre- or
    /// post-window of a matching action.
    /// @return effectiveTime The `effectiveTime` of the action whose window
    /// is currently open. Zero when `paused` is false. When both a pending
    /// and a completed action's window contain `now` (e.g. a back-to-back
    /// schedule), the pending action's `effectiveTime` is returned —
    /// integrators see the next event coming, not the last one done.
    function inPauseWindow(address corporateActionsVault, uint256 mask, uint64 pauseTimeBefore, uint64 pauseTimeAfter)
        internal
        view
        returns (bool paused, uint64 effectiveTime)
    {
        // Strip the bootstrap bit: `ACTION_TYPE_INIT_V1` is the vault's
        // lazily-created init node, completed in the same block as the first
        // `scheduleCorporateAction`. Matching it (notably under the
        // recommended `type(uint256).max` mask) would auto-pause the oracle
        // for the whole `pauseTimeAfter` on the mere act of scheduling any
        // first action — an unrecoverable spurious pause tied to a non-event.
        uint256 effectiveMask = mask & ~ACTION_TYPE_INIT_V1;
        if (corporateActionsVault == address(0) || effectiveMask == 0) {
            return (false, 0);
        }

        ICorporateActionsV1 vault = ICorporateActionsV1(corporateActionsVault);

        // The middle return (the matched action's actionType) is deliberately
        // discarded — the mask already constrained the match, so only the
        // cursor (match/no-match sentinel) and effectiveTime matter here.
        // slither-disable-next-line unused-return
        (uint256 pendingCursor,, uint64 pendingEffective) =
            vault.earliestActionOfType(effectiveMask, CompletionFilter.PENDING);
        // `NODE_NONE = type(uint256).max` is the documented no-match sentinel
        // from `ICorporateActionsV1` — cursor `0` is a real bootstrap node and
        // must NOT be treated as "no match".
        // `effectiveTime == 0` is the documented sentinel for a cancelled
        // (unlinked) node; under the upstream unlinking contract such a node
        // is never returned by the traversal API, but we reject it here as
        // defence-in-depth so a leaked cancelled node cannot yield `(true, 0)`.
        if (pendingCursor != NODE_NONE && pendingEffective != 0) {
            // Defence-in-depth: re-assert the PENDING filter's invariant
            // locally. `pendingEffective > now` is guaranteed server-side by
            // the PENDING completion filter; if a regressed vault returned a
            // "PENDING" action whose effectiveTime is already in the past, the
            // pre-window predicate `now + before >= pendingEffective` would be
            // trivially true for any `pauseTimeBefore` and spuriously open a
            // pre-window on a phantom action. Skip such a node — cleanly
            // degrade to "no pending action", never revert.
            if (uint256(pendingEffective) <= block.timestamp) {
                // Phantom pending: treat as no pending action.
            } else if (block.timestamp + uint256(pauseTimeBefore) >= uint256(pendingEffective)) {
                // We compare via addition on uint256-promoted operands so
                // neither underflow nor overflow is possible for any realistic
                // timestamp.
                // slither-disable-next-line timestamp
                return (true, pendingEffective);
            }
        }

        // Middle return (actionType) discarded as above — only cursor +
        // effectiveTime are needed.
        // slither-disable-next-line unused-return
        (uint256 completedCursor,, uint64 completedEffective) =
            vault.latestActionOfType(effectiveMask, CompletionFilter.COMPLETED);
        // Same `effectiveTime == 0` cancelled-node guard as the pending branch.
        if (completedCursor != NODE_NONE && completedEffective != 0) {
            // Defence-in-depth: re-assert the COMPLETED filter's invariant
            // locally. `completedEffective <= now` is guaranteed server-side by
            // the COMPLETED completion filter; if a regressed vault returned a
            // "COMPLETED" action whose effectiveTime is in the future, skip it
            // rather than open a phantom post-window. Cleanly degrade to "no
            // completed action", never revert.
            if (uint256(completedEffective) > block.timestamp) {
                // Phantom completed: treat as no completed action.
            } else if (block.timestamp <= uint256(completedEffective) + uint256(pauseTimeAfter)) {
                // slither-disable-next-line timestamp
                return (true, completedEffective);
            }
        }

        return (false, 0);
    }
}
