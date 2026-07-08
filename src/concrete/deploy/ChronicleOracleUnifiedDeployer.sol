// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {AggregatorV2V3Interface} from "src/interface/IAggregatorV2V3.sol";
import {ChronicleVaultOracle, ChronicleVaultOracleConfig} from "src/concrete/oracle/ChronicleVaultOracle.sol";
import {
    PausableOracleWrapper,
    PausableOracleWrapperConfig,
    CorporateActionPauseConfig
} from "src/concrete/wrapper/PausableOracleWrapper.sol";
import {ChronicleVaultOracleBeaconSetDeployer} from "src/concrete/deploy/ChronicleVaultOracleBeaconSetDeployer.sol";
import {PausableOracleWrapperBeaconSetDeployer} from "src/concrete/deploy/PausableOracleWrapperBeaconSetDeployer.sol";

/// @dev Error raised when a zero address is provided for an upstream beacon
/// set deployer.
error ZeroBeaconSetDeployer();

/// @title ChronicleOracleUnifiedDeployerConstructorConfig
/// @notice Wires the unified deployer to the two beacon-set deployers it
/// composes.
/// @param chronicleVaultOracleBeaconSetDeployer Deployer for the
/// `ChronicleVaultOracle` proxies.
/// @param pausableOracleWrapperBeaconSetDeployer Deployer for the
/// `PausableOracleWrapper` proxies.
struct ChronicleOracleUnifiedDeployerConstructorConfig {
    ChronicleVaultOracleBeaconSetDeployer chronicleVaultOracleBeaconSetDeployer;
    PausableOracleWrapperBeaconSetDeployer pausableOracleWrapperBeaconSetDeployer;
}

/// @title ChronicleOracleUnifiedDeployConfig
/// @notice Per-deployment config bundle: the adapter side + the wrapper side
/// minus the upstream (which is wired by the deployer itself).
/// @param admin The wrapper's admin (governance for manual pause + admin
/// rotation). Cannot be zero.
/// @param oracleConfig The `ChronicleVaultOracle` init config (chronicle
/// feed + vault + maxAge).
/// @param pauseConfig The wrapper's corporate-action auto-pause config.
struct ChronicleOracleUnifiedDeployConfig {
    address admin;
    ChronicleVaultOracleConfig oracleConfig;
    CorporateActionPauseConfig pauseConfig;
}

/// @title ChronicleOracleUnifiedDeployer
/// @notice One-shot factory that deploys a paired
/// `(ChronicleVaultOracle, PausableOracleWrapper)` and wires the wrapper's
/// upstream slot to the freshly-deployed adapter. The wrapper proxy is the
/// canonical address consumers (Euler, lending markets) target — its upstream is
/// immutable, so the adapter address never has to leak past deploy time.
///
/// Atomicity is the whole point: integrators don't want to coordinate a
/// two-step deploy + wire-up, and getting the wiring wrong (e.g. wrapping
/// the wrong adapter address) would mint a broken oracle.
contract ChronicleOracleUnifiedDeployer {
    /// @notice Emitted on every successful unified deployment.
    /// @param caller The on-chain caller of `newOracleWithWrapper`.
    /// @param oracle The new `ChronicleVaultOracle` proxy.
    /// @param wrapper The new `PausableOracleWrapper` proxy (canonical
    /// consumer-facing address).
    event Deployment(address indexed caller, address indexed oracle, address indexed wrapper);

    /// The beacon-set deployer for the underlying ChronicleVaultOracle proxies.
    ChronicleVaultOracleBeaconSetDeployer public immutable I_CHRONICLE_VAULT_ORACLE_BEACON_SET_DEPLOYER;
    /// The beacon-set deployer for the PausableOracleWrapper proxies.
    PausableOracleWrapperBeaconSetDeployer public immutable I_PAUSABLE_ORACLE_WRAPPER_BEACON_SET_DEPLOYER;

    constructor(ChronicleOracleUnifiedDeployerConstructorConfig memory config) {
        if (address(config.chronicleVaultOracleBeaconSetDeployer) == address(0)) {
            revert ZeroBeaconSetDeployer();
        }
        if (address(config.pausableOracleWrapperBeaconSetDeployer) == address(0)) {
            revert ZeroBeaconSetDeployer();
        }
        I_CHRONICLE_VAULT_ORACLE_BEACON_SET_DEPLOYER = config.chronicleVaultOracleBeaconSetDeployer;
        I_PAUSABLE_ORACLE_WRAPPER_BEACON_SET_DEPLOYER = config.pausableOracleWrapperBeaconSetDeployer;
    }

    /// @notice Deploys a ChronicleVaultOracle and a PausableOracleWrapper
    /// wiring the latter's upstream to the former. Both are beacon proxies
    /// off their respective beacons.
    /// @param config The unified deploy config.
    /// @return oracle The deployed ChronicleVaultOracle proxy.
    /// @return wrapper The deployed PausableOracleWrapper proxy.
    // slither-disable-next-line reentrancy-events
    function newOracleWithWrapper(ChronicleOracleUnifiedDeployConfig memory config)
        external
        returns (ChronicleVaultOracle oracle, PausableOracleWrapper wrapper)
    {
        oracle = I_CHRONICLE_VAULT_ORACLE_BEACON_SET_DEPLOYER.newChronicleVaultOracle(config.oracleConfig);

        wrapper = I_PAUSABLE_ORACLE_WRAPPER_BEACON_SET_DEPLOYER.newPausableOracleWrapper(
            PausableOracleWrapperConfig({
                admin: config.admin, upstream: AggregatorV2V3Interface(address(oracle)), pauseConfig: config.pauseConfig
            })
        );

        emit Deployment(msg.sender, address(oracle), address(wrapper));

        return (oracle, wrapper);
    }
}
