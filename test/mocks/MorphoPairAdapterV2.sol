// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {MorphoPairAdapter} from "../../src/concrete/adapter/MorphoPairAdapter.sol";
import {ST0xPriceOracle} from "../../src/concrete/oracle/ST0xPriceOracle.sol";

/// @title MorphoPairAdapterV2
/// @dev Trivial V2 implementation used only to prove that upgrading the
/// shared adapter beacon retargets every deployed MorphoPairAdapter proxy
/// at once.
contract MorphoPairAdapterV2 is MorphoPairAdapter {
    constructor(ST0xPriceOracle central) MorphoPairAdapter(central) {}

    function version() external pure returns (uint256) {
        return 2;
    }
}
