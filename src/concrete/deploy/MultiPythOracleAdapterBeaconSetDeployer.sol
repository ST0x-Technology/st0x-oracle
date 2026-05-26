// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {IBeacon} from "@openzeppelin-contracts-5.6.1/proxy/beacon/IBeacon.sol";
import {UpgradeableBeacon} from "@openzeppelin-contracts-5.6.1/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin-contracts-5.6.1/proxy/beacon/BeaconProxy.sol";
import {ICLONEABLE_V2_SUCCESS} from "rain-factory-0.1.1/src/interface/ICloneableV2.sol";
import {MultiPythOracleAdapter, MultiPythOracleAdapterConfig} from "src/concrete/oracle/MultiPythOracleAdapter.sol";

/// @dev Error raised when a zero address is provided for the implementation.
error MultiZeroImplementation();

/// @dev Error raised when a zero address is provided for the initial beacon
/// owner.
error MultiZeroBeaconOwner();

/// @dev Error raised when initialization of the oracle adapter fails.
error InitializeMultiOracleFailed();

/// @title MultiPythOracleAdapterBeaconSetDeployerConfig
/// @notice Configuration for the MultiPythOracleAdapterBeaconSetDeployer
/// construction.
/// @param initialOwner The initial owner of the beacon.
/// @param initialMultiPythOracleAdapterImplementation The initial implementation.
struct MultiPythOracleAdapterBeaconSetDeployerConfig {
    address initialOwner;
    address initialMultiPythOracleAdapterImplementation;
}

/// @title MultiPythOracleAdapterBeaconSetDeployer
/// @notice Deploys and manages a beacon set for MultiPythOracleAdapter contracts.
/// Follows the st0x.deploy BeaconSetDeployer pattern.
contract MultiPythOracleAdapterBeaconSetDeployer {
    /// Emitted when a new MultiPythOracleAdapter is deployed.
    event Deployment(address sender, address multiPythOracleAdapter);

    /// The beacon for the MultiPythOracleAdapter implementation contracts.
    IBeacon public immutable I_MULTI_PYTH_ORACLE_ADAPTER_BEACON;

    constructor(MultiPythOracleAdapterBeaconSetDeployerConfig memory config) {
        if (config.initialMultiPythOracleAdapterImplementation == address(0)) {
            revert MultiZeroImplementation();
        }
        if (config.initialOwner == address(0)) {
            revert MultiZeroBeaconOwner();
        }

        I_MULTI_PYTH_ORACLE_ADAPTER_BEACON =
            new UpgradeableBeacon(config.initialMultiPythOracleAdapterImplementation, config.initialOwner);
    }

    /// @notice Deploys and initializes a new MultiPythOracleAdapter proxy.
    /// @param config The initialization configuration.
    /// @return adapter The deployed MultiPythOracleAdapter proxy.
    // slither-disable-next-line reentrancy-events
    function newMultiPythOracleAdapter(MultiPythOracleAdapterConfig memory config)
        external
        returns (MultiPythOracleAdapter)
    {
        MultiPythOracleAdapter adapter =
            MultiPythOracleAdapter(address(new BeaconProxy(address(I_MULTI_PYTH_ORACLE_ADAPTER_BEACON), "")));

        if (adapter.initialize(abi.encode(config)) != ICLONEABLE_V2_SUCCESS) {
            revert InitializeMultiOracleFailed();
        }

        emit Deployment(msg.sender, address(adapter));

        return adapter;
    }
}
