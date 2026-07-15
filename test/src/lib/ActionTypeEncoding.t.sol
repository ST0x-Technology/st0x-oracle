// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.1/src/Test.sol";
import {
    ACTION_TYPE_INIT_V1,
    ACTION_TYPE_STOCK_SPLIT_V1,
    ACTION_TYPE_STABLES_DIVIDEND_V1
} from "st0x-deploy-0.1.1/src/interface/ICorporateActionsV1.sol";

/// @title ActionTypeEncodingTest
/// @notice Pins the `st0x-deploy` action-type bitmap that SPEC.md §5.2 and
/// `PausableOracleWrapper`'s NatSpec restate by value. Nothing else forces
/// those first-party restatements to agree with the dependency; this test
/// fires on any soldeer bump that re-encodes the bitmap, forcing every
/// documented `actionTypeMask` recipe to be re-verified before it ships. A
/// silent bit drift would make an operator's mask match the wrong (or no)
/// action, so the flagship auto-pause silently never fires — this is the
/// enforcement that catches it.
contract ActionTypeEncodingTest is Test {
    function testActionTypeBitsMatchDocumentedEncoding() external pure {
        assertEq(ACTION_TYPE_INIT_V1, 1 << 0, "INIT bit drifted from docs");
        assertEq(ACTION_TYPE_STOCK_SPLIT_V1, 1 << 1, "STOCK_SPLIT bit drifted from docs");
        assertEq(ACTION_TYPE_STABLES_DIVIDEND_V1, 1 << 2, "STABLES_DIVIDEND bit drifted from docs");
    }
}
