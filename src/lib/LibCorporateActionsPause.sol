// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {ICorporateActionsV1} from "st0x.deploy/src/interface/ICorporateActionsV1.sol";
import {CompletionFilter, NODE_NONE} from "st0x.deploy/src/lib/LibCorporateActionNode.sol";

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
    /// @param mask Bitmap of action types to consider. `0` short-circuits
    /// to `false` (no action types match anything). `type(uint256).max`
    /// matches every present and future action type.
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
        if (corporateActionsVault == address(0) || mask == 0) {
            return (false, 0);
        }

        ICorporateActionsV1 vault = ICorporateActionsV1(corporateActionsVault);

        (uint256 pendingCursor,, uint64 pendingEffective) = vault.earliestActionOfType(mask, CompletionFilter.PENDING);
        // `NODE_NONE = type(uint256).max` is the documented no-match sentinel
        // from `ICorporateActionsV1` — cursor `0` is a real bootstrap node and
        // must NOT be treated as "no match".
        if (pendingCursor != NODE_NONE) {
            // pendingEffective > now is guaranteed by the PENDING filter.
            // We compare via addition on uint256-promoted operands so neither
            // underflow nor overflow is possible for any realistic timestamp.
            if (block.timestamp + uint256(pauseTimeBefore) >= uint256(pendingEffective)) {
                return (true, pendingEffective);
            }
        }

        (uint256 completedCursor,, uint64 completedEffective) =
            vault.latestActionOfType(mask, CompletionFilter.COMPLETED);
        if (completedCursor != NODE_NONE) {
            // completedEffective <= now is guaranteed by the COMPLETED filter.
            if (block.timestamp <= uint256(completedEffective) + uint256(pauseTimeAfter)) {
                return (true, completedEffective);
            }
        }

        return (false, 0);
    }
}
