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
/// owner. Only constrains construction-time ownership; subsequent owner
/// rotations are the beacon's concern.
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
/// @notice Deploys a beacon (constructed once at deploy-time) and the
/// proxies that share it for OracleRegistry contracts. Beacon authority
/// — including upgrade and ownership transfer — lives entirely with the
/// `initialOwner` supplied at construction; this contract retains no
/// post-construction authority over the beacon. Follows the st0x.deploy
/// BeaconSetDeployer pattern.
contract OracleRegistryBeaconSetDeployer {
    /// @notice Emitted when a new OracleRegistry is deployed.
    /// @param caller The direct on-chain caller of `newOracleRegistry`. Also
    /// becomes the registry admin per SPEC §13. Indexed so monitoring can
    /// filter by deployer.
    /// @param oracleRegistry The address of the new proxy. Indexed so
    /// monitoring can filter by registry.
    event Deployment(address indexed caller, address indexed oracleRegistry);

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
    /// @dev `msg.sender` becomes the registry admin. SPEC §13 states the
    /// registry admin is the founder multisig, so this function MUST be
    /// called from that multisig (or, after deployment, transfer admin to
    /// the multisig via `OracleRegistry.setAdmin`).
    /// @return registry The deployed OracleRegistry proxy.
    // slither-disable-next-line reentrancy-events
    function newOracleRegistry() external returns (OracleRegistry) {
        OracleRegistry registry = OracleRegistry(address(new BeaconProxy(address(I_ORACLE_REGISTRY_BEACON), "")));

        if (registry.initialize(abi.encode(OracleRegistryConfig({admin: msg.sender}))) != ICLONEABLE_V2_SUCCESS) {
            revert InitializeRegistryFailed();
        }

        emit Deployment(msg.sender, address(registry));

        return registry;
    }
}
