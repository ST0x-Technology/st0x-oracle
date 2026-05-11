// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test, Vm} from "forge-std-1.16.1/src/Test.sol";
import {
    MorphoProtocolAdapter,
    MorphoProtocolAdapterConfig,
    OnlyAdmin,
    ZeroAdmin,
    ZeroRegistry,
    ZeroVault,
    OracleNotFound,
    NonPositivePrice,
    UnexpectedOracleDecimals
} from "src/concrete/protocol/MorphoProtocolAdapter.sol";
import {
    MorphoProtocolAdapterBeaconSetDeployer,
    MorphoProtocolAdapterBeaconSetDeployerConfig
} from "src/concrete/deploy/MorphoProtocolAdapterBeaconSetDeployer.sol";
import {OracleRegistry} from "src/concrete/registry/OracleRegistry.sol";
import {
    OracleRegistryBeaconSetDeployer,
    OracleRegistryBeaconSetDeployerConfig
} from "src/concrete/deploy/OracleRegistryBeaconSetDeployer.sol";
import {AggregatorV2V3Interface} from "src/interface/IAggregatorV2V3.sol";

contract MorphoProtocolAdapterTest is Test {
    MorphoProtocolAdapter internal immutable I_IMPLEMENTATION;
    MorphoProtocolAdapterBeaconSetDeployer internal immutable I_DEPLOYER;
    OracleRegistry internal immutable I_REGISTRY_IMPLEMENTATION;
    OracleRegistryBeaconSetDeployer internal immutable I_REGISTRY_DEPLOYER;

    constructor() {
        I_IMPLEMENTATION = new MorphoProtocolAdapter();
        I_DEPLOYER = new MorphoProtocolAdapterBeaconSetDeployer(
            MorphoProtocolAdapterBeaconSetDeployerConfig({
                initialOwner: address(this), initialMorphoProtocolAdapterImplementation: address(I_IMPLEMENTATION)
            })
        );
        I_REGISTRY_IMPLEMENTATION = new OracleRegistry();
        I_REGISTRY_DEPLOYER = new OracleRegistryBeaconSetDeployer(
            OracleRegistryBeaconSetDeployerConfig({
                initialOwner: address(this), initialOracleRegistryImplementation: address(I_REGISTRY_IMPLEMENTATION)
            })
        );
    }

    function _createRegistry(address admin) internal returns (OracleRegistry) {
        vm.prank(admin);
        return I_REGISTRY_DEPLOYER.newOracleRegistry();
    }

    /// Test that initialization with zero registry reverts.
    function testInitializeZeroRegistry(address vault, address admin) external {
        vm.assume(vault != address(0));
        vm.expectRevert(abi.encodeWithSelector(ZeroRegistry.selector));
        I_DEPLOYER.newMorphoProtocolAdapter(OracleRegistry(address(0)), vault, admin);
    }

    /// Test that initialization with zero vault reverts.
    function testInitializeZeroVault(address registryAdmin, address admin) external {
        vm.assume(registryAdmin != address(0));
        OracleRegistry registry = _createRegistry(registryAdmin);
        vm.expectRevert(abi.encodeWithSelector(ZeroVault.selector));
        I_DEPLOYER.newMorphoProtocolAdapter(registry, address(0), admin);
    }

    /// Test that initialization with zero admin reverts.
    function testInitializeZeroAdmin(address registryAdmin, address vault) external {
        vm.assume(registryAdmin != address(0));
        vm.assume(vault != address(0));
        OracleRegistry registry = _createRegistry(registryAdmin);
        vm.expectRevert(abi.encodeWithSelector(ZeroAdmin.selector));
        I_DEPLOYER.newMorphoProtocolAdapter(registry, vault, address(0));
    }

    /// Test successful initialization.
    function testInitializeSuccess(address registryAdmin, address vault, address admin) external {
        vm.assume(registryAdmin != address(0));
        vm.assume(vault != address(0));
        vm.assume(admin != address(0));

        OracleRegistry registry = _createRegistry(registryAdmin);
        MorphoProtocolAdapter adapter = I_DEPLOYER.newMorphoProtocolAdapter(registry, vault, admin);

        assertEq(address(adapter.registry()), address(registry));
        assertEq(adapter.vault(), vault);
        assertEq(adapter.admin(), admin);
    }

    /// Test that initialization emits event.
    function testInitializeEvent(address registryAdmin, address vault, address admin) external {
        vm.assume(registryAdmin != address(0));
        vm.assume(vault != address(0));
        vm.assume(admin != address(0));

        OracleRegistry registry = _createRegistry(registryAdmin);

        vm.recordLogs();
        I_DEPLOYER.newMorphoProtocolAdapter(registry, vault, admin);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool eventFound = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("MorphoProtocolAdapterInitialized(address,(address,address,address))")) {
                eventFound = true;
                break;
            }
        }
        assertTrue(eventFound, "MorphoProtocolAdapterInitialized event not found");
    }

    /// Test setRegistry by admin.
    function testSetRegistry(address registryAdmin, address vault, address admin) external {
        vm.assume(registryAdmin != address(0));
        vm.assume(vault != address(0));
        vm.assume(admin != address(0));

        OracleRegistry registry1 = _createRegistry(registryAdmin);
        OracleRegistry registry2 = _createRegistry(registryAdmin);

        MorphoProtocolAdapter adapter = I_DEPLOYER.newMorphoProtocolAdapter(registry1, vault, admin);

        vm.expectEmit();
        emit MorphoProtocolAdapter.RegistrySet(address(registry1), address(registry2));
        vm.prank(admin);
        adapter.setRegistry(registry2);

        assertEq(address(adapter.registry()), address(registry2));
    }

    /// Test setRegistry reverts for non-admin.
    function testSetRegistryOnlyAdmin(address registryAdmin, address vault, address admin, address nonAdmin) external {
        vm.assume(registryAdmin != address(0));
        vm.assume(vault != address(0));
        vm.assume(admin != address(0));
        vm.assume(nonAdmin != admin);

        OracleRegistry registry = _createRegistry(registryAdmin);
        MorphoProtocolAdapter adapter = I_DEPLOYER.newMorphoProtocolAdapter(registry, vault, admin);

        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(OnlyAdmin.selector));
        adapter.setRegistry(registry);
    }

    /// Test setRegistry with zero address reverts.
    function testSetRegistryZeroAddress(address registryAdmin, address vault, address admin) external {
        vm.assume(registryAdmin != address(0));
        vm.assume(vault != address(0));
        vm.assume(admin != address(0));

        OracleRegistry registry = _createRegistry(registryAdmin);
        MorphoProtocolAdapter adapter = I_DEPLOYER.newMorphoProtocolAdapter(registry, vault, admin);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ZeroRegistry.selector));
        adapter.setRegistry(OracleRegistry(address(0)));
    }

    /// Test price() reverts when oracle not found in registry.
    function testPriceOracleNotFound(address registryAdmin, address vault, address admin) external {
        vm.assume(registryAdmin != address(0));
        vm.assume(vault != address(0));
        vm.assume(admin != address(0));

        OracleRegistry registry = _createRegistry(registryAdmin);
        MorphoProtocolAdapter adapter = I_DEPLOYER.newMorphoProtocolAdapter(registry, vault, admin);

        vm.expectRevert(abi.encodeWithSelector(OracleNotFound.selector));
        adapter.price();
    }

    /// Helper: mock the oracle's `decimals()` to return 8 so the
    /// `EXPECTED_ORACLE_DECIMALS` check in `price()` passes.
    function _mockDecimals(address mockOracle, uint8 d) internal {
        vm.mockCall(mockOracle, abi.encodeWithSelector(AggregatorV2V3Interface.decimals.selector), abi.encode(d));
    }

    /// Test price() scales 8 decimals to 36 decimals correctly.
    function testPriceScaling(address admin) external {
        vm.assume(admin != address(0));

        address vault = address(uint160(uint256(keccak256("vault"))));
        address mockOracle = address(uint160(uint256(keccak256("mock.oracle"))));

        // Create registry and register oracle
        OracleRegistry registry = _createRegistry(admin);
        vm.prank(admin);
        registry.setOracle(vault, AggregatorV2V3Interface(mockOracle));

        _mockDecimals(mockOracle, 8);
        // Mock a price of 100.00000000 (100 USD at 8 decimals)
        int256 mockPrice = 100e8;
        vm.mockCall(
            mockOracle, abi.encodeWithSelector(AggregatorV2V3Interface.latestAnswer.selector), abi.encode(mockPrice)
        );

        MorphoProtocolAdapter adapter = I_DEPLOYER.newMorphoProtocolAdapter(registry, vault, admin);

        uint256 morphoPrice = adapter.price();
        // 100e8 * 1e28 = 100e36
        assertEq(morphoPrice, 100e36);
    }

    /// Test price() with various values.
    function testPriceScalingFuzz(address admin, int256 mockPrice) external {
        vm.assume(admin != address(0));
        // Price must be positive and not overflow when multiplied by 1e28.
        mockPrice = bound(mockPrice, 1, int256(type(uint256).max / 1e28));

        address vault = address(uint160(uint256(keccak256("vault"))));
        address mockOracle = address(uint160(uint256(keccak256("mock.oracle"))));

        // Create registry and register oracle
        OracleRegistry registry = _createRegistry(admin);
        vm.prank(admin);
        registry.setOracle(vault, AggregatorV2V3Interface(mockOracle));

        _mockDecimals(mockOracle, 8);
        vm.mockCall(
            mockOracle, abi.encodeWithSelector(AggregatorV2V3Interface.latestAnswer.selector), abi.encode(mockPrice)
        );

        MorphoProtocolAdapter adapter = I_DEPLOYER.newMorphoProtocolAdapter(registry, vault, admin);

        uint256 morphoPrice = adapter.price();
        assertEq(morphoPrice, uint256(mockPrice) * 1e28);
    }

    /// Test price() reverts on zero price.
    function testPriceRevertsOnZero(address admin) external {
        vm.assume(admin != address(0));

        address vault = address(uint160(uint256(keccak256("vault"))));
        address mockOracle = address(uint160(uint256(keccak256("mock.oracle"))));

        // Create registry and register oracle
        OracleRegistry registry = _createRegistry(admin);
        vm.prank(admin);
        registry.setOracle(vault, AggregatorV2V3Interface(mockOracle));

        _mockDecimals(mockOracle, 8);
        vm.mockCall(
            mockOracle, abi.encodeWithSelector(AggregatorV2V3Interface.latestAnswer.selector), abi.encode(int256(0))
        );

        MorphoProtocolAdapter adapter = I_DEPLOYER.newMorphoProtocolAdapter(registry, vault, admin);

        vm.expectRevert(abi.encodeWithSelector(NonPositivePrice.selector));
        adapter.price();
    }

    /// Test price() reverts on negative price.
    function testPriceRevertsOnNegative(address admin, int256 negativePrice) external {
        vm.assume(admin != address(0));
        negativePrice = bound(negativePrice, type(int256).min, -1);

        address vault = address(uint160(uint256(keccak256("vault"))));
        address mockOracle = address(uint160(uint256(keccak256("mock.oracle"))));

        // Create registry and register oracle
        OracleRegistry registry = _createRegistry(admin);
        vm.prank(admin);
        registry.setOracle(vault, AggregatorV2V3Interface(mockOracle));

        _mockDecimals(mockOracle, 8);
        vm.mockCall(
            mockOracle, abi.encodeWithSelector(AggregatorV2V3Interface.latestAnswer.selector), abi.encode(negativePrice)
        );

        MorphoProtocolAdapter adapter = I_DEPLOYER.newMorphoProtocolAdapter(registry, vault, admin);

        vm.expectRevert(abi.encodeWithSelector(NonPositivePrice.selector));
        adapter.price();
    }

    /// `price()` must revert when the registered oracle reports any decimals
    /// value other than 8 — preventing silent `10^N`-magnitude mis-pricing if
    /// the registry is repointed to e.g. an 18-decimal Chainlink feed.
    function testPriceRevertsOnNonEightDecimals(address admin, uint8 wrongDecimals) external {
        vm.assume(admin != address(0));
        vm.assume(wrongDecimals != 8);

        address vault = address(uint160(uint256(keccak256("vault"))));
        address mockOracle = address(uint160(uint256(keccak256("mock.oracle"))));

        OracleRegistry registry = _createRegistry(admin);
        vm.prank(admin);
        registry.setOracle(vault, AggregatorV2V3Interface(mockOracle));

        _mockDecimals(mockOracle, wrongDecimals);
        // Set a non-zero answer so we can prove the decimals check fires
        // BEFORE the latestAnswer/NonPositivePrice path.
        vm.mockCall(
            mockOracle, abi.encodeWithSelector(AggregatorV2V3Interface.latestAnswer.selector), abi.encode(int256(100e8))
        );

        MorphoProtocolAdapter adapter = I_DEPLOYER.newMorphoProtocolAdapter(registry, vault, admin);

        vm.expectRevert(abi.encodeWithSelector(UnexpectedOracleDecimals.selector, wrongDecimals, uint8(8)));
        adapter.price();
    }

    /// The decimals check happens BEFORE `latestAnswer()` is called — verify
    /// by mocking `latestAnswer` to revert and confirming the decimals error
    /// surfaces first (not the latestAnswer revert).
    function testPriceDecimalsCheckRunsBeforeAnswer(address admin, uint8 wrongDecimals) external {
        vm.assume(admin != address(0));
        vm.assume(wrongDecimals != 8);

        address vault = address(uint160(uint256(keccak256("vault"))));
        address mockOracle = address(uint160(uint256(keccak256("mock.oracle"))));

        OracleRegistry registry = _createRegistry(admin);
        vm.prank(admin);
        registry.setOracle(vault, AggregatorV2V3Interface(mockOracle));

        _mockDecimals(mockOracle, wrongDecimals);
        vm.mockCallRevert(
            mockOracle, abi.encodeWithSelector(AggregatorV2V3Interface.latestAnswer.selector), "should not reach"
        );

        MorphoProtocolAdapter adapter = I_DEPLOYER.newMorphoProtocolAdapter(registry, vault, admin);

        vm.expectRevert(abi.encodeWithSelector(UnexpectedOracleDecimals.selector, wrongDecimals, uint8(8)));
        adapter.price();
    }

    /// Test setAdmin by admin.
    function testSetAdmin(address registryAdmin, address vault, address admin, address newAdmin) external {
        vm.assume(registryAdmin != address(0));
        vm.assume(vault != address(0));
        vm.assume(admin != address(0));
        vm.assume(newAdmin != address(0));

        OracleRegistry registry = _createRegistry(registryAdmin);
        MorphoProtocolAdapter adapter = I_DEPLOYER.newMorphoProtocolAdapter(registry, vault, admin);

        vm.expectEmit(true, true, true, true);
        emit MorphoProtocolAdapter.AdminSet(admin, newAdmin);
        vm.prank(admin);
        adapter.setAdmin(newAdmin);

        assertEq(adapter.admin(), newAdmin);
    }

    /// Test setAdmin reverts for non-admin.
    function testSetAdminOnlyAdmin(address registryAdmin, address vault, address admin, address nonAdmin) external {
        vm.assume(registryAdmin != address(0));
        vm.assume(vault != address(0));
        vm.assume(admin != address(0));
        vm.assume(nonAdmin != admin);

        OracleRegistry registry = _createRegistry(registryAdmin);
        MorphoProtocolAdapter adapter = I_DEPLOYER.newMorphoProtocolAdapter(registry, vault, admin);

        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(OnlyAdmin.selector));
        adapter.setAdmin(address(1));
    }

    /// Test setAdmin with zero address reverts.
    function testSetAdminZeroAddress(address registryAdmin, address vault, address admin) external {
        vm.assume(registryAdmin != address(0));
        vm.assume(vault != address(0));
        vm.assume(admin != address(0));

        OracleRegistry registry = _createRegistry(registryAdmin);
        MorphoProtocolAdapter adapter = I_DEPLOYER.newMorphoProtocolAdapter(registry, vault, admin);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ZeroAdmin.selector));
        adapter.setAdmin(address(0));
    }
}
