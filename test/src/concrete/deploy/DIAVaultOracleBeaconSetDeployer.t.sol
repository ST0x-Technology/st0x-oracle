// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.1/src/Test.sol";
import {Vm} from "forge-std-1.16.1/src/Vm.sol";
import {UpgradeableBeacon} from "@openzeppelin-contracts-5.6.1/proxy/beacon/UpgradeableBeacon.sol";
import {IDIAOracleV2} from "src/interface/IDIAOracleV2.sol";
import {DIAVaultOracle, DIAVaultOracleConfig, ZeroVault} from "src/concrete/oracle/DIAVaultOracle.sol";
import {
    DIAVaultOracleBeaconSetDeployer,
    DIAVaultOracleBeaconSetDeployerConfig,
    ZeroImplementation,
    ZeroBeaconOwner
} from "src/concrete/deploy/DIAVaultOracleBeaconSetDeployer.sol";
import {MockDIAOracle} from "test/mocks/MockDIAOracle.sol";
import {MockERC4626} from "test/mocks/MockERC4626.sol";

contract DIAVaultOracleBeaconSetDeployerTest is Test {
    DIAVaultOracle internal implementation;
    MockDIAOracle internal diaOracle;
    MockERC4626 internal vault;
    address internal constant BEACON_OWNER = address(0xBEEF);
    string internal constant SYMBOL = "COIN";
    uint256 internal constant MAX_AGE = 1 hours;

    event Deployment(address indexed caller, address indexed oracle);

    function setUp() public {
        implementation = new DIAVaultOracle();
        diaOracle = new MockDIAOracle();
        vault = new MockERC4626();
        vm.warp(1_000_000);
    }

    function _deployBSD() internal returns (DIAVaultOracleBeaconSetDeployer) {
        return new DIAVaultOracleBeaconSetDeployer(
            DIAVaultOracleBeaconSetDeployerConfig({
                initialOwner: BEACON_OWNER, initialDIAVaultOracleImplementation: address(implementation)
            })
        );
    }

    function _defaultOracleConfig() internal view returns (DIAVaultOracleConfig memory) {
        return DIAVaultOracleConfig({
            diaOracle: IDIAOracleV2(address(diaOracle)), symbol: SYMBOL, vault: address(vault), maxAge: MAX_AGE
        });
    }

    // -------- Constructor validation --------

    function testConstructorRevertsZeroImplementation() external {
        vm.expectRevert(ZeroImplementation.selector);
        new DIAVaultOracleBeaconSetDeployer(
            DIAVaultOracleBeaconSetDeployerConfig({
                initialOwner: BEACON_OWNER, initialDIAVaultOracleImplementation: address(0)
            })
        );
    }

    function testConstructorRevertsZeroBeaconOwner() external {
        vm.expectRevert(ZeroBeaconOwner.selector);
        new DIAVaultOracleBeaconSetDeployer(
            DIAVaultOracleBeaconSetDeployerConfig({
                initialOwner: address(0), initialDIAVaultOracleImplementation: address(implementation)
            })
        );
    }

    function testConstructorHappyPathDeploysBeacon() external {
        DIAVaultOracleBeaconSetDeployer bsd = _deployBSD();
        address beacon = address(bsd.I_DIA_VAULT_ORACLE_BEACON());
        assertTrue(beacon != address(0));
        assertEq(UpgradeableBeacon(beacon).owner(), BEACON_OWNER);
        assertEq(UpgradeableBeacon(beacon).implementation(), address(implementation));
    }

    // -------- newDIAVaultOracle --------

    function testNewDIAVaultOracleEmitsDeployment() external {
        DIAVaultOracleBeaconSetDeployer bsd = _deployBSD();

        vm.recordLogs();
        DIAVaultOracle oracle = bsd.newDIAVaultOracle(_defaultOracleConfig());

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sig = keccak256("Deployment(address,address)");
        bool found;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter == address(bsd) && entries[i].topics[0] == sig) {
                assertEq(address(uint160(uint256(entries[i].topics[1]))), address(this), "caller mismatch");
                assertEq(address(uint160(uint256(entries[i].topics[2]))), address(oracle), "oracle mismatch");
                found = true;
                break;
            }
        }
        assertTrue(found, "Deployment event not emitted");
    }

    function testNewDIAVaultOraclePropagatesInitRevertZeroVault() external {
        DIAVaultOracleBeaconSetDeployer bsd = _deployBSD();
        DIAVaultOracleConfig memory badConfig = DIAVaultOracleConfig({
            diaOracle: IDIAOracleV2(address(diaOracle)), symbol: SYMBOL, vault: address(0), maxAge: MAX_AGE
        });
        vm.expectRevert(ZeroVault.selector);
        bsd.newDIAVaultOracle(badConfig);
    }

    function testMultipleProxiesShareBeacon() external {
        DIAVaultOracleBeaconSetDeployer bsd = _deployBSD();
        DIAVaultOracle a = bsd.newDIAVaultOracle(_defaultOracleConfig());
        DIAVaultOracle b = bsd.newDIAVaultOracle(_defaultOracleConfig());
        assertTrue(address(a) != address(b), "proxies must be distinct");

        address beacon = address(bsd.I_DIA_VAULT_ORACLE_BEACON());
        assertEq(UpgradeableBeacon(beacon).implementation(), address(implementation));

        // Both proxies independently delegate to the same implementation, so
        // both `diaOracle()` reads should succeed and return the value each
        // was initialized with.
        assertEq(address(a.diaOracle()), address(b.diaOracle()));
    }
}
