// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {IChronicle} from "src/interface/IChronicle.sol";

/// @title MockChronicle
/// @notice Minimal mock of `IChronicle` for unit-testing oracle consumers.
/// Tests script the `(value, age)` returned by `readWithAge`/`read` via the
/// setters. Methods not consumed by `ChronicleVaultOracle` revert so a
/// regression that reaches into the rest of the interface surfaces loudly.
contract MockChronicle is IChronicle {
    uint256 private _value;
    uint256 private _age;

    function setReadWithAge(uint256 value_, uint256 age_) external {
        _value = value_;
        _age = age_;
    }

    function setRead(uint256 value_) external {
        _value = value_;
    }

    function read() external view override returns (uint256) {
        return _value;
    }

    function readWithAge() external view override returns (uint256, uint256) {
        return (_value, _age);
    }

    function wat() external pure override returns (bytes32) {
        revert("mock: not implemented");
    }

    function tryRead() external pure override returns (bool, uint256) {
        revert("mock: not implemented");
    }

    function tryReadWithAge() external pure override returns (bool, uint256, uint256) {
        revert("mock: not implemented");
    }
}
