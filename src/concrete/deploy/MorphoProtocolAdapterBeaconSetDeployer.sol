// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {IBeacon} from "openzeppelin-contracts/contracts/proxy/beacon/IBeacon.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "openzeppelin-contracts/contracts/proxy/beacon/BeaconProxy.sol";
import {ICLONEABLE_V2_SUCCESS} from "rain.factory/interface/ICloneableV2.sol";
import {MorphoProtocolAdapter, MorphoProtocolAdapterConfig} from "src/concrete/protocol/MorphoProtocolAdapter.sol";
import {OracleRegistry} from "src/concrete/registry/OracleRegistry.sol";

/// @dev Error raised when a zero address is provided for the implementation.
error ZeroImplementation();

/// @dev Error raised when a zero address is provided for the initial beacon
/// owner.
error ZeroBeaconOwner();

/// @dev Error raised when initialization of the protocol adapter fails.
error InitializeAdapterFailed();

/// @title MorphoProtocolAdapterBeaconSetDeployerConfig
/// @notice Configuration for the MorphoProtocolAdapterBeaconSetDeployer
/// construction.
/// @param initialOwner The initial owner of the beacon.
/// @param initialMorphoProtocolAdapterImplementation The initial implementation.
struct MorphoProtocolAdapterBeaconSetDeployerConfig {
    address initialOwner;
    address initialMorphoProtocolAdapterImplementation;
}

/// @title MorphoProtocolAdapterBeaconSetDeployer
/// @notice Deploys and manages a beacon set for MorphoProtocolAdapter
/// contracts. Used for Morpho Blue protocol integration.
contract MorphoProtocolAdapterBeaconSetDeployer {
    /// Emitted when a new MorphoProtocolAdapter is deployed.
    event Deployment(address sender, address morphoProtocolAdapter);

    /// The beacon for the MorphoProtocolAdapter implementation contracts.
    IBeacon public immutable I_MORPHO_PROTOCOL_ADAPTER_BEACON;

    constructor(MorphoProtocolAdapterBeaconSetDeployerConfig memory config) {
        if (config.initialMorphoProtocolAdapterImplementation == address(0)) {
            revert ZeroImplementation();
        }
        if (config.initialOwner == address(0)) {
            revert ZeroBeaconOwner();
        }

        I_MORPHO_PROTOCOL_ADAPTER_BEACON =
            new UpgradeableBeacon(config.initialMorphoProtocolAdapterImplementation, config.initialOwner);
    }

    /// @notice Deploys and initializes a new MorphoProtocolAdapter proxy.
    /// @param registry The oracle registry address.
    /// @param vault The vault address this adapter serves.
    /// @param admin The admin address.
    /// @return adapter The deployed MorphoProtocolAdapter proxy.
    // slither-disable-next-line reentrancy-events
    function newMorphoProtocolAdapter(OracleRegistry registry, address vault, address admin)
        external
        returns (MorphoProtocolAdapter)
    {
        MorphoProtocolAdapter adapter =
            MorphoProtocolAdapter(address(new BeaconProxy(address(I_MORPHO_PROTOCOL_ADAPTER_BEACON), "")));

        if (
            adapter.initialize(
                    abi.encode(MorphoProtocolAdapterConfig({registry: registry, vault: vault, admin: admin}))
                ) != ICLONEABLE_V2_SUCCESS
        ) {
            revert InitializeAdapterFailed();
        }

        emit Deployment(msg.sender, address(adapter));

        return adapter;
    }
}
