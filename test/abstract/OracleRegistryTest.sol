// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test, Vm} from "forge-std/Test.sol";
import {OracleRegistry, OracleRegistryConfig} from "src/concrete/registry/OracleRegistry.sol";
import {
    OracleRegistryBeaconSetDeployer,
    OracleRegistryBeaconSetDeployerConfig
} from "src/concrete/deploy/OracleRegistryBeaconSetDeployer.sol";

contract OracleRegistryTest is Test {
    OracleRegistry internal immutable I_IMPLEMENTATION;
    OracleRegistryBeaconSetDeployer internal immutable I_DEPLOYER;

    constructor() {
        I_IMPLEMENTATION = new OracleRegistry();
        I_DEPLOYER = new OracleRegistryBeaconSetDeployer(
            OracleRegistryBeaconSetDeployerConfig({
                initialOwner: address(this),
                initialOracleRegistryImplementation: address(I_IMPLEMENTATION)
            })
        );
    }

    function createRegistry(address admin) internal returns (OracleRegistry) {
        return I_DEPLOYER.newOracleRegistry(OracleRegistryConfig({admin: admin}));
    }
}
