// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test, Vm} from "forge-std/Test.sol";
import {
    MultiPythOracleAdapterBeaconSetDeployer,
    MultiPythOracleAdapterBeaconSetDeployerConfig,
    MultiZeroImplementation,
    MultiZeroBeaconOwner,
    InitializeMultiOracleFailed
} from "src/concrete/deploy/MultiPythOracleAdapterBeaconSetDeployer.sol";
import {
    MultiPythOracleAdapter,
    MultiPythOracleAdapterConfig,
    FeedConfig
} from "src/concrete/oracle/MultiPythOracleAdapter.sol";
import {CorporateActionPauseConfig} from "src/abstract/BasePythOracleAdapter.sol";

/// @dev Malicious implementation whose `initialize` returns a non-success
/// sentinel, exercising the `InitializeMultiOracleFailed` branch in
/// `newMultiPythOracleAdapter`.
contract BadMultiImpl {
    function initialize(bytes calldata) external pure returns (bytes32) {
        return bytes32(uint256(0xdead));
    }
}

/// @title MultiPythOracleAdapterBeaconSetDeployerConstructTest
/// @notice Mirrors the construct-only tests for the sibling beacon-set
/// deployers (`PythOracleAdapter`, `MorphoProtocolAdapter`,
/// `PassthroughProtocolAdapter`, `OracleRegistry`). Closes audit #55.
contract MultiPythOracleAdapterBeaconSetDeployerConstructTest is Test {
    function _emptyPauseConfig() internal pure returns (CorporateActionPauseConfig memory) {
        return CorporateActionPauseConfig({
            corporateActionsVault: address(0), actionTypeMask: 0, pauseTimeBefore: 0, pauseTimeAfter: 0
        });
    }

    /// Constructor must revert `MultiZeroImplementation` when the
    /// implementation address is zero.
    function testMultiPythOracleAdapterBeaconSetDeployerConstructZeroImplementation(address initialOwner) external {
        vm.assume(initialOwner != address(0));
        vm.expectRevert(abi.encodeWithSelector(MultiZeroImplementation.selector));
        new MultiPythOracleAdapterBeaconSetDeployer(
            MultiPythOracleAdapterBeaconSetDeployerConfig({
                initialOwner: initialOwner, initialMultiPythOracleAdapterImplementation: address(0)
            })
        );
    }

    /// Constructor must revert `MultiZeroBeaconOwner` when the initial owner
    /// is zero (checked after implementation validation).
    function testMultiPythOracleAdapterBeaconSetDeployerConstructZeroBeaconOwner(address initialMultiPythOracleAdapterImplementation)
        external
    {
        vm.assume(initialMultiPythOracleAdapterImplementation != address(0));
        vm.expectRevert(abi.encodeWithSelector(MultiZeroBeaconOwner.selector));
        new MultiPythOracleAdapterBeaconSetDeployer(
            MultiPythOracleAdapterBeaconSetDeployerConfig({
                initialOwner: address(0),
                initialMultiPythOracleAdapterImplementation: initialMultiPythOracleAdapterImplementation
            })
        );
    }

    /// Success path: the beacon is wired to the supplied implementation.
    function testMultiPythOracleAdapterBeaconSetDeployerConstructSuccess(address initialOwner) external {
        vm.assume(initialOwner != address(0));
        MultiPythOracleAdapter implementation = new MultiPythOracleAdapter();
        MultiPythOracleAdapterBeaconSetDeployer deployer = new MultiPythOracleAdapterBeaconSetDeployer(
            MultiPythOracleAdapterBeaconSetDeployerConfig({
                initialOwner: initialOwner, initialMultiPythOracleAdapterImplementation: address(implementation)
            })
        );
        assertEq(address(deployer.I_MULTI_PYTH_ORACLE_ADAPTER_BEACON().implementation()), address(implementation));
    }

    /// `newMultiPythOracleAdapter` must revert `InitializeMultiOracleFailed`
    /// when the cloned proxy's `initialize` returns the wrong sentinel.
    function testNewMultiPythOracleAdapterRevertsInitFailure() external {
        BadMultiImpl bad = new BadMultiImpl();
        MultiPythOracleAdapterBeaconSetDeployer deployer = new MultiPythOracleAdapterBeaconSetDeployer(
            MultiPythOracleAdapterBeaconSetDeployerConfig({
                initialOwner: address(this), initialMultiPythOracleAdapterImplementation: address(bad)
            })
        );

        FeedConfig[] memory feeds = new FeedConfig[](1);
        feeds[0] = FeedConfig({priceId: bytes32(uint256(1)), maxAge: 300});

        vm.expectRevert(abi.encodeWithSelector(InitializeMultiOracleFailed.selector));
        deployer.newMultiPythOracleAdapter(
            MultiPythOracleAdapterConfig({
                vault: address(0xBEEF), feeds: feeds, admin: address(this), pauseConfig: _emptyPauseConfig()
            })
        );
    }

    /// `newMultiPythOracleAdapter` must emit `Deployment(sender, adapter)` on
    /// the success path.
    function testNewMultiPythOracleAdapterEmitsDeploymentEvent(address vault, address admin) external {
        vm.assume(vault != address(0));
        vm.assume(admin != address(0));

        MultiPythOracleAdapter implementation = new MultiPythOracleAdapter();
        MultiPythOracleAdapterBeaconSetDeployer deployer = new MultiPythOracleAdapterBeaconSetDeployer(
            MultiPythOracleAdapterBeaconSetDeployerConfig({
                initialOwner: address(this), initialMultiPythOracleAdapterImplementation: address(implementation)
            })
        );

        FeedConfig[] memory feeds = new FeedConfig[](1);
        feeds[0] = FeedConfig({priceId: bytes32(uint256(1)), maxAge: 300});

        vm.recordLogs();
        MultiPythOracleAdapter adapter = deployer.newMultiPythOracleAdapter(
            MultiPythOracleAdapterConfig({vault: vault, feeds: feeds, admin: admin, pauseConfig: _emptyPauseConfig()})
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("Deployment(address,address)")) {
                // Both fields are indexed — decode from topics, not data.
                address caller = address(uint160(uint256(logs[i].topics[1])));
                address adapterAddr = address(uint160(uint256(logs[i].topics[2])));
                assertEq(caller, address(this));
                assertEq(adapterAddr, address(adapter));
                found = true;
            }
        }
        assertTrue(found, "Deployment event missing");
    }
}
