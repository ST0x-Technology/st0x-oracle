// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {
    MultiOracleUnifiedDeployer,
    MultiPythBeaconSetDeployerNotSet
} from "src/concrete/deploy/MultiOracleUnifiedDeployer.sol";
import {LibProdDeploy} from "src/lib/LibProdDeploy.sol";
import {MultiPythOracleAdapterBeaconSetDeployer} from "src/concrete/deploy/MultiPythOracleAdapterBeaconSetDeployer.sol";
import {
    PassthroughProtocolAdapterBeaconSetDeployer
} from "src/concrete/deploy/PassthroughProtocolAdapterBeaconSetDeployer.sol";
import {MorphoProtocolAdapterBeaconSetDeployer} from "src/concrete/deploy/MorphoProtocolAdapterBeaconSetDeployer.sol";
import {FeedConfig} from "src/concrete/oracle/MultiPythOracleAdapter.sol";
import {OracleRegistry} from "src/concrete/registry/OracleRegistry.sol";
import {
    OracleRegistryBeaconSetDeployer,
    OracleRegistryBeaconSetDeployerConfig
} from "src/concrete/deploy/OracleRegistryBeaconSetDeployer.sol";

contract MultiOracleUnifiedDeployerTest is Test {
    OracleRegistry internal immutable I_REGISTRY_IMPLEMENTATION;
    OracleRegistryBeaconSetDeployer internal immutable I_REGISTRY_DEPLOYER;

    constructor() {
        I_REGISTRY_IMPLEMENTATION = new OracleRegistry();
        I_REGISTRY_DEPLOYER = new OracleRegistryBeaconSetDeployer(
            OracleRegistryBeaconSetDeployerConfig({
                initialOwner: address(this), initialOracleRegistryImplementation: address(I_REGISTRY_IMPLEMENTATION)
            })
        );
    }

    function _createRegistry(address admin) internal returns (OracleRegistry) {
        vm.prank(admin);
        return I_REGISTRY_DEPLOYER.newOracleRegistry();
    }

    /// Test that the deployer reverts when MULTI_PYTH beacon set deployer is
    /// address(0) (not yet deployed to prod).
    function testRevertsWhenBeaconSetDeployerNotSet() external {
        MultiOracleUnifiedDeployer deployer = new MultiOracleUnifiedDeployer();
        OracleRegistry registry = _createRegistry(address(this));

        FeedConfig[] memory feeds = new FeedConfig[](1);
        feeds[0] = FeedConfig({priceId: bytes32(uint256(1)), maxAge: 300});

        vm.expectRevert(abi.encodeWithSelector(MultiPythBeaconSetDeployerNotSet.selector));
        deployer.newMultiOracleAndProtocolAdapters(address(1), feeds, registry);
    }
}
