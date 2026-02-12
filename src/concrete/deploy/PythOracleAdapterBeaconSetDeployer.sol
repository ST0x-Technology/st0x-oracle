// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {IBeacon} from "openzeppelin-contracts/contracts/proxy/beacon/IBeacon.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "openzeppelin-contracts/contracts/proxy/beacon/BeaconProxy.sol";
import {ICLONEABLE_V2_SUCCESS} from "rain.factory/interface/ICloneableV2.sol";
import {PythOracleAdapter, PythOracleAdapterConfig} from "src/concrete/oracle/PythOracleAdapter.sol";

/// @dev Error raised when a zero address is provided for the implementation.
error ZeroImplementation();

/// @dev Error raised when a zero address is provided for the initial beacon
/// owner.
error ZeroBeaconOwner();

/// @dev Error raised when initialization of the oracle adapter fails.
error InitializeOracleFailed();

/// @title PythOracleAdapterBeaconSetDeployerConfig
/// @notice Configuration for the PythOracleAdapterBeaconSetDeployer
/// construction.
/// @param initialOwner The initial owner of the beacon.
/// @param initialPythOracleAdapterImplementation The initial implementation.
struct PythOracleAdapterBeaconSetDeployerConfig {
    address initialOwner;
    address initialPythOracleAdapterImplementation;
}

/// @title PythOracleAdapterBeaconSetDeployer
/// @notice Deploys and manages a beacon set for PythOracleAdapter contracts.
/// Follows the st0x.deploy BeaconSetDeployer pattern.
contract PythOracleAdapterBeaconSetDeployer {
    /// Emitted when a new PythOracleAdapter is deployed.
    event Deployment(address sender, address pythOracleAdapter);

    /// The beacon for the PythOracleAdapter implementation contracts.
    IBeacon public immutable I_PYTH_ORACLE_ADAPTER_BEACON;

    constructor(PythOracleAdapterBeaconSetDeployerConfig memory config) {
        if (config.initialPythOracleAdapterImplementation == address(0)) {
            revert ZeroImplementation();
        }
        if (config.initialOwner == address(0)) {
            revert ZeroBeaconOwner();
        }

        I_PYTH_ORACLE_ADAPTER_BEACON =
            new UpgradeableBeacon(config.initialPythOracleAdapterImplementation, config.initialOwner);
    }

    /// @notice Deploys and initializes a new PythOracleAdapter proxy.
    /// @param config The initialization configuration.
    /// @return adapter The deployed PythOracleAdapter proxy.
    // slither-disable-next-line reentrancy-events
    function newPythOracleAdapter(PythOracleAdapterConfig memory config) external returns (PythOracleAdapter) {
        PythOracleAdapter adapter =
            PythOracleAdapter(address(new BeaconProxy(address(I_PYTH_ORACLE_ADAPTER_BEACON), "")));

        if (adapter.initialize(abi.encode(config)) != ICLONEABLE_V2_SUCCESS) {
            revert InitializeOracleFailed();
        }

        emit Deployment(msg.sender, address(adapter));

        return adapter;
    }
}
