// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {CompletionFilter, LibCorporateActionNode} from "st0x-deploy-0.1.1/src/lib/LibCorporateActionNode.sol";
import {LibCorporateAction} from "st0x-deploy-0.1.1/src/lib/LibCorporateAction.sol";

/// @title CorporateActionsListHarness
/// @notice Thin harness that drives the REAL upstream corporate-action list
/// primitives — `LibCorporateAction.schedule` / `.cancel` and
/// `LibCorporateActionNode.{earliest,latest}ActionOfType` — directly against
/// this contract's own ERC-7201 storage.
///
/// Why not the real `StoxCorporateActionsFacet`? That facet carries
/// `onlyDelegatecalled` on every entry point (including the view getters), so a
/// standalone `new StoxCorporateActionsFacet()` reverts `FacetMustBeDelegatecalled`
/// on any direct call; exercising it requires a full delegatecall + authorizer
/// + `OffchainAssetReceiptVault` harness. The conventions audit #216 pins — the
/// no-match sentinel, mask filter shape, effective-time monotonicity, and
/// `cancel` unlinking — all live in `LibCorporateAction` / `LibCorporateActionNode`,
/// which the facet merely delegates to verbatim (see
/// `StoxCorporateActionsFacet.{earliest,latest}ActionOfType`). Driving those
/// libraries directly exercises the identical traversal + list-mutation code
/// path the facet exposes, with none of the delegatecall scaffolding, and pins
/// exactly the wire-format conventions `LibCorporateActionsPause` depends on.
///
/// `schedule` is called with an already-resolved `actionType`, bypassing
/// `resolveActionType` (which validates stock-split params via the vault's
/// ERC20 `decimals()` — irrelevant to list-shape conventions and not wired on a
/// bare harness). The list insert/traversal/unlink logic is unaffected by the
/// stored `parameters` payload.
contract CorporateActionsListHarness {
    function schedule(uint256 actionType, uint64 effectiveTime) external returns (uint256) {
        return LibCorporateAction.schedule(actionType, effectiveTime, "");
    }

    function cancel(uint256 actionId) external {
        LibCorporateAction.cancel(actionId);
    }

    function earliestActionOfType(uint256 mask, CompletionFilter filter)
        external
        view
        returns (uint256, uint256, uint64)
    {
        return LibCorporateActionNode.earliestActionOfType(mask, filter);
    }

    function latestActionOfType(uint256 mask, CompletionFilter filter)
        external
        view
        returns (uint256, uint256, uint64)
    {
        return LibCorporateActionNode.latestActionOfType(mask, filter);
    }
}
