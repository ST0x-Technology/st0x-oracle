// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {ICorporateActionsV1} from "st0x-deploy-0.1.1/src/interface/ICorporateActionsV1.sol";
import {CompletionFilter} from "st0x-deploy-0.1.1/src/lib/LibCorporateActionNode.sol";

/// @dev Raised by every read path of this mock.
error CorporateActionsUnavailable();

/// @title MockRevertingCorporateActions
/// @notice A corporate-actions vault whose traversal getters always revert —
/// stands in for a vault whose corporate-actions facet is not cut yet (or a
/// mask outside `VALID_ACTION_TYPES_MASK`). Used to prove `DIAVaultOracle`
/// probes the vault at `initialize`, so incompatible wiring reverts the deploy
/// transaction instead of every future read.
contract MockRevertingCorporateActions is ICorporateActionsV1 {
    function earliestActionOfType(uint256, CompletionFilter) external pure override returns (uint256, uint256, uint64) {
        revert CorporateActionsUnavailable();
    }

    function latestActionOfType(uint256, CompletionFilter) external pure override returns (uint256, uint256, uint64) {
        revert CorporateActionsUnavailable();
    }

    function scheduleCorporateAction(bytes32, uint64, bytes calldata) external pure override returns (uint256) {
        revert CorporateActionsUnavailable();
    }

    function cancelCorporateAction(uint256) external pure override {
        revert CorporateActionsUnavailable();
    }

    function completedActionCount() external pure override returns (uint256) {
        revert CorporateActionsUnavailable();
    }

    function nextOfType(uint256, uint256, CompletionFilter) external pure override returns (uint256, uint256, uint64) {
        revert CorporateActionsUnavailable();
    }

    function prevOfType(uint256, uint256, CompletionFilter) external pure override returns (uint256, uint256, uint64) {
        revert CorporateActionsUnavailable();
    }

    function getActionParameters(uint256) external pure override returns (bytes memory) {
        revert CorporateActionsUnavailable();
    }
}
