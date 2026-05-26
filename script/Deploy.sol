// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Script} from "forge-std-1.16.1/src/Script.sol";

import {LibProdDeploy} from "src/lib/LibProdDeploy.sol";
import {PythOracleAdapter} from "src/concrete/oracle/PythOracleAdapter.sol";
import {
    PythOracleAdapterBeaconSetDeployer,
    PythOracleAdapterBeaconSetDeployerConfig
} from "src/concrete/deploy/PythOracleAdapterBeaconSetDeployer.sol";
import {PassthroughProtocolAdapter} from "src/concrete/protocol/PassthroughProtocolAdapter.sol";
import {
    PassthroughProtocolAdapterBeaconSetDeployer,
    PassthroughProtocolAdapterBeaconSetDeployerConfig
} from "src/concrete/deploy/PassthroughProtocolAdapterBeaconSetDeployer.sol";
import {MorphoProtocolAdapter} from "src/concrete/protocol/MorphoProtocolAdapter.sol";
import {
    MorphoProtocolAdapterBeaconSetDeployer,
    MorphoProtocolAdapterBeaconSetDeployerConfig
} from "src/concrete/deploy/MorphoProtocolAdapterBeaconSetDeployer.sol";
import {OracleUnifiedDeployer} from "src/concrete/deploy/OracleUnifiedDeployer.sol";
import {OracleRegistry} from "src/concrete/registry/OracleRegistry.sol";
import {
    OracleRegistryBeaconSetDeployer,
    OracleRegistryBeaconSetDeployerConfig
} from "src/concrete/deploy/OracleRegistryBeaconSetDeployer.sol";
import {MultiPythOracleAdapter} from "src/concrete/oracle/MultiPythOracleAdapter.sol";
import {
    MultiPythOracleAdapterBeaconSetDeployer,
    MultiPythOracleAdapterBeaconSetDeployerConfig
} from "src/concrete/deploy/MultiPythOracleAdapterBeaconSetDeployer.sol";
import {MultiOracleUnifiedDeployer} from "src/concrete/deploy/MultiOracleUnifiedDeployer.sol";

/// @dev The deployment suite name for the pyth oracle adapter beacon set.
bytes32 constant DEPLOYMENT_SUITE_PYTH_ORACLE_ADAPTER_BEACON_SET = keccak256("pyth-oracle-adapter-beacon-set");

/// @dev The deployment suite name for the morpho protocol adapter beacon set.
bytes32 constant DEPLOYMENT_SUITE_MORPHO_PROTOCOL_ADAPTER_BEACON_SET = keccak256("morpho-protocol-adapter-beacon-set");

/// @dev The deployment suite name for the passthrough protocol adapter beacon
/// set.
bytes32 constant DEPLOYMENT_SUITE_PASSTHROUGH_PROTOCOL_ADAPTER_BEACON_SET =
    keccak256("passthrough-protocol-adapter-beacon-set");

/// @dev The deployment suite name for the oracle unified deployer.
bytes32 constant DEPLOYMENT_SUITE_ORACLE_UNIFIED_DEPLOYER = keccak256("oracle-unified-deployer");

/// @dev The deployment suite name for the oracle registry beacon set.
bytes32 constant DEPLOYMENT_SUITE_ORACLE_REGISTRY_BEACON_SET = keccak256("oracle-registry-beacon-set");

/// @dev The deployment suite name for the multi pyth oracle adapter beacon set.
bytes32 constant DEPLOYMENT_SUITE_MULTI_PYTH_ORACLE_ADAPTER_BEACON_SET =
    keccak256("multi-pyth-oracle-adapter-beacon-set");

/// @dev The deployment suite name for the multi oracle unified deployer.
bytes32 constant DEPLOYMENT_SUITE_MULTI_ORACLE_UNIFIED_DEPLOYER = keccak256("multi-oracle-unified-deployer");

