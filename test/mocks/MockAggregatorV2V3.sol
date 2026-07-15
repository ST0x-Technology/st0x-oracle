// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {AggregatorV2V3Interface} from "../../src/interface/IAggregatorV2V3.sol";

/// @title MockAggregatorV2V3
/// @notice Scriptable mock of `AggregatorV2V3Interface` for unit-testing
/// adapters that wrap an upstream aggregator. Each read method returns the
/// value previously set via the matching setter. `getRoundData` reverts by
/// default — flip `setGetRoundDataReverts(false)` to make it return the same
/// scripted 5-tuple as `latestRoundData`. The default-revert behaviour lets
/// pause-gated tests verify the wrapper short-circuits BEFORE delegating
/// (a paused wrapper that still hit the upstream would surface a different
/// error than `OraclePaused*`).
contract MockAggregatorV2V3 is AggregatorV2V3Interface {
    uint8 private _decimals;
    string private _description;
    uint256 private _version;
    int256 private _latestAnswer;
    uint80 private _roundId;
    int256 private _answer;
    uint256 private _startedAt;
    uint256 private _updatedAt;
    uint80 private _answeredInRound;
    bool private _getRoundDataReverts = true;

    function setDecimals(uint8 d) external {
        _decimals = d;
    }

    function setDescription(string calldata s) external {
        _description = s;
    }

    function setVersion(uint256 v) external {
        _version = v;
    }

    function setLatestAnswer(int256 a) external {
        _latestAnswer = a;
    }

    function setLatestRoundData(
        uint80 roundId_,
        int256 answer_,
        uint256 startedAt_,
        uint256 updatedAt_,
        uint80 answeredInRound_
    ) external {
        _roundId = roundId_;
        _answer = answer_;
        _startedAt = startedAt_;
        _updatedAt = updatedAt_;
        _answeredInRound = answeredInRound_;
    }

    function setGetRoundDataReverts(bool reverts) external {
        _getRoundDataReverts = reverts;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external view override returns (string memory) {
        return _description;
    }

    function version() external view override returns (uint256) {
        return _version;
    }

    function latestAnswer() external view override returns (int256) {
        return _latestAnswer;
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }

    function getRoundData(uint80) external view override returns (uint80, int256, uint256, uint256, uint80) {
        if (_getRoundDataReverts) revert("mock: getRoundData reverts");
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }
}
