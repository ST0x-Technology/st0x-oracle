// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {PausableOracleWrapper} from "../../src/concrete/wrapper/PausableOracleWrapper.sol";

/// @title PausableOracleWrapperV2
/// @dev Trivial V2 implementation used only to prove that upgrading the shared
/// PausableOracleWrapper beacon retargets every deployed proxy at once. Adds a
/// fresh `implVersion()` getter absent from V1, so a proxy answering it is
/// proof the beacon has been retargeted, while all V1 storage getters keep
/// working. Note `version()` is already an upstream-delegating method on V1, so
/// a distinct name is used to avoid shadowing.
contract PausableOracleWrapperV2 is PausableOracleWrapper {
    function implVersion() external pure returns (uint256) {
        return 2;
    }
}
