// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {IBeacon} from "openzeppelin-contracts/contracts/proxy/beacon/IBeacon.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "openzeppelin-contracts/contracts/proxy/beacon/BeaconProxy.sol";
import {ICLONEABLE_V2_SUCCESS} from "rain.factory/interface/ICloneableV2.sol";
import {
    PassthroughProtocolAdapter,
    PassthroughProtocolAdapterConfig
} from "st0x.oracle/concrete/protocol/PassthroughProtocolAdapter.sol";
import {OracleRegistry} from "st0x.oracle/concrete/registry/OracleRegistry.sol";

/// @dev Error raised when a zero address is provided for the implementation.
error ZeroImplementation();

/// @dev Error raised when a zero address is provided for the initial beacon
/// owner. Only constrains construction-time ownership; subsequent owner
/// rotations are the beacon's concern.
error ZeroBeaconOwner();

/// @dev Error raised when initialization of the protocol adapter fails.
error InitializeAdapterFailed();

/// @title PassthroughProtocolAdapterBeaconSetDeployerConfig
/// @notice Configuration for the PassthroughProtocolAdapterBeaconSetDeployer
/// construction.
/// @param initialOwner The initial owner of the beacon.
/// @param initialPassthroughProtocolAdapterImplementation The initial
/// implementation.
struct PassthroughProtocolAdapterBeaconSetDeployerConfig {
    address initialOwner;
    address initialPassthroughProtocolAdapterImplementation;
}

/// @title PassthroughProtocolAdapterBeaconSetDeployer
/// @notice Deploys a beacon and the proxies that share it for
/// PassthroughProtocolAdapter contracts. Beacon management (upgrades,
/// ownership transfer) is performed externally by the beacon owner; this
/// contract retains no authority over the beacon after construction. Used
/// for Aave V3, Compound V3, and any future Chainlink-compatible protocol.
contract PassthroughProtocolAdapterBeaconSetDeployer {
    /// @notice Emitted when a new PassthroughProtocolAdapter is deployed.
    /// @param caller The direct on-chain caller of
    /// `newPassthroughProtocolAdapter`. For adapters created via
    /// `OracleUnifiedDeployer` / `MultiOracleUnifiedDeployer` this is the
    /// unified-deployer contract, not the originating EOA. Indexed so
    /// monitoring can filter by deployer.
    /// @param passthroughProtocolAdapter The address of the new proxy. Indexed
    /// so monitoring can filter by adapter.
    event Deployment(address indexed caller, address indexed passthroughProtocolAdapter);

    /// The beacon for the PassthroughProtocolAdapter implementation contracts.
    IBeacon public immutable I_PASSTHROUGH_PROTOCOL_ADAPTER_BEACON;

    constructor(PassthroughProtocolAdapterBeaconSetDeployerConfig memory config) {
        if (config.initialPassthroughProtocolAdapterImplementation == address(0)) {
            revert ZeroImplementation();
        }
        if (config.initialOwner == address(0)) {
            revert ZeroBeaconOwner();
        }

        I_PASSTHROUGH_PROTOCOL_ADAPTER_BEACON =
            new UpgradeableBeacon(config.initialPassthroughProtocolAdapterImplementation, config.initialOwner);
    }

    /// @notice Deploys and initializes a new PassthroughProtocolAdapter proxy.
    /// @param registry The oracle registry address.
    /// @param vault The vault address this adapter serves.
    /// @param admin Sole governance principal of the deployed adapter:
    /// can call `setRegistry(newRegistry)` to swap the registry pointer
    /// and `setAdmin(newAdmin)` to rotate this role. Distinct from the
    /// `OracleRegistry` admin, which is not affected by this argument.
    /// One-step transfer model — pass an address that cannot be
    /// misaddressed (typically a multisig).
    /// @return adapter The deployed PassthroughProtocolAdapter proxy.
    // slither-disable-next-line reentrancy-events
    function newPassthroughProtocolAdapter(OracleRegistry registry, address vault, address admin)
        external
        returns (PassthroughProtocolAdapter)
    {
        PassthroughProtocolAdapter adapter = PassthroughProtocolAdapter(
            address(new BeaconProxy(address(I_PASSTHROUGH_PROTOCOL_ADAPTER_BEACON), ""))
        );

        if (
            adapter.initialize(
                    abi.encode(PassthroughProtocolAdapterConfig({registry: registry, vault: vault, admin: admin}))
                ) != ICLONEABLE_V2_SUCCESS
        ) {
            revert InitializeAdapterFailed();
        }

        emit Deployment(msg.sender, address(adapter));

        return adapter;
    }
}
