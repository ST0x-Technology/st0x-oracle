// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {OracleRegistryTest} from "test/abstract/OracleRegistryTest.sol";
import {
    OracleRegistry,
    OracleRegistryConfig,
    OnlyAdmin,
    ZeroAdmin,
    ZeroVault,
    ZeroOracle,
    ArrayLengthMismatch,
    BulkLengthExceeded,
    MAX_BULK_LENGTH
} from "src/concrete/registry/OracleRegistry.sol";
import {ICLONEABLE_V2_SUCCESS} from "rain-factory-0.1.1/src/interface/ICloneableV2.sol";
import {AggregatorV2V3Interface} from "src/interface/IAggregatorV2V3.sol";
import {Vm} from "forge-std-1.16.1/src/Test.sol";

contract OracleRegistryInitializeTest is OracleRegistryTest {
    /// Test that deployer sets msg.sender as admin.
    /// Note: zero admin is no longer possible through the deployer since
    /// msg.sender cannot be address(0).
    function testInitializeAdminIsMsgSender(address admin) external {
        vm.assume(admin != address(0));
        vm.prank(admin);
        OracleRegistry registry = I_DEPLOYER.newOracleRegistry();
        assertEq(registry.admin(), admin);
    }

    /// Test successful initialization sets admin correctly.
    function testInitializeSuccess(address admin) external {
        vm.assume(admin != address(0));

        OracleRegistry registry = createRegistry(admin);

        assertEq(registry.admin(), admin);
    }

    /// Test that OracleRegistryInitialized event is emitted.
    function testInitializeEvent(address admin) external {
        vm.assume(admin != address(0));

        vm.recordLogs();
        OracleRegistry registry = createRegistry(admin);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool eventFound = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("OracleRegistryInitialized(address,(address))")) {
                address sender = address(uint160(uint256(logs[i].topics[1])));
                OracleRegistryConfig memory config = abi.decode(logs[i].data, (OracleRegistryConfig));
                assertEq(sender, address(I_DEPLOYER));
                assertEq(config.admin, admin);
                eventFound = true;
                break;
            }
        }
        assertTrue(eventFound, "OracleRegistryInitialized event not found");
        assertTrue(address(registry) != address(0));
    }
}

contract OracleRegistrySetOracleTest is OracleRegistryTest {
    /// Test that only admin can call setOracle.
    function testSetOracleOnlyAdmin(address admin, address notAdmin, address vault, address oracle) external {
        vm.assume(admin != address(0));
        vm.assume(notAdmin != admin);
        vm.assume(vault != address(0));
        vm.assume(oracle != address(0));

        OracleRegistry registry = createRegistry(admin);

        vm.prank(notAdmin);
        vm.expectRevert(abi.encodeWithSelector(OnlyAdmin.selector));
        registry.setOracle(vault, AggregatorV2V3Interface(oracle));
    }

    /// Test that zero vault address reverts.
    function testSetOracleZeroVault(address admin, address oracle) external {
        vm.assume(admin != address(0));
        vm.assume(oracle != address(0));

        OracleRegistry registry = createRegistry(admin);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ZeroVault.selector));
        registry.setOracle(address(0), AggregatorV2V3Interface(oracle));
    }

    /// Test that zero oracle address reverts.
    function testSetOracleZeroOracle(address admin, address vault) external {
        vm.assume(admin != address(0));
        vm.assume(vault != address(0));

        OracleRegistry registry = createRegistry(admin);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ZeroOracle.selector));
        registry.setOracle(vault, AggregatorV2V3Interface(address(0)));
    }

    /// Test successful new registration (oldOracle is address(0)).
    function testSetOracleNewRegistration(address admin, address vault, address oracle) external {
        vm.assume(admin != address(0));
        vm.assume(vault != address(0));
        vm.assume(oracle != address(0));

        OracleRegistry registry = createRegistry(admin);

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit OracleSet(vault, address(0), oracle);
        registry.setOracle(vault, AggregatorV2V3Interface(oracle));

        assertEq(address(registry.getOracle(vault)), oracle);
    }

    /// Test successful update of existing registration.
    function testSetOracleUpdate(address admin, address vault, address oracle1, address oracle2) external {
        vm.assume(admin != address(0));
        vm.assume(vault != address(0));
        vm.assume(oracle1 != address(0));
        vm.assume(oracle2 != address(0));
        vm.assume(oracle1 != oracle2);

        OracleRegistry registry = createRegistry(admin);

        vm.prank(admin);
        registry.setOracle(vault, AggregatorV2V3Interface(oracle1));

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit OracleSet(vault, oracle1, oracle2);
        registry.setOracle(vault, AggregatorV2V3Interface(oracle2));

        assertEq(address(registry.getOracle(vault)), oracle2);
    }

    event OracleSet(address indexed vault, address indexed oldOracle, address indexed newOracle);
}

