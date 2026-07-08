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

    function testMultipleProxiesShareBeacon() external {
        PausableOracleWrapperBeaconSetDeployer bsd = _deployBSD();
        PausableOracleWrapper a = bsd.newPausableOracleWrapper(_defaultWrapperConfig());
        PausableOracleWrapper b = bsd.newPausableOracleWrapper(_defaultWrapperConfig());
        assertTrue(address(a) != address(b), "proxies must be distinct");

        address beacon = address(bsd.I_PAUSABLE_ORACLE_WRAPPER_BEACON());
        assertEq(UpgradeableBeacon(beacon).implementation(), address(implementation));

        // Both proxies independently delegate to the same implementation, so
        // both `upstream()` reads should succeed and return the value each
        // was initialized with.
        assertEq(address(a.upstream()), address(b.upstream()));
    }
}
