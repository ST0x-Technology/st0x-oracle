// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {IBeacon} from "openzeppelin-contracts/contracts/proxy/beacon/IBeacon.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "openzeppelin-contracts/contracts/proxy/beacon/BeaconProxy.sol";
import {ICLONEABLE_V2_SUCCESS} from "rain.factory/interface/ICloneableV2.sol";
import {OracleRegistry, OracleRegistryConfig} from "src/concrete/registry/OracleRegistry.sol";

/// @dev Error raised when a zero address is provided for the implementation.
error ZeroImplementation();

/// @dev Error raised when a zero address is provided for the initial beacon
/// owner.
error ZeroBeaconOwner();

/// @dev Error raised when initialization of the oracle registry fails.
error InitializeRegistryFailed();

/// @title OracleRegistryBeaconSetDeployerConfig
/// @notice Configuration for the OracleRegistryBeaconSetDeployer construction.
/// @param initialOwner The initial owner of the beacon.
/// @param initialOracleRegistryImplementation The initial implementation.
struct OracleRegistryBeaconSetDeployerConfig {
    address initialOwner;
    address initialOracleRegistryImplementation;
}

/// @title OracleRegistryBeaconSetDeployer
/// @notice Deploys and manages a beacon set for OracleRegistry contracts.
/// Follows the st0x.deploy BeaconSetDeployer pattern.
contract OracleRegistryBeaconSetDeployer {
    /// Emitted when a new OracleRegistry is deployed.
    event Deployment(address sender, address oracleRegistry);

    /// The beacon for the OracleRegistry implementation contracts.
    IBeacon public immutable I_ORACLE_REGISTRY_BEACON;

    constructor(OracleRegistryBeaconSetDeployerConfig memory config) {
        if (config.initialOracleRegistryImplementation == address(0)) {
            revert ZeroImplementation();
        }
        if (config.initialOwner == address(0)) {
            revert ZeroBeaconOwner();
        }

        I_ORACLE_REGISTRY_BEACON =
            new UpgradeableBeacon(config.initialOracleRegistryImplementation, config.initialOwner);
    }

    /// @notice Deploys and initializes a new OracleRegistry proxy.
    /// @param config The initialization configuration.
    /// @return registry The deployed OracleRegistry proxy.
    // slither-disable-next-line reentrancy-events
    function newOracleRegistry(OracleRegistryConfig memory config) external returns (OracleRegistry) {
        OracleRegistry registry = OracleRegistry(address(new BeaconProxy(address(I_ORACLE_REGISTRY_BEACON), "")));

        if (registry.initialize(abi.encode(config)) != ICLONEABLE_V2_SUCCESS) {
            revert InitializeRegistryFailed();
        }

        emit Deployment(msg.sender, address(registry));

        return registry;
    }
}
