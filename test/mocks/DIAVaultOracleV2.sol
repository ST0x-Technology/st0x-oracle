// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {DIAVaultOracle} from "src/concrete/oracle/DIAVaultOracle.sol";

/// @title DIAVaultOracleV2
/// @dev Trivial V2 implementation used only to prove that upgrading the shared
/// DIAVaultOracle beacon retargets every deployed proxy at once. Adds a fresh
/// `implVersion()` getter absent from V1, so a proxy answering it is proof the
/// beacon has been retargeted, while all V1 storage getters keep working.
contract DIAVaultOracleV2 is DIAVaultOracle {
    function implVersion() external pure returns (uint256) {
        return 2;
    }
}
