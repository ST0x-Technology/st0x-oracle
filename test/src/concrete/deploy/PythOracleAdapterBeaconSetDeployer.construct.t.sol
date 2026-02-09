// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {
    PythOracleAdapterBeaconSetDeployer,
    PythOracleAdapterBeaconSetDeployerConfig,
    ZeroImplementation,
    ZeroBeaconOwner
} from "src/concrete/deploy/PythOracleAdapterBeaconSetDeployer.sol";
import {PythOracleAdapter} from "src/concrete/oracle/PythOracleAdapter.sol";

contract PythOracleAdapterBeaconSetDeployerConstructTest is Test {
    function testPythOracleAdapterBeaconSetDeployerConstructZeroImplementation(address initialOwner) external {
        vm.assume(initialOwner != address(0));
        vm.expectRevert(abi.encodeWithSelector(ZeroImplementation.selector));
        new PythOracleAdapterBeaconSetDeployer(
            PythOracleAdapterBeaconSetDeployerConfig({
                initialOwner: initialOwner, initialPythOracleAdapterImplementation: address(0)
            })
        );
    }

    function testPythOracleAdapterBeaconSetDeployerConstructZeroBeaconOwner(address initialPythOracleAdapterImplementation)
        external
    {
        vm.assume(initialPythOracleAdapterImplementation != address(0));
        vm.expectRevert(abi.encodeWithSelector(ZeroBeaconOwner.selector));
        new PythOracleAdapterBeaconSetDeployer(
            PythOracleAdapterBeaconSetDeployerConfig({
                initialOwner: address(0), initialPythOracleAdapterImplementation: initialPythOracleAdapterImplementation
            })
        );
    }

    function testPythOracleAdapterBeaconSetDeployerConstructSuccess(address initialOwner) external {
        vm.assume(initialOwner != address(0));
        PythOracleAdapter implementation = new PythOracleAdapter();

        PythOracleAdapterBeaconSetDeployer deployer = new PythOracleAdapterBeaconSetDeployer(
            PythOracleAdapterBeaconSetDeployerConfig({
                initialOwner: initialOwner, initialPythOracleAdapterImplementation: address(implementation)
            })
        );

        assertEq(address(deployer.I_PYTH_ORACLE_ADAPTER_BEACON().implementation()), address(implementation));
    }
}
