// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {DeployRecordLib} from "../../../src/generated/DeployRecordLib.sol";

/// @title DeployRecordHarness
/// @dev Test-only wrapper exposing the `internal` `DeployRecordLib` checks as
/// EXTERNAL functions. `vm.expectRevert` only catches reverts one call-frame
/// below the cheatcode; an inlined internal library call reverts at the same
/// depth ("call didn't revert at a lower depth"). Routing through this harness
/// gives the revert its own frame so the specific-error expectation works.
contract DeployRecordHarness {
    function verifyCodehash(address account, bytes32 expected) external view {
        DeployRecordLib.verifyCodehash(account, expected);
    }

    function verifyBeaconProxyAddress(address actual, address deployer, address beacon, bytes32 salt) external pure {
        DeployRecordLib.verifyBeaconProxyAddress(actual, deployer, beacon, salt);
    }
}
