// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {MorphoPairOracle} from "src/concrete/oracle/MorphoPairOracle.sol";
import {ST0xPriceOracle} from "src/concrete/oracle/ST0xPriceOracle.sol";

/// @title MorphoPairOracleV2
/// @dev Trivial V2 implementation used only to prove that upgrading the
/// shared adapter beacon retargets every deployed MorphoPairOracle proxy
/// at once.
contract MorphoPairOracleV2 is MorphoPairOracle {
    constructor(ST0xPriceOracle central) MorphoPairOracle(central) {}

    function version() external pure returns (uint256) {
        return 2;
    }
}
