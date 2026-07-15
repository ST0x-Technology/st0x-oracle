// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.1/src/Test.sol";
import {Vm} from "forge-std-1.16.1/src/Vm.sol";
import {UpgradeableBeacon} from "@openzeppelin-contracts-5.6.1/proxy/beacon/UpgradeableBeacon.sol";
import {AggregatorV2V3Interface} from "src/interface/IAggregatorV2V3.sol";
import {
    PausableOracleWrapper,
    PausableOracleWrapperConfig,
    CorporateActionPauseConfig,
    ZeroAdmin,
    ZeroUpstream
} from "src/concrete/wrapper/PausableOracleWrapper.sol";
import {
    PausableOracleWrapperBeaconSetDeployer,
    PausableOracleWrapperBeaconSetDeployerConfig,
    ZeroImplementation,
    ZeroBeaconOwner
} from "src/concrete/deploy/PausableOracleWrapperBeaconSetDeployer.sol";
import {MockAggregatorV2V3} from "test/mocks/MockAggregatorV2V3.sol";
import {PausableOracleWrapperV2} from "test/mocks/PausableOracleWrapperV2.sol";

contract PausableOracleWrapperBeaconSetDeployerTest is Test {
    PausableOracleWrapper internal implementation;
    MockAggregatorV2V3 internal upstream;
    address internal constant BEACON_OWNER = address(0xBEEF);
    address internal constant ADMIN = address(0xA11CE);

    event Deployment(address indexed caller, address indexed wrapper);

    function setUp() public {
        implementation = new PausableOracleWrapper();
        upstream = new MockAggregatorV2V3();
        vm.warp(1_000_000);
    }

    function _deployBSD() internal returns (PausableOracleWrapperBeaconSetDeployer) {
        return new PausableOracleWrapperBeaconSetDeployer(
            PausableOracleWrapperBeaconSetDeployerConfig({
                initialOwner: BEACON_OWNER, initialPausableOracleWrapperImplementation: address(implementation)
            })
        );
    }

    function _disabledPauseConfig() internal pure returns (CorporateActionPauseConfig memory) {
        return CorporateActionPauseConfig({
            corporateActionsVault: address(0), actionTypeMask: 0, pauseTimeBefore: 0, pauseTimeAfter: 0
        });
    }

    function _defaultWrapperConfig() internal view returns (PausableOracleWrapperConfig memory) {
        return PausableOracleWrapperConfig({
            admin: ADMIN, upstream: AggregatorV2V3Interface(address(upstream)), pauseConfig: _disabledPauseConfig()
        });
    }

    // -------- Constructor validation --------

    function testConstructorRevertsZeroImplementation() external {
        vm.expectRevert(ZeroImplementation.selector);
        new PausableOracleWrapperBeaconSetDeployer(
            PausableOracleWrapperBeaconSetDeployerConfig({
                initialOwner: BEACON_OWNER, initialPausableOracleWrapperImplementation: address(0)
            })
        );
    }

    function testConstructorRevertsZeroBeaconOwner() external {
        vm.expectRevert(ZeroBeaconOwner.selector);
        new PausableOracleWrapperBeaconSetDeployer(
            PausableOracleWrapperBeaconSetDeployerConfig({
                initialOwner: address(0), initialPausableOracleWrapperImplementation: address(implementation)
            })
        );
    }

    function testConstructorHappyPathDeploysBeacon() external {
        PausableOracleWrapperBeaconSetDeployer bsd = _deployBSD();
        address beacon = address(bsd.I_PAUSABLE_ORACLE_WRAPPER_BEACON());
        assertTrue(beacon != address(0));
        assertEq(UpgradeableBeacon(beacon).owner(), BEACON_OWNER);
        assertEq(UpgradeableBeacon(beacon).implementation(), address(implementation));
    }

    // -------- newPausableOracleWrapper --------

    function testNewPausableOracleWrapperEmitsDeployment() external {
        PausableOracleWrapperBeaconSetDeployer bsd = _deployBSD();

        vm.recordLogs();
        PausableOracleWrapper wrapper = bsd.newPausableOracleWrapper(_defaultWrapperConfig());

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sig = keccak256("Deployment(address,address)");
        bool found;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter == address(bsd) && entries[i].topics[0] == sig) {
                assertEq(address(uint160(uint256(entries[i].topics[1]))), address(this), "caller mismatch");
                assertEq(address(uint160(uint256(entries[i].topics[2]))), address(wrapper), "wrapper mismatch");
                found = true;
                break;
            }
        }
        assertTrue(found, "Deployment event not emitted");
    }

    function testNewPausableOracleWrapperInitsState() external {
        PausableOracleWrapperBeaconSetDeployer bsd = _deployBSD();
        PausableOracleWrapper wrapper = bsd.newPausableOracleWrapper(_defaultWrapperConfig());
        assertEq(wrapper.admin(), ADMIN);
        assertEq(address(wrapper.upstream()), address(upstream));
        assertEq(wrapper.paused(), false);
    }

    function testNewPausableOracleWrapperPropagatesInitRevertZeroAdmin() external {
        PausableOracleWrapperBeaconSetDeployer bsd = _deployBSD();
        PausableOracleWrapperConfig memory badConfig = PausableOracleWrapperConfig({
            admin: address(0), upstream: AggregatorV2V3Interface(address(upstream)), pauseConfig: _disabledPauseConfig()
        });
        vm.expectRevert(ZeroAdmin.selector);
        bsd.newPausableOracleWrapper(badConfig);
    }

    /// @notice The beacon is genuinely SHARED: deploy two proxies with DISTINCT
    /// configs, then upgrade the single beacon to a V2 implementation and prove
    /// BOTH proxies retarget (answer the V2-only `implVersion()`), while each
    /// proxy retains its OWN distinct config across the upgrade. A tautological
    /// version (identical configs, no upgrade) would pass even if each proxy
    /// had its own beacon — this discriminates that.
    function testMultipleProxiesShareBeacon() external {
        PausableOracleWrapperBeaconSetDeployer bsd = _deployBSD();

        // Distinct configs: different admin + different upstream per proxy.
        MockAggregatorV2V3 upstreamB = new MockAggregatorV2V3();
        address adminB = address(0xB0B);
        PausableOracleWrapperConfig memory configA = _defaultWrapperConfig();
        PausableOracleWrapperConfig memory configB = PausableOracleWrapperConfig({
            admin: adminB, upstream: AggregatorV2V3Interface(address(upstreamB)), pauseConfig: _disabledPauseConfig()
        });

        PausableOracleWrapper a = bsd.newPausableOracleWrapper(configA);
        PausableOracleWrapper b = bsd.newPausableOracleWrapper(configB);
        assertTrue(address(a) != address(b), "proxies must be distinct");

        address beacon = address(bsd.I_PAUSABLE_ORACLE_WRAPPER_BEACON());
        assertEq(UpgradeableBeacon(beacon).implementation(), address(implementation));

        // V1 has no `implVersion()` — both proxies revert on it pre-upgrade.
        (bool okA,) = address(a).staticcall(abi.encodeWithSignature("implVersion()"));
        (bool okB,) = address(b).staticcall(abi.encodeWithSignature("implVersion()"));
        assertFalse(okA, "V1 has no implVersion() (a)");
        assertFalse(okB, "V1 has no implVersion() (b)");

        // One beacon upgrade retargets EVERY proxy off that beacon.
        PausableOracleWrapperV2 v2Impl = new PausableOracleWrapperV2();
        vm.prank(BEACON_OWNER);
        UpgradeableBeacon(beacon).upgradeTo(address(v2Impl));

        assertEq(PausableOracleWrapperV2(address(a)).implVersion(), 2, "proxy a retargeted");
        assertEq(PausableOracleWrapperV2(address(b)).implVersion(), 2, "proxy b retargeted");

        // Each proxy retains its OWN distinct config across the upgrade.
        assertEq(a.admin(), ADMIN, "proxy a keeps its own admin");
        assertEq(address(a.upstream()), address(upstream), "proxy a keeps its own upstream");
        assertEq(b.admin(), adminB, "proxy b keeps its own admin");
        assertEq(address(b.upstream()), address(upstreamB), "proxy b keeps its own upstream");
    }
}
