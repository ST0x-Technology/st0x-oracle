// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.1/src/Test.sol";
import {Vm} from "forge-std-1.16.1/src/Vm.sol";
import {ChronicleVaultOracle, ChronicleVaultOracleConfig} from "src/concrete/oracle/ChronicleVaultOracle.sol";
import {
    PausableOracleWrapper,
    PausableOracleWrapperConfig,
    CorporateActionPauseConfig
} from "src/concrete/wrapper/PausableOracleWrapper.sol";
import {
    ChronicleVaultOracleBeaconSetDeployer,
    ChronicleVaultOracleBeaconSetDeployerConfig
} from "src/concrete/deploy/ChronicleVaultOracleBeaconSetDeployer.sol";
import {
    PausableOracleWrapperBeaconSetDeployer,
    PausableOracleWrapperBeaconSetDeployerConfig
} from "src/concrete/deploy/PausableOracleWrapperBeaconSetDeployer.sol";
import {
    ChronicleOracleUnifiedDeployer,
    ChronicleOracleUnifiedDeployerConstructorConfig,
    ChronicleOracleUnifiedDeployConfig,
    ZeroBeaconSetDeployer
} from "src/concrete/deploy/ChronicleOracleUnifiedDeployer.sol";
import {MockChronicle} from "test/mocks/MockChronicle.sol";
import {MockERC4626} from "test/mocks/MockERC4626.sol";