contract OracleRegistrySetOracleBulkTest is OracleRegistryTest {
    /// Test that only admin can call setOracleBulk.
    function testSetOracleBulkOnlyAdmin(address admin, address notAdmin) external {
        vm.assume(admin != address(0));
        vm.assume(notAdmin != admin);

        OracleRegistry registry = createRegistry(admin);

        address[] memory vaults = new address[](1);
        vaults[0] = address(1);
        AggregatorV2V3Interface[] memory oracles = new AggregatorV2V3Interface[](1);
        oracles[0] = AggregatorV2V3Interface(address(2));

        vm.prank(notAdmin);
        vm.expectRevert(abi.encodeWithSelector(OnlyAdmin.selector));
        registry.setOracleBulk(vaults, oracles);
    }

    /// Test that array length mismatch reverts.
    function testSetOracleBulkArrayLengthMismatch(address admin) external {
        vm.assume(admin != address(0));

        OracleRegistry registry = createRegistry(admin);

        address[] memory vaults = new address[](2);
        vaults[0] = address(1);
        vaults[1] = address(2);
        AggregatorV2V3Interface[] memory oracles = new AggregatorV2V3Interface[](1);
        oracles[0] = AggregatorV2V3Interface(address(3));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ArrayLengthMismatch.selector));
        registry.setOracleBulk(vaults, oracles);
    }

    /// Test that zero vault in bulk reverts.
    function testSetOracleBulkZeroVault(address admin) external {
        vm.assume(admin != address(0));

        OracleRegistry registry = createRegistry(admin);

        address[] memory vaults = new address[](2);
        vaults[0] = address(1);
        vaults[1] = address(0);
        AggregatorV2V3Interface[] memory oracles = new AggregatorV2V3Interface[](2);
        oracles[0] = AggregatorV2V3Interface(address(2));
        oracles[1] = AggregatorV2V3Interface(address(3));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ZeroVault.selector));
        registry.setOracleBulk(vaults, oracles);
    }

    /// Test that zero oracle in bulk reverts.
    function testSetOracleBulkZeroOracle(address admin) external {
        vm.assume(admin != address(0));

        OracleRegistry registry = createRegistry(admin);

        address[] memory vaults = new address[](2);
        vaults[0] = address(1);
        vaults[1] = address(2);
        AggregatorV2V3Interface[] memory oracles = new AggregatorV2V3Interface[](2);
        oracles[0] = AggregatorV2V3Interface(address(3));
        oracles[1] = AggregatorV2V3Interface(address(0));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ZeroOracle.selector));
        registry.setOracleBulk(vaults, oracles);
    }

    /// `setOracleBulk` must revert `BulkLengthExceeded(length, max)` when the
    /// input arrays are strictly longer than `MAX_BULK_LENGTH`. The cap exists
    /// so a multisig signer can confirm the bound from the calldata alone —
    /// the function must surface the cap, not silently consume gas. Closes
    /// audit #36.
    function testSetOracleBulkRevertsAboveMaxLength(address admin) external {
        vm.assume(admin != address(0));

        OracleRegistry registry = createRegistry(admin);

        address[] memory vaults = new address[](MAX_BULK_LENGTH + 1);
        AggregatorV2V3Interface[] memory oracles = new AggregatorV2V3Interface[](MAX_BULK_LENGTH + 1);
        for (uint256 i = 0; i < vaults.length; i++) {
            vaults[i] = address(uint160(i + 1));
            oracles[i] = AggregatorV2V3Interface(address(uint160(i + 1 + 1e6)));
        }

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(BulkLengthExceeded.selector, MAX_BULK_LENGTH + 1, MAX_BULK_LENGTH));
        registry.setOracleBulk(vaults, oracles);
    }

    /// `setOracleBulk` must succeed at exactly `MAX_BULK_LENGTH` entries — the
    /// cap is inclusive. Catches an off-by-one regression (`>=`) that would
    /// silently reject the largest valid bulk call. Closes audit #36.
    function testSetOracleBulkSucceedsAtExactlyMaxLength(address admin) external {
        vm.assume(admin != address(0));

        OracleRegistry registry = createRegistry(admin);

        address[] memory vaults = new address[](MAX_BULK_LENGTH);
        AggregatorV2V3Interface[] memory oracles = new AggregatorV2V3Interface[](MAX_BULK_LENGTH);
        for (uint256 i = 0; i < vaults.length; i++) {
            vaults[i] = address(uint160(i + 1));
            oracles[i] = AggregatorV2V3Interface(address(uint160(i + 1 + 1e6)));
        }

        vm.prank(admin);
        registry.setOracleBulk(vaults, oracles);

        for (uint256 i = 0; i < vaults.length; i++) {
            assertEq(address(registry.getOracle(vaults[i])), address(oracles[i]));
        }
    }

    /// Test successful bulk registration.
    function testSetOracleBulkSuccess(address admin) external {
        vm.assume(admin != address(0));

        OracleRegistry registry = createRegistry(admin);

        address[] memory vaults = new address[](3);
        vaults[0] = address(1);
        vaults[1] = address(2);
        vaults[2] = address(3);
        AggregatorV2V3Interface[] memory oracles = new AggregatorV2V3Interface[](3);
        oracles[0] = AggregatorV2V3Interface(address(4));
        oracles[1] = AggregatorV2V3Interface(address(5));
        oracles[2] = AggregatorV2V3Interface(address(6));

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit OracleSet(vaults[0], address(0), address(oracles[0]));
        vm.expectEmit(true, true, true, true);
        emit OracleSet(vaults[1], address(0), address(oracles[1]));
        vm.expectEmit(true, true, true, true);
        emit OracleSet(vaults[2], address(0), address(oracles[2]));
        registry.setOracleBulk(vaults, oracles);

        assertEq(address(registry.getOracle(vaults[0])), address(oracles[0]));
        assertEq(address(registry.getOracle(vaults[1])), address(oracles[1]));
        assertEq(address(registry.getOracle(vaults[2])), address(oracles[2]));
    }

    event OracleSet(address indexed vault, address indexed oldOracle, address indexed newOracle);
}

