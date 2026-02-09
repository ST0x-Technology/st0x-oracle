// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {
    MorphoProtocolAdapterBeaconSetDeployer,
    MorphoProtocolAdapterBeaconSetDeployerConfig,
    ZeroImplementation,
    ZeroBeaconOwner
} from "src/concrete/deploy/MorphoProtocolAdapterBeaconSetDeployer.sol";
import {MorphoProtocolAdapter} from "src/concrete/protocol/MorphoProtocolAdapter.sol";

contract MorphoProtocolAdapterBeaconSetDeployerConstructTest is Test {
    function testMorphoProtocolAdapterBeaconSetDeployerConstructZeroImplementation(address initialOwner) external {
        vm.assume(initialOwner != address(0));
        vm.expectRevert(abi.encodeWithSelector(ZeroImplementation.selector));
        new MorphoProtocolAdapterBeaconSetDeployer(
            MorphoProtocolAdapterBeaconSetDeployerConfig({
                initialOwner: initialOwner,
                initialMorphoProtocolAdapterImplementation: address(0)
            })
        );
    }

    function testMorphoProtocolAdapterBeaconSetDeployerConstructZeroBeaconOwner(
        address initialMorphoProtocolAdapterImplementation
    ) external {
        vm.assume(initialMorphoProtocolAdapterImplementation != address(0));
        vm.expectRevert(abi.encodeWithSelector(ZeroBeaconOwner.selector));
        new MorphoProtocolAdapterBeaconSetDeployer(
            MorphoProtocolAdapterBeaconSetDeployerConfig({
                initialOwner: address(0),
                initialMorphoProtocolAdapterImplementation: initialMorphoProtocolAdapterImplementation
            })
        );
    }

    function testMorphoProtocolAdapterBeaconSetDeployerConstructSuccess(address initialOwner) external {
        vm.assume(initialOwner != address(0));
        MorphoProtocolAdapter implementation = new MorphoProtocolAdapter();

        MorphoProtocolAdapterBeaconSetDeployer deployer = new MorphoProtocolAdapterBeaconSetDeployer(
            MorphoProtocolAdapterBeaconSetDeployerConfig({
                initialOwner: initialOwner,
                initialMorphoProtocolAdapterImplementation: address(implementation)
            })
        );

        assertEq(address(deployer.I_MORPHO_PROTOCOL_ADAPTER_BEACON().implementation()), address(implementation));
    }
}
