// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {ST0xPriceOracle} from "../../src/concrete/oracle/ST0xPriceOracle.sol";

/// @title ST0xPriceOracleV2
/// @dev Trivial V2 implementation used only to prove that upgrading the shared
/// ST0xPriceOracle beacon retargets every deployed proxy at once. Adds a fresh
/// `implVersion()` getter absent from V1, so a proxy answering it is proof the
/// beacon has been retargeted, while all V1 storage getters keep working.
contract ST0xPriceOracleV2 is ST0xPriceOracle {
    function implVersion() external pure returns (uint256) {
        return 2;
    }
}
