// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Initializable} from "@openzeppelin-contracts-upgradeable-5.6.1/proxy/utils/Initializable.sol";

import {IOracle} from "src/interface/IOracle.sol";
import {ST0xPriceOracle} from "src/concrete/oracle/ST0xPriceOracle.sol";

/// @title MorphoPairOracle
/// @notice Thin adapter binding one Morpho Blue market to one pair on the
/// central `ST0xPriceOracle`. It is literally the interface: `price()`
/// forwards `iCentral.price(sPairId)` verbatim — scaling, staleness policy,
/// signer rotation and update mechanics all live on the central oracle.
///
/// Beacon-proxy implementation: every market's adapter is a `BeaconProxy`
/// over one shared `UpgradeableBeacon`, so upgrading the beacon retargets
/// ALL deployed adapters at once. The central oracle is an implementation
/// immutable — it is chain-constant and shared by every proxy, so it lives
/// in code, not in per-proxy storage. Only the per-market `sPairId` is
/// proxy storage, set once in `initialize`.
contract MorphoPairOracle is Initializable, IOracle {
    /// @notice The central multi-pair price store this adapter reads —
    /// chain-constant, shared by all beacon proxies, hence an
    /// implementation immutable.
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    ST0xPriceOracle public immutable iCentral;

    /// @notice The pair this adapter forwards, on `iCentral`'s canonical
    /// `pairId(base, quote)` derivation.
    bytes32 public sPairId;

    error ZeroCentral();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(ST0xPriceOracle central) {
        if (address(central) == address(0)) revert ZeroCentral();
        iCentral = central;
        _disableInitializers();
    }

    /// @notice Initialise one beacon proxy with the pair it forwards.
    function initialize(bytes32 pairId) external initializer {
        sPairId = pairId;
    }

    /// @inheritdoc IOracle
    function price() external view returns (uint256) {
        return iCentral.price(sPairId);
    }
}