contract ChronicleOracleUnifiedDeployerTest is Test {
    ChronicleVaultOracle internal oracleImpl;
    PausableOracleWrapper internal wrapperImpl;
    ChronicleVaultOracleBeaconSetDeployer internal oracleBSD;
    PausableOracleWrapperBeaconSetDeployer internal wrapperBSD;
    MockChronicle internal chronicle;
    MockERC4626 internal vault;

    address internal constant BEACON_OWNER = address(0xBEEF);
    address internal constant ADMIN = address(0xA11CE);
    uint256 internal constant MAX_AGE = 1 hours;

    event Deployment(address indexed caller, address indexed oracle, address indexed wrapper);

    function setUp() public {
        oracleImpl = new ChronicleVaultOracle();
        wrapperImpl = new PausableOracleWrapper();
        chronicle = new MockChronicle();
        vault = new MockERC4626();

        oracleBSD = new ChronicleVaultOracleBeaconSetDeployer(
            ChronicleVaultOracleBeaconSetDeployerConfig({
                initialOwner: BEACON_OWNER, initialChronicleVaultOracleImplementation: address(oracleImpl)
            })
        );
        wrapperBSD = new PausableOracleWrapperBeaconSetDeployer(
            PausableOracleWrapperBeaconSetDeployerConfig({
                initialOwner: BEACON_OWNER, initialPausableOracleWrapperImplementation: address(wrapperImpl)
            })
        );

        vm.warp(1_000_000);
    }

    function _disabledPauseConfig() internal pure returns (CorporateActionPauseConfig memory) {
        return CorporateActionPauseConfig({
            corporateActionsVault: address(0), actionTypeMask: 0, pauseTimeBefore: 0, pauseTimeAfter: 0
        });
    }

    function _defaultDeployConfig() internal view returns (ChronicleOracleUnifiedDeployConfig memory) {
        return ChronicleOracleUnifiedDeployConfig({
            admin: ADMIN,
            oracleConfig: ChronicleVaultOracleConfig({chronicle: chronicle, vault: address(vault), maxAge: MAX_AGE}),
            pauseConfig: _disabledPauseConfig()
        });
    }

    function _deployUnified() internal returns (ChronicleOracleUnifiedDeployer) {
        return new ChronicleOracleUnifiedDeployer(
            ChronicleOracleUnifiedDeployerConstructorConfig({
                chronicleVaultOracleBeaconSetDeployer: oracleBSD, pausableOracleWrapperBeaconSetDeployer: wrapperBSD
            })
        );
    }

    // -------- Constructor validation --------

    function testConstructorRevertsZeroChronicleBSD() external {
        vm.expectRevert(ZeroBeaconSetDeployer.selector);
        new ChronicleOracleUnifiedDeployer(
            ChronicleOracleUnifiedDeployerConstructorConfig({
                chronicleVaultOracleBeaconSetDeployer: ChronicleVaultOracleBeaconSetDeployer(address(0)),
                pausableOracleWrapperBeaconSetDeployer: wrapperBSD
            })
        );
    }

    function testConstructorRevertsZeroWrapperBSD() external {
        vm.expectRevert(ZeroBeaconSetDeployer.selector);
        new ChronicleOracleUnifiedDeployer(
            ChronicleOracleUnifiedDeployerConstructorConfig({
                chronicleVaultOracleBeaconSetDeployer: oracleBSD,
                pausableOracleWrapperBeaconSetDeployer: PausableOracleWrapperBeaconSetDeployer(address(0))
            })
        );
    }

    function testConstructorHappyPathStoresBoth() external {
        ChronicleOracleUnifiedDeployer unified = _deployUnified();
        assertEq(address(unified.I_CHRONICLE_VAULT_ORACLE_BEACON_SET_DEPLOYER()), address(oracleBSD));
        assertEq(address(unified.I_PAUSABLE_ORACLE_WRAPPER_BEACON_SET_DEPLOYER()), address(wrapperBSD));
    }

    // -------- newOracleWithWrapper --------

    function testNewOracleWithWrapperEmitsAndWires() external {
        ChronicleOracleUnifiedDeployer unified = _deployUnified();

        vm.recordLogs();
        (ChronicleVaultOracle oracle, PausableOracleWrapper wrapper) =
            unified.newOracleWithWrapper(_defaultDeployConfig());

        // Wiring: wrapper.upstream() points at oracle, admin is the configured
        // governance address, oracle.chronicle() is the configured chronicle.
        assertEq(address(wrapper.upstream()), address(oracle), "wrapper.upstream not wired to oracle");
        assertEq(wrapper.admin(), ADMIN, "wrapper.admin not set");
        assertEq(address(oracle.chronicle()), address(chronicle), "oracle.chronicle not set");
        assertEq(oracle.vault(), address(vault));
        assertEq(oracle.maxAge(), MAX_AGE);

        // Locate the unified Deployment(address,address,address) event in the
        // recorded logs.
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sig = keccak256("Deployment(address,address,address)");
        bool found;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter == address(unified) && entries[i].topics[0] == sig) {
                assertEq(address(uint160(uint256(entries[i].topics[1]))), address(this), "caller");
                assertEq(address(uint160(uint256(entries[i].topics[2]))), address(oracle), "oracle topic");
                assertEq(address(uint160(uint256(entries[i].topics[3]))), address(wrapper), "wrapper topic");
                found = true;
                break;
            }
        }
        assertTrue(found, "unified Deployment event not emitted");
    }

    function testEndToEndLatestAnswerThroughWrapper() external {
        ChronicleOracleUnifiedDeployer unified = _deployUnified();
        (ChronicleVaultOracle oracle, PausableOracleWrapper wrapper) =
            unified.newOracleWithWrapper(_defaultDeployConfig());

        // Mock Chronicle: $100 at 18dp, fresh.
        chronicle.setReadWithAge(100e18, block.timestamp);
        // Vault: 2 assets per share.
        vault.setTotalAssets(2e18);
        vault.setTotalSupply(1e18);

        // Direct read against the underlying oracle.
        int256 oracleAnswer = oracle.latestAnswer();
        assertEq(oracleAnswer, int256(200e8), "oracle direct read");

        // Read through the wrapper — same value since the wrapper is a pure
        // pass-through with no pause active.
        int256 wrapperAnswer = wrapper.latestAnswer();
        assertEq(wrapperAnswer, oracleAnswer, "wrapper -> oracle pass-through");
        assertEq(wrapperAnswer, int256(200e8));
    }
}
