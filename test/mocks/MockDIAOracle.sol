// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {IDIAOracleV2} from "../../src/interface/IDIAOracleV2.sol";

/// @title MockDIAOracle
/// @notice Minimal scriptable mock of `IDIAOracleV2`. Tests script a feed via
/// `setValue(key, value, timestamp)` and the matching `getValue(key)` call
/// returns the same tuple. Keys that have never been set return `(0, 0)` —
/// mirroring DIA's production behaviour for a never-pushed feed and letting
/// `DIAVaultOracle._readDIAChecked` exercise its `DIAPriceNotSet` branch.
contract MockDIAOracle is IDIAOracleV2 {
    struct StubValue {
        uint128 value;
        uint128 timestamp;
    }

    mapping(string => StubValue) private _values;

    function setValue(string memory key, uint128 value, uint128 timestamp) external {
        _values[key] = StubValue({value: value, timestamp: timestamp});
    }

    function getValue(string memory key) external view override returns (uint128 value, uint128 timestamp) {
        StubValue memory v = _values[key];
        return (v.value, v.timestamp);
    }
}
