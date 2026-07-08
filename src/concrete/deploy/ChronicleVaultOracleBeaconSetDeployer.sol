// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {IBeacon} from "@openzeppelin-contracts-5.6.1/proxy/beacon/IBeacon.sol";
import {UpgradeableBeacon} from "@openzeppelin-contracts-5.6.1/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin-contracts-5.6.1/proxy/beacon/BeaconProxy.sol";
import {ICLONEABLE_V2_SUCCESS} from "rain-factory-0.1.1/src/interface/ICloneableV2.sol";
import {ChronicleVaultOracle, ChronicleVaultOracleConfig} from "src/concrete/oracle/ChronicleVaultOracle.sol";

/// @dev Error raised when a zero address is provided for the implementation.
error ZeroImplementation();

/// @dev Error raised when a zero address is provided for the initial beacon
/// owner. Only constrains construction-time ownership; subsequent owner
/// rotations are the beacon's concern.
error ZeroBeaconOwner();

/// @dev Error raised when initialization of the oracle returns the wrong
/// magic value (i.e. not `ICLONEABLE_V2_SUCCESS`). Indicates an
/// implementation regression — should never fire in production.
error InitializeOracleFailed();

/// @title ChronicleVaultOracleBeaconSetDeployerConfig
/// @notice Configuration for the `ChronicleVaultOracleBeaconSetDeployer`
/// constructor.
/// @param initialOwner The initial owner of the beacon (controls upgrades).
/// @param initialChronicleVaultOracleImplementation The initial
/// implementation contract behind the beacon.
struct ChronicleVaultOracleBeaconSetDeployerConfig {
    address initialOwner;
    address initialChronicleVaultOracleImplementation;
}

/// @title ChronicleVaultOracleBeaconSetDeployer
/// @notice Deploys a beacon and the `ChronicleVaultOracle` proxies that
/// share it. Beacon management (upgrades, ownership transfer) is performed
/// externally by the beacon owner; this contract retains no authority over
/// the beacon after construction. Follows the canonical
/// `st0x.deploy`-style BeaconSetDeployer pattern.
contract ChronicleVaultOracleBeaconSetDeployer {
    /// @notice Emitted when a new ChronicleVaultOracle proxy is deployed.
    /// @param caller The direct on-chain caller of `newChronicleVaultOracle`.
    /// For oracles created via `ChronicleOracleUnifiedDeployer` this is the
    /// unified deployer contract, not the originating EOA. Indexed so
    /// monitoring can filter by deployer.
    /// @param oracle The address of the new proxy. Indexed for filtering.
    event Deployment(address indexed caller, address indexed oracle);

    /// The beacon for the ChronicleVaultOracle implementation contracts.
    IBeacon public immutable I_CHRONICLE_VAULT_ORACLE_BEACON;

    constructor(ChronicleVaultOracleBeaconSetDeployerConfig memory config) {
        if (config.initialChronicleVaultOracleImplementation == address(0)) {
            revert ZeroImplementation();
        }
        if (config.initialOwner == address(0)) {
            revert ZeroBeaconOwner();
        }

        I_CHRONICLE_VAULT_ORACLE_BEACON =
            new UpgradeableBeacon(config.initialChronicleVaultOracleImplementation, config.initialOwner);
    }

    /// @notice Deploys and initializes a new ChronicleVaultOracle proxy.
    /// @param config The initialization configuration.
    /// @return oracle The deployed proxy as a typed reference.
    // slither-disable-next-line reentrancy-events
    function newChronicleVaultOracle(ChronicleVaultOracleConfig memory config)
        external
        returns (ChronicleVaultOracle oracle)
    {
        oracle = ChronicleVaultOracle(address(new BeaconProxy(address(I_CHRONICLE_VAULT_ORACLE_BEACON), "")));

        if (oracle.initialize(abi.encode(config)) != ICLONEABLE_V2_SUCCESS) {
            revert InitializeOracleFailed();
        }

        emit Deployment(msg.sender, address(oracle));

        return oracle;
    }
}