contract Deploy is Script {
    /// @notice Deploys the PythOracleAdapterBeaconSetDeployer contract.
    /// Creates a PythOracleAdapter anew for the initial implementation.
    /// Initial owner is set to the BEACON_INITIAL_OWNER constant in
    /// LibProdDeploy.
    function deployPythOracleAdapterBeaconSet(uint256 deploymentKey) internal {
        vm.startBroadcast(deploymentKey);

        new PythOracleAdapterBeaconSetDeployer(
            PythOracleAdapterBeaconSetDeployerConfig({
                initialOwner: LibProdDeploy.BEACON_INITIAL_OWNER,
                initialPythOracleAdapterImplementation: address(new PythOracleAdapter())
            })
        );

        vm.stopBroadcast();
    }

    /// @notice Deploys the MorphoProtocolAdapterBeaconSetDeployer contract.
    /// Creates a MorphoProtocolAdapter anew for the initial implementation.
    /// Initial owner is set to the BEACON_INITIAL_OWNER constant in
    /// LibProdDeploy.
    function deployMorphoProtocolAdapterBeaconSet(uint256 deploymentKey) internal {
        vm.startBroadcast(deploymentKey);

        new MorphoProtocolAdapterBeaconSetDeployer(
            MorphoProtocolAdapterBeaconSetDeployerConfig({
                initialOwner: LibProdDeploy.BEACON_INITIAL_OWNER,
                initialMorphoProtocolAdapterImplementation: address(new MorphoProtocolAdapter())
            })
        );

        vm.stopBroadcast();
    }

    /// @notice Deploys the PassthroughProtocolAdapterBeaconSetDeployer
    /// contract. Creates a PassthroughProtocolAdapter anew for the initial
    /// implementation. Initial owner is set to the BEACON_INITIAL_OWNER
    /// constant in LibProdDeploy.
    function deployPassthroughProtocolAdapterBeaconSet(uint256 deploymentKey) internal {
        vm.startBroadcast(deploymentKey);

        new PassthroughProtocolAdapterBeaconSetDeployer(
            PassthroughProtocolAdapterBeaconSetDeployerConfig({
                initialOwner: LibProdDeploy.BEACON_INITIAL_OWNER,
                initialPassthroughProtocolAdapterImplementation: address(new PassthroughProtocolAdapter())
            })
        );

        vm.stopBroadcast();
    }

    /// @notice Deploys the OracleUnifiedDeployer contract.
    function deployOracleUnifiedDeployer(uint256 deploymentKey) internal {
        vm.startBroadcast(deploymentKey);

        new OracleUnifiedDeployer();

        vm.stopBroadcast();
    }

    /// @notice Deploys the OracleRegistryBeaconSetDeployer contract.
    /// Creates an OracleRegistry anew for the initial implementation.
    /// Initial owner is set to the BEACON_INITIAL_OWNER constant in
    /// LibProdDeploy.
    function deployOracleRegistryBeaconSet(uint256 deploymentKey) internal {
        vm.startBroadcast(deploymentKey);

        new OracleRegistryBeaconSetDeployer(
            OracleRegistryBeaconSetDeployerConfig({
                initialOwner: LibProdDeploy.BEACON_INITIAL_OWNER,
                initialOracleRegistryImplementation: address(new OracleRegistry())
            })
        );

        vm.stopBroadcast();
    }

    /// @notice Deploys the MultiPythOracleAdapterBeaconSetDeployer contract.
    /// Creates a MultiPythOracleAdapter anew for the initial implementation.
    /// Initial owner is set to the BEACON_INITIAL_OWNER constant in
    /// LibProdDeploy.
    function deployMultiPythOracleAdapterBeaconSet(uint256 deploymentKey) internal {
        vm.startBroadcast(deploymentKey);

        new MultiPythOracleAdapterBeaconSetDeployer(
            MultiPythOracleAdapterBeaconSetDeployerConfig({
                initialOwner: LibProdDeploy.BEACON_INITIAL_OWNER,
                initialMultiPythOracleAdapterImplementation: address(new MultiPythOracleAdapter())
            })
        );

        vm.stopBroadcast();
    }

    /// @notice Deploys the MultiOracleUnifiedDeployer contract.
    function deployMultiOracleUnifiedDeployer(uint256 deploymentKey) internal {
        vm.startBroadcast(deploymentKey);

        new MultiOracleUnifiedDeployer();

        vm.stopBroadcast();
    }

    /// @notice Entry point for the deployment script. Dispatches to the
    /// appropriate deployment function based on the DEPLOYMENT_SUITE environment
    /// variable.
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYMENT_KEY");
        bytes32 suite = keccak256(bytes(vm.envString("DEPLOYMENT_SUITE")));

        if (suite == DEPLOYMENT_SUITE_PYTH_ORACLE_ADAPTER_BEACON_SET) {
            deployPythOracleAdapterBeaconSet(deployerPrivateKey);
        } else if (suite == DEPLOYMENT_SUITE_MORPHO_PROTOCOL_ADAPTER_BEACON_SET) {
            deployMorphoProtocolAdapterBeaconSet(deployerPrivateKey);
        } else if (suite == DEPLOYMENT_SUITE_PASSTHROUGH_PROTOCOL_ADAPTER_BEACON_SET) {
            deployPassthroughProtocolAdapterBeaconSet(deployerPrivateKey);
        } else if (suite == DEPLOYMENT_SUITE_ORACLE_UNIFIED_DEPLOYER) {
            deployOracleUnifiedDeployer(deployerPrivateKey);
        } else if (suite == DEPLOYMENT_SUITE_ORACLE_REGISTRY_BEACON_SET) {
            deployOracleRegistryBeaconSet(deployerPrivateKey);
        } else if (suite == DEPLOYMENT_SUITE_MULTI_PYTH_ORACLE_ADAPTER_BEACON_SET) {
            deployMultiPythOracleAdapterBeaconSet(deployerPrivateKey);
        } else if (suite == DEPLOYMENT_SUITE_MULTI_ORACLE_UNIFIED_DEPLOYER) {
            deployMultiOracleUnifiedDeployer(deployerPrivateKey);
        } else {
            revert("Unknown deployment suite");
        }
    }
}
