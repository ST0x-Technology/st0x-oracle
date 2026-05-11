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
import {CorporateActionPauseConfig} from "src/abstract/BasePythOracleAdapter.sol";

/// @title MultiOracleUnifiedDeployerTest
/// @notice Mirrors `OracleUnifiedDeployerTest` — etches the three sub-deployers
/// at their `LibProdDeploy` constants and mocks each `new*Adapter` call to
/// return a chosen address, then asserts the `Deployment` event payload.
/// Closes audit #54 (the prior implementation was a `try/catch {}` no-op).
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

    function _emptyPauseConfig() internal pure returns (CorporateActionPauseConfig memory) {
        return CorporateActionPauseConfig({
            corporateActionsVault: address(0), actionTypeMask: 0, pauseTimeBefore: 0, pauseTimeAfter: 0
        });
    }

    function _createRegistry(address admin) internal returns (OracleRegistry) {
        vm.prank(admin);
        return I_REGISTRY_DEPLOYER.newOracleRegistry();
    }

    /// Happy path: with all three sub-deployers etched and mocked, the unified
    /// deployer must call through to each in order and emit `Deployment` with
    /// the resolved adapter addresses.
    function testNewMultiOracleAndProtocolAdaptersEmitsAndChains(
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

        MultiOracleUnifiedDeployer unified = new MultiOracleUnifiedDeployer();
        OracleRegistry registry = _createRegistry(registryAdmin);

        FeedConfig[] memory feeds = new FeedConfig[](1);
        feeds[0] = FeedConfig({priceId: priceId, maxAge: maxAge});

        // Etch + mock the three sub-deployers at their LibProdDeploy
        // addresses. The new*Adapter calls inside the unified deployer route
        // here, so mocks decide the returned adapter addresses.
        vm.etch(
            LibProdDeploy.MULTI_PYTH_ORACLE_ADAPTER_BEACON_SET_DEPLOYER,
            vm.getCode("MultiPythOracleAdapterBeaconSetDeployer")
        );
        vm.mockCall(
            LibProdDeploy.MULTI_PYTH_ORACLE_ADAPTER_BEACON_SET_DEPLOYER,
            abi.encodeWithSelector(MultiPythOracleAdapterBeaconSetDeployer.newMultiPythOracleAdapter.selector),
            abi.encode(oracleAdapter)
        );
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
        emit MultiOracleUnifiedDeployer.Deployment(address(this), oracleAdapter, morphoAdapter, passthroughAdapter);
        unified.newMultiOracleAndProtocolAdapters(vault, feeds, registry, _emptyPauseConfig());
    }
}
