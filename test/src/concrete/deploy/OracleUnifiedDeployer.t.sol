// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {CorporateActionPauseConfig} from "st0x.oracle/abstract/BasePythOracleAdapter.sol";
import {OracleUnifiedDeployer} from "st0x.oracle/concrete/deploy/OracleUnifiedDeployer.sol";
import {LibProdDeploy} from "st0x.oracle/lib/LibProdDeploy.sol";
import {PythOracleAdapterBeaconSetDeployer} from "st0x.oracle/concrete/deploy/PythOracleAdapterBeaconSetDeployer.sol";
import {
    PassthroughProtocolAdapterBeaconSetDeployer
} from "st0x.oracle/concrete/deploy/PassthroughProtocolAdapterBeaconSetDeployer.sol";
import {
    MorphoProtocolAdapterBeaconSetDeployer
} from "st0x.oracle/concrete/deploy/MorphoProtocolAdapterBeaconSetDeployer.sol";
import {PythOracleAdapterConfig} from "st0x.oracle/concrete/oracle/PythOracleAdapter.sol";
import {OracleRegistry} from "st0x.oracle/concrete/registry/OracleRegistry.sol";
import {
    OracleRegistryBeaconSetDeployer,
    OracleRegistryBeaconSetDeployerConfig
} from "st0x.oracle/concrete/deploy/OracleRegistryBeaconSetDeployer.sol";

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

    /// @dev Packed fuzz inputs for `testOracleUnifiedDeployerPropagatesNonEmptyPauseConfig`.
    /// Solidity's stack-depth limit forces grouping the 10+ fuzz vars into a
    /// struct so the test body has room for locals + mock setup.
    struct PropagateInputs {
        address vault;
        bytes32 priceId;
        uint256 maxAge;
        address oracleAdapter;
        address morphoAdapter;
        address passthroughAdapter;
        address registryAdmin;
        address corporateActionsVault;
        uint64 pauseBefore;
        uint64 pauseAfter;
    }

    /// `OracleUnifiedDeployer.newOracleAndProtocolAdapters` MUST forward the
    /// `pauseConfig` argument verbatim into the `PythOracleAdapterConfig` it
    /// passes to `PythOracleAdapterBeaconSetDeployer.newPythOracleAdapter`.
    /// The existing happy-path test pins only the `_emptyPauseConfig()` shape;
    /// a regression that dropped or rewrote the caller's pauseConfig (e.g.
    /// substituted an empty one) would pass that test. The `vm.mockCall` /
    /// `vm.expectCall` matchers here are keyed on the *non-empty* pauseConfig
    /// so the deployer call would revert / fail expectations on any deviation.
    /// Closes audit #57.
    function testOracleUnifiedDeployerPropagatesNonEmptyPauseConfig(PropagateInputs memory in_) external {
        vm.assume(in_.oracleAdapter.code.length == 0);
        vm.assume(in_.morphoAdapter.code.length == 0);
        vm.assume(in_.passthroughAdapter.code.length == 0);
        vm.assume(in_.registryAdmin != address(0));
        vm.assume(in_.corporateActionsVault != address(0));

        OracleUnifiedDeployer unifiedDeployer = new OracleUnifiedDeployer();
        OracleRegistry registry = _createRegistry(in_.registryAdmin);

        CorporateActionPauseConfig memory pauseConfig = CorporateActionPauseConfig({
            corporateActionsVault: in_.corporateActionsVault,
            actionTypeMask: type(uint256).max,
            pauseTimeBefore: in_.pauseBefore,
            pauseTimeAfter: in_.pauseAfter
        });

        _armSubDeployerMocksWithPause(in_, registry, pauseConfig);

        // `vm.expectCall` is a positive matcher on the exact calldata — if
        // the unified deployer drops/rewrites the pauseConfig, this fails.
        vm.expectCall(
            LibProdDeploy.PYTH_ORACLE_ADAPTER_BEACON_SET_DEPLOYER,
            abi.encodeWithSelector(
                PythOracleAdapterBeaconSetDeployer.newPythOracleAdapter.selector,
                PythOracleAdapterConfig({
                    vault: in_.vault,
                    priceId: in_.priceId,
                    maxAge: in_.maxAge,
                    admin: address(this),
                    pauseConfig: pauseConfig
                })
            )
        );

        vm.expectEmit();
        emit OracleUnifiedDeployer.Deployment(
            address(this), in_.oracleAdapter, in_.morphoAdapter, in_.passthroughAdapter
        );
        unifiedDeployer.newOracleAndProtocolAdapters(in_.vault, in_.priceId, in_.maxAge, registry, pauseConfig);
    }

    /// @dev Etch + mock every sub-deployer at its prod address. Mocks are
    /// keyed on the *non-empty* pauseConfig so a regression that rewrote it
    /// in transit would surface as an un-decoded outer revert.
    function _armSubDeployerMocksWithPause(
        PropagateInputs memory in_,
        OracleRegistry registry,
        CorporateActionPauseConfig memory pauseConfig
    ) internal {
        vm.etch(LibProdDeploy.PYTH_ORACLE_ADAPTER_BEACON_SET_DEPLOYER, vm.getCode("PythOracleAdapterBeaconSetDeployer"));
        vm.mockCall(
            LibProdDeploy.PYTH_ORACLE_ADAPTER_BEACON_SET_DEPLOYER,
            abi.encodeWithSelector(
                PythOracleAdapterBeaconSetDeployer.newPythOracleAdapter.selector,
                PythOracleAdapterConfig({
                    vault: in_.vault,
                    priceId: in_.priceId,
                    maxAge: in_.maxAge,
                    admin: address(this),
                    pauseConfig: pauseConfig
                })
            ),
            abi.encode(in_.oracleAdapter)
        );

        vm.etch(
            LibProdDeploy.MORPHO_PROTOCOL_ADAPTER_BEACON_SET_DEPLOYER,
            vm.getCode("MorphoProtocolAdapterBeaconSetDeployer")
        );
        vm.mockCall(
            LibProdDeploy.MORPHO_PROTOCOL_ADAPTER_BEACON_SET_DEPLOYER,
            abi.encodeWithSelector(
                MorphoProtocolAdapterBeaconSetDeployer.newMorphoProtocolAdapter.selector,
                registry,
                in_.vault,
                address(this)
            ),
            abi.encode(in_.morphoAdapter)
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
                in_.vault,
                address(this)
            ),
            abi.encode(in_.passthroughAdapter)
        );
    }
}
