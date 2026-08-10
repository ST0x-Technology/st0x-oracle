// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {ICorporateActionsV1} from "st0x-deploy-0.1.1/src/interface/ICorporateActionsV1.sol";
import {CompletionFilter} from "st0x-deploy-0.1.1/src/lib/LibCorporateActionNode.sol";

/// @title MockMalformedCorporateActions
/// @notice A vault-shaped stub that returns caller-supplied traversal tuples
/// VERBATIM, with no internal consistency enforced between the cursor and the
/// effectiveTime.
///
/// `MockCorporateActions` deliberately models a well-behaved vault: it derives
/// "no match" from the cursor and therefore can only ever emit the coherent
/// pair `(NODE_NONE, 0, 0)`. That makes it structurally incapable of expressing
/// a *malformed* return such as `(NODE_NONE, type, futureTime)` — a no-match
/// cursor paired with a live-looking effectiveTime. This mock exists purely to
/// express those incoherent tuples so tests can pin which of the two fields
/// `LibCorporateActionsPause` treats as authoritative: the CURSOR is the
/// no-match sentinel, so a `NODE_NONE` cursor must be rejected regardless of
/// what effectiveTime came back alongside it.
///
/// The completion filter is NOT validated here (unlike `MockCorporateActions`)
/// because these tests are about the cursor/effectiveTime pair, not the filter
/// wiring, which is pinned separately.
contract MockMalformedCorporateActions is ICorporateActionsV1 {
    uint256 private _earliestCursor;
    uint256 private _earliestType;
    uint64 private _earliestEffective;

    uint256 private _latestCursor;
    uint256 private _latestType;
    uint64 private _latestEffective;

    function setEarliestRaw(uint256 cursor, uint256 actionType, uint64 effectiveTime) external {
        _earliestCursor = cursor;
        _earliestType = actionType;
        _earliestEffective = effectiveTime;
    }

    function setLatestRaw(uint256 cursor, uint256 actionType, uint64 effectiveTime) external {
        _latestCursor = cursor;
        _latestType = actionType;
        _latestEffective = effectiveTime;
    }

    function earliestActionOfType(uint256, CompletionFilter) external view override returns (uint256, uint256, uint64) {
        return (_earliestCursor, _earliestType, _earliestEffective);
    }

    function latestActionOfType(uint256, CompletionFilter) external view override returns (uint256, uint256, uint64) {
        return (_latestCursor, _latestType, _latestEffective);
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
