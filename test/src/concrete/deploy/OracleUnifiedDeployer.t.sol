// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.1/src/Test.sol";
import {CorporateActionPauseConfig} from "src/abstract/BasePythOracleAdapter.sol";
import {OracleUnifiedDeployer} from "src/concrete/deploy/OracleUnifiedDeployer.sol";
import {LibProdDeploy} from "src/lib/LibProdDeploy.sol";
import {PythOracleAdapterBeaconSetDeployer} from "src/concrete/deploy/PythOracleAdapterBeaconSetDeployer.sol";
import {
    PassthroughProtocolAdapterBeaconSetDeployer
} from "src/concrete/deploy/PassthroughProtocolAdapterBeaconSetDeployer.sol";
import {MorphoProtocolAdapterBeaconSetDeployer} from "src/concrete/deploy/MorphoProtocolAdapterBeaconSetDeployer.sol";
import {PythOracleAdapterConfig} from "src/concrete/oracle/PythOracleAdapter.sol";
import {OracleRegistry} from "src/concrete/registry/OracleRegistry.sol";
import {
    OracleRegistryBeaconSetDeployer,
    OracleRegistryBeaconSetDeployerConfig
} from "src/concrete/deploy/OracleRegistryBeaconSetDeployer.sol";

contract OracleUnifiedDeployerTest is Test {
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

    function _emptyPauseConfig() internal pure returns (CorporateActionPauseConfig memory) {
        return CorporateActionPauseConfig({
            corporateActionsVault: address(0), actionTypeMask: 0, pauseTimeBefore: 0, pauseTimeAfter: 0
        });
    }

    function _createRegistry(address admin) internal returns (OracleRegistry) {
        vm.prank(admin);
        return I_REGISTRY_DEPLOYER.newOracleRegistry();
    }

    function testOracleUnifiedDeployer(
        address vault,
        bytes32 priceId,
        uint256 maxAge,
        address oracleAdapter,
        address morphoAdapter,
        address passthroughAdapter,
        address registryAdmin
    ) external {
        vm.assume(oracleAdapter.code.length == 0);
        vm.assume(morphoAdapter.code.length == 0);
        vm.assume(passthroughAdapter.code.length == 0);
        vm.assume(registryAdmin != address(0));

        OracleUnifiedDeployer unifiedDeployer = new OracleUnifiedDeployer();
        OracleRegistry registry = _createRegistry(registryAdmin);

        // Mock the PythOracleAdapterBeaconSetDeployer at the prod address.
        vm.etch(LibProdDeploy.PYTH_ORACLE_ADAPTER_BEACON_SET_DEPLOYER, vm.getCode("PythOracleAdapterBeaconSetDeployer"));
        vm.mockCall(
            LibProdDeploy.PYTH_ORACLE_ADAPTER_BEACON_SET_DEPLOYER,
            abi.encodeWithSelector(
                PythOracleAdapterBeaconSetDeployer.newPythOracleAdapter.selector,
                PythOracleAdapterConfig({
                    vault: vault,
                    priceId: priceId,
                    maxAge: maxAge,
                    admin: address(this),
                    pauseConfig: _emptyPauseConfig()
                })
            ),
            abi.encode(oracleAdapter)
        );

        // Mock the MorphoProtocolAdapterBeaconSetDeployer at the prod address.
        vm.etch(
            LibProdDeploy.MORPHO_PROTOCOL_ADAPTER_BEACON_SET_DEPLOYER,
            vm.getCode("MorphoProtocolAdapterBeaconSetDeployer")
        );
        vm.mockCall(
            LibProdDeploy.MORPHO_PROTOCOL_ADAPTER_BEACON_SET_DEPLOYER,
            abi.encodeWithSelector(
                MorphoProtocolAdapterBeaconSetDeployer.newMorphoProtocolAdapter.selector, registry, vault, address(this)
            ),
            abi.encode(morphoAdapter)
        );

        // Mock the PassthroughProtocolAdapterBeaconSetDeployer at the prod address.
        vm.etch(
            LibProdDeploy.PASSTHROUGH_PROTOCOL_ADAPTER_BEACON_SET_DEPLOYER,
            vm.getCode("PassthroughProtocolAdapterBeaconSetDeployer")
        );
        vm.mockCall(
            LibProdDeploy.PASSTHROUGH_PROTOCOL_ADAPTER_BEACON_SET_DEPLOYER,
            abi.encodeWithSelector(
                PassthroughProtocolAdapterBeaconSetDeployer.newPassthroughProtocolAdapter.selector,
                registry,
                vault,
                address(this)
            ),
            abi.encode(passthroughAdapter)
        );

        vm.expectEmit();
        emit OracleUnifiedDeployer.Deployment(address(this), oracleAdapter, morphoAdapter, passthroughAdapter);
        unifiedDeployer.newOracleAndProtocolAdapters(vault, priceId, maxAge, registry, _emptyPauseConfig());
    }
}