contract OracleRegistryGetOracleTest is OracleRegistryTest {
    /// Test that getOracle returns address(0) for unregistered vault.
    function testGetOracleUnregistered(address admin, address vault) external {
        vm.assume(admin != address(0));
        vm.assume(vault != address(0));

        OracleRegistry registry = createRegistry(admin);

        assertEq(address(registry.getOracle(vault)), address(0));
    }

    /// Test that getOracle returns correct oracle for registered vault.
    function testGetOracleRegistered(address admin, address vault, address oracle) external {
        vm.assume(admin != address(0));
        vm.assume(vault != address(0));
        vm.assume(oracle != address(0));

        OracleRegistry registry = createRegistry(admin);

        vm.prank(admin);
        registry.setOracle(vault, AggregatorV2V3Interface(oracle));

        assertEq(address(registry.getOracle(vault)), oracle);
    }
}

contract OracleRegistrySetAdminTest is OracleRegistryTest {
    event AdminSet(address indexed oldAdmin, address indexed newAdmin);

    /// Test that only admin can call setAdmin.
    function testSetAdminOnlyAdmin(address admin, address notAdmin, address newAdmin) external {
        vm.assume(admin != address(0));
        vm.assume(notAdmin != admin);
        vm.assume(newAdmin != address(0));

        OracleRegistry registry = createRegistry(admin);

        vm.prank(notAdmin);
        vm.expectRevert(abi.encodeWithSelector(OnlyAdmin.selector));
        registry.setAdmin(newAdmin);
    }

    /// Test that zero address reverts.
    function testSetAdminZeroAddress(address admin) external {
        vm.assume(admin != address(0));

        OracleRegistry registry = createRegistry(admin);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ZeroAdmin.selector));
        registry.setAdmin(address(0));
    }

    /// Test successful admin change.
    function testSetAdminSuccess(address admin, address newAdmin) external {
        vm.assume(admin != address(0));
        vm.assume(newAdmin != address(0));

        OracleRegistry registry = createRegistry(admin);

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit AdminSet(admin, newAdmin);
        registry.setAdmin(newAdmin);

        assertEq(registry.admin(), newAdmin);
    }

    /// Test that new admin can perform admin actions.
    function testSetAdminNewAdminCanAct(address admin, address newAdmin, address vault, address oracle) external {
        vm.assume(admin != address(0));
        vm.assume(newAdmin != address(0));
        vm.assume(admin != newAdmin);
        vm.assume(vault != address(0));
        vm.assume(oracle != address(0));

        OracleRegistry registry = createRegistry(admin);

        vm.prank(admin);
        registry.setAdmin(newAdmin);

        // Old admin should no longer be able to act
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(OnlyAdmin.selector));
        registry.setOracle(vault, AggregatorV2V3Interface(oracle));

        // New admin should be able to act
        vm.prank(newAdmin);
        registry.setOracle(vault, AggregatorV2V3Interface(oracle));

        assertEq(address(registry.getOracle(vault)), oracle);
    }
}
