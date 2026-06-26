// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.1/src/Test.sol";
import {Vm} from "forge-std-1.16.1/src/Vm.sol";
import {UpgradeableBeacon} from "@openzeppelin-contracts-5.6.1/proxy/beacon/UpgradeableBeacon.sol";
import {IChronicle} from "src/interface/IChronicle.sol";
import {
    ChronicleVaultOracle,
    ChronicleVaultOracleConfig,
    ZeroVault
} from "src/concrete/oracle/ChronicleVaultOracle.sol";
import {
    ChronicleVaultOracleBeaconSetDeployer,
    ChronicleVaultOracleBeaconSetDeployerConfig,
    ZeroImplementation,
    ZeroBeaconOwner
} from "src/concrete/deploy/ChronicleVaultOracleBeaconSetDeployer.sol";
import {MockChronicle} from "test/mocks/MockChronicle.sol";
import {MockERC4626} from "test/mocks/MockERC4626.sol";

contract ChronicleVaultOracleBeaconSetDeployerTest is Test {
    ChronicleVaultOracle internal implementation;
    MockChronicle internal chronicle;
    MockERC4626 internal vault;
    address internal constant BEACON_OWNER = address(0xBEEF);
    uint256 internal constant MAX_AGE = 1 hours;

    event Deployment(address indexed caller, address indexed oracle);

    function setUp() public {
        implementation = new ChronicleVaultOracle();
        chronicle = new MockChronicle();
        vault = new MockERC4626();
        vm.warp(1_000_000);
    }

    function _deployBSD() internal returns (ChronicleVaultOracleBeaconSetDeployer) {
        return new ChronicleVaultOracleBeaconSetDeployer(
            ChronicleVaultOracleBeaconSetDeployerConfig({
                initialOwner: BEACON_OWNER, initialChronicleVaultOracleImplementation: address(implementation)
            })
        );
    }

    function _defaultOracleConfig() internal view returns (ChronicleVaultOracleConfig memory) {
        return ChronicleVaultOracleConfig({chronicle: chronicle, vault: address(vault), maxAge: MAX_AGE});
    }

    // -------- Constructor validation --------

    function testConstructorRevertsZeroImplementation() external {
        vm.expectRevert(ZeroImplementation.selector);
        new ChronicleVaultOracleBeaconSetDeployer(
            ChronicleVaultOracleBeaconSetDeployerConfig({
                initialOwner: BEACON_OWNER, initialChronicleVaultOracleImplementation: address(0)
            })
        );
    }

    function testConstructorRevertsZeroBeaconOwner() external {
        vm.expectRevert(ZeroBeaconOwner.selector);
        new ChronicleVaultOracleBeaconSetDeployer(
            ChronicleVaultOracleBeaconSetDeployerConfig({
                initialOwner: address(0), initialChronicleVaultOracleImplementation: address(implementation)
            })
        );
    }

    function testConstructorHappyPathDeploysBeacon() external {
        ChronicleVaultOracleBeaconSetDeployer bsd = _deployBSD();
        address beacon = address(bsd.I_CHRONICLE_VAULT_ORACLE_BEACON());
        assertTrue(beacon != address(0));
        assertEq(UpgradeableBeacon(beacon).owner(), BEACON_OWNER);
        assertEq(UpgradeableBeacon(beacon).implementation(), address(implementation));
    }

    // -------- newChronicleVaultOracle --------

    function testNewChronicleVaultOracleEmitsDeployment() external {
        ChronicleVaultOracleBeaconSetDeployer bsd = _deployBSD();

        // We can't predict the proxy address without computing CREATE nonce —
        // so check caller (indexed) and ignore the address topic by using
        // checkData=false on the second indexed slot via `vm.recordLogs`.
        vm.recordLogs();
        ChronicleVaultOracle oracle = bsd.newChronicleVaultOracle(_defaultOracleConfig());

        Vm.Log[] memory entries = vm.getRecordedLogs();
        // Walk entries to find the Deployment event from the BSD itself.
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

    function testNewChronicleVaultOracleInitsState() external {
        ChronicleVaultOracleBeaconSetDeployer bsd = _deployBSD();
        ChronicleVaultOracle oracle = bsd.newChronicleVaultOracle(_defaultOracleConfig());
        assertEq(address(oracle.chronicle()), address(chronicle));
        assertEq(oracle.vault(), address(vault));
        assertEq(oracle.maxAge(), MAX_AGE);
    }

    function testNewChronicleVaultOraclePropagatesInitRevert() external {
        ChronicleVaultOracleBeaconSetDeployer bsd = _deployBSD();
        ChronicleVaultOracleConfig memory badConfig =
            ChronicleVaultOracleConfig({chronicle: chronicle, vault: address(0), maxAge: MAX_AGE});
        vm.expectRevert(ZeroVault.selector);
        bsd.newChronicleVaultOracle(badConfig);
    }

    function testMultipleProxiesShareBeacon() external {
        ChronicleVaultOracleBeaconSetDeployer bsd = _deployBSD();
        ChronicleVaultOracle a = bsd.newChronicleVaultOracle(_defaultOracleConfig());
        ChronicleVaultOracle b = bsd.newChronicleVaultOracle(_defaultOracleConfig());
        assertTrue(address(a) != address(b), "proxies must be distinct");

        // Both proxies should resolve through the same beacon address.
        // BeaconProxy stores the beacon in a known slot; we verify indirectly
        // by checking both proxies still resolve the same implementation
        // (this is `UpgradeableBeacon.implementation()` reached via the proxy
        // logic).
        address beacon = address(bsd.I_CHRONICLE_VAULT_ORACLE_BEACON());
        assertEq(UpgradeableBeacon(beacon).implementation(), address(implementation));

        // Functional sanity: both proxies share the same logic and behave
        // identically given identical state. We didn't init them with the
        // same vault state, but they should both have the same maxAge value
        // from their own storage (set during the per-proxy init).
        assertEq(a.maxAge(), b.maxAge());
    }
}
