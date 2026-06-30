// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.1/src/Test.sol";
import {Vm} from "forge-std-1.16.1/src/Vm.sol";
import {AggregatorV2V3Interface} from "src/interface/IAggregatorV2V3.sol";
import {IDIAOracleV2} from "src/interface/IDIAOracleV2.sol";
import {DIAVaultOracle, DIAVaultOracleConfig} from "src/concrete/oracle/DIAVaultOracle.sol";
import {PausableOracleWrapper, CorporateActionPauseConfig} from "src/concrete/wrapper/PausableOracleWrapper.sol";
import {
    DIAVaultOracleBeaconSetDeployer,
    DIAVaultOracleBeaconSetDeployerConfig
} from "src/concrete/deploy/DIAVaultOracleBeaconSetDeployer.sol";
import {
    PausableOracleWrapperBeaconSetDeployer,
    PausableOracleWrapperBeaconSetDeployerConfig
} from "src/concrete/deploy/PausableOracleWrapperBeaconSetDeployer.sol";
import {
    DIAOracleUnifiedDeployer,
    DIAOracleUnifiedDeployerConstructorConfig,
    DIAOracleUnifiedDeployConfig,
    ZeroBeaconSetDeployer
} from "src/concrete/deploy/DIAOracleUnifiedDeployer.sol";
import {MockDIAOracle} from "test/mocks/MockDIAOracle.sol";
import {MockERC4626} from "test/mocks/MockERC4626.sol";

contract DIAOracleUnifiedDeployerTest is Test {
    DIAVaultOracle internal oracleImpl;
    PausableOracleWrapper internal wrapperImpl;
    DIAVaultOracleBeaconSetDeployer internal oracleBSD;
    PausableOracleWrapperBeaconSetDeployer internal wrapperBSD;

    MockDIAOracle internal diaOracle;
    MockERC4626 internal vault;

    address internal constant ADMIN = address(0xA11CE);
    string internal constant SYMBOL = "COIN";
    uint256 internal constant MAX_AGE = 1 hours;

    event Deployment(address indexed caller, address indexed oracle, address indexed wrapper);

    function setUp() public {
        oracleImpl = new DIAVaultOracle();
        wrapperImpl = new PausableOracleWrapper();
        diaOracle = new MockDIAOracle();
        vault = new MockERC4626();

        oracleBSD = new DIAVaultOracleBeaconSetDeployer(
            DIAVaultOracleBeaconSetDeployerConfig({
                initialOwner: address(this), initialDIAVaultOracleImplementation: address(oracleImpl)
            })
        );
        wrapperBSD = new PausableOracleWrapperBeaconSetDeployer(
            PausableOracleWrapperBeaconSetDeployerConfig({
                initialOwner: address(this), initialPausableOracleWrapperImplementation: address(wrapperImpl)
            })
        );

        vm.warp(1_000_000);
    }

    function _disabledPauseConfig() internal pure returns (CorporateActionPauseConfig memory) {
        return CorporateActionPauseConfig({
            corporateActionsVault: address(0), actionTypeMask: 0, pauseTimeBefore: 0, pauseTimeAfter: 0
        });
    }

    function _defaultDeployConfig() internal view returns (DIAOracleUnifiedDeployConfig memory) {
        return DIAOracleUnifiedDeployConfig({
            admin: ADMIN,
            oracleConfig: DIAVaultOracleConfig({
                diaOracle: IDIAOracleV2(address(diaOracle)), symbol: SYMBOL, vault: address(vault), maxAge: MAX_AGE
            }),
            pauseConfig: _disabledPauseConfig()
        });
    }

    // -------- Constructor validation --------

    function testConstructorRevertsZeroDIABSD() external {
        vm.expectRevert(ZeroBeaconSetDeployer.selector);
        new DIAOracleUnifiedDeployer(
            DIAOracleUnifiedDeployerConstructorConfig({
                diaVaultOracleBeaconSetDeployer: DIAVaultOracleBeaconSetDeployer(address(0)),
                pausableOracleWrapperBeaconSetDeployer: wrapperBSD
            })
        );
    }

    function testConstructorRevertsZeroWrapperBSD() external {
        vm.expectRevert(ZeroBeaconSetDeployer.selector);
        new DIAOracleUnifiedDeployer(
            DIAOracleUnifiedDeployerConstructorConfig({
                diaVaultOracleBeaconSetDeployer: oracleBSD,
                pausableOracleWrapperBeaconSetDeployer: PausableOracleWrapperBeaconSetDeployer(address(0))
            })
        );
    }

    function testConstructorHappyPathStoresBSDs() external {
        DIAOracleUnifiedDeployer unified = new DIAOracleUnifiedDeployer(
            DIAOracleUnifiedDeployerConstructorConfig({
                diaVaultOracleBeaconSetDeployer: oracleBSD, pausableOracleWrapperBeaconSetDeployer: wrapperBSD
            })
        );
        assertEq(address(unified.I_DIA_VAULT_ORACLE_BEACON_SET_DEPLOYER()), address(oracleBSD));
        assertEq(address(unified.I_PAUSABLE_ORACLE_WRAPPER_BEACON_SET_DEPLOYER()), address(wrapperBSD));
    }

    // -------- newOracleWithWrapper --------

    function testNewOracleWithWrapperEmitsAndWiresUp() external {
        DIAOracleUnifiedDeployer unified = new DIAOracleUnifiedDeployer(
            DIAOracleUnifiedDeployerConstructorConfig({
                diaVaultOracleBeaconSetDeployer: oracleBSD, pausableOracleWrapperBeaconSetDeployer: wrapperBSD
            })
        );

        vm.recordLogs();
        (DIAVaultOracle oracle, PausableOracleWrapper wrapper) = unified.newOracleWithWrapper(_defaultDeployConfig());

        // -- Event --
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sig = keccak256("Deployment(address,address,address)");
        bool found;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter == address(unified) && entries[i].topics[0] == sig) {
                assertEq(address(uint160(uint256(entries[i].topics[1]))), address(this), "caller mismatch");
                assertEq(address(uint160(uint256(entries[i].topics[2]))), address(oracle), "oracle mismatch");
                assertEq(address(uint160(uint256(entries[i].topics[3]))), address(wrapper), "wrapper mismatch");
                found = true;
                break;
            }
        }
        assertTrue(found, "unified Deployment event not emitted");

        // -- Wiring --
        assertEq(address(wrapper.upstream()), address(oracle), "wrapper upstream wired to oracle");
        assertEq(wrapper.admin(), ADMIN, "wrapper admin from config");
        assertEq(address(oracle.diaOracle()), address(diaOracle), "oracle DIA feed from config");
    }

    function testNewOracleWithWrapperEndToEndPriceRead() external {
        // Proves the full deploy graph is wired correctly by reading a price
        // through the wrapper — if any wire is wrong the call would either
        // revert or return a stale/wrong number.
        DIAOracleUnifiedDeployer unified = new DIAOracleUnifiedDeployer(
            DIAOracleUnifiedDeployerConstructorConfig({
                diaVaultOracleBeaconSetDeployer: oracleBSD, pausableOracleWrapperBeaconSetDeployer: wrapperBSD
            })
        );

        (DIAVaultOracle oracle, PausableOracleWrapper wrapper) = unified.newOracleWithWrapper(_defaultDeployConfig());

        diaOracle.setValue(SYMBOL, 100e18, uint128(block.timestamp));
        vault.setTotalAssets(1e18);
        vault.setTotalSupply(1e18);

        assertEq(wrapper.latestAnswer(), int256(100e8));
        assertEq(oracle.latestAnswer(), int256(100e8));
    }
}
