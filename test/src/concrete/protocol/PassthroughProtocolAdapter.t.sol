// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test, Vm} from "forge-std/Test.sol";
import {
    PassthroughProtocolAdapter,
    PassthroughProtocolAdapterConfig,
    OnlyAdmin,
    ZeroAdmin,
    ZeroRegistry,
    ZeroVault,
    OracleNotFound
} from "src/concrete/protocol/PassthroughProtocolAdapter.sol";
import {
    PassthroughProtocolAdapterBeaconSetDeployer,
    PassthroughProtocolAdapterBeaconSetDeployerConfig
} from "src/concrete/deploy/PassthroughProtocolAdapterBeaconSetDeployer.sol";
import {OracleRegistry} from "src/concrete/registry/OracleRegistry.sol";
import {
    OracleRegistryBeaconSetDeployer,
    OracleRegistryBeaconSetDeployerConfig
} from "src/concrete/deploy/OracleRegistryBeaconSetDeployer.sol";
import {AggregatorV2V3Interface} from "src/interface/IAggregatorV2V3.sol";

contract PassthroughProtocolAdapterTest is Test {
    PassthroughProtocolAdapter internal immutable I_IMPLEMENTATION;
    PassthroughProtocolAdapterBeaconSetDeployer internal immutable I_DEPLOYER;
    OracleRegistry internal immutable I_REGISTRY_IMPLEMENTATION;
    OracleRegistryBeaconSetDeployer internal immutable I_REGISTRY_DEPLOYER;

    constructor() {
        I_IMPLEMENTATION = new PassthroughProtocolAdapter();
        I_DEPLOYER = new PassthroughProtocolAdapterBeaconSetDeployer(
            PassthroughProtocolAdapterBeaconSetDeployerConfig({
                initialOwner: address(this), initialPassthroughProtocolAdapterImplementation: address(I_IMPLEMENTATION)
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
        I_DEPLOYER.newPassthroughProtocolAdapter(OracleRegistry(address(0)), vault, admin);
    }

    /// Test that initialization with zero vault reverts.
    function testInitializeZeroVault(address registryAdmin, address admin) external {
        vm.assume(registryAdmin != address(0));
        vm.assume(admin != address(0));
        OracleRegistry registry = _createRegistry(registryAdmin);
        vm.expectRevert(abi.encodeWithSelector(ZeroVault.selector));
        I_DEPLOYER.newPassthroughProtocolAdapter(registry, address(0), admin);
    }

    /// Test that initialization with zero admin reverts.
    function testInitializeZeroAdmin(address registryAdmin, address vault) external {
        vm.assume(registryAdmin != address(0));
        vm.assume(vault != address(0));
        OracleRegistry registry = _createRegistry(registryAdmin);
        vm.expectRevert(abi.encodeWithSelector(ZeroAdmin.selector));
        I_DEPLOYER.newPassthroughProtocolAdapter(registry, vault, address(0));
    }

    /// Test successful initialization.
    function testInitializeSuccess(address registryAdmin, address vault, address admin) external {
        vm.assume(registryAdmin != address(0));
        vm.assume(vault != address(0));
        vm.assume(admin != address(0));

        OracleRegistry registry = _createRegistry(registryAdmin);
        PassthroughProtocolAdapter adapter = I_DEPLOYER.newPassthroughProtocolAdapter(registry, vault, admin);

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
        I_DEPLOYER.newPassthroughProtocolAdapter(registry, vault, admin);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool eventFound = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].topics[0]
                    == keccak256("PassthroughProtocolAdapterInitialized(address,(address,address,address))")
            ) {
                eventFound = true;
                break;
            }
        }
        assertTrue(eventFound, "PassthroughProtocolAdapterInitialized event not found");
    }

    /// Test setRegistry by admin.
    function testSetRegistry(address registryAdmin, address vault, address admin) external {
        vm.assume(registryAdmin != address(0));
        vm.assume(vault != address(0));
        vm.assume(admin != address(0));

        OracleRegistry registry1 = _createRegistry(registryAdmin);
        OracleRegistry registry2 = _createRegistry(registryAdmin);

        PassthroughProtocolAdapter adapter = I_DEPLOYER.newPassthroughProtocolAdapter(registry1, vault, admin);

        vm.expectEmit();
        emit PassthroughProtocolAdapter.RegistrySet(address(registry1), address(registry2));
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
        PassthroughProtocolAdapter adapter = I_DEPLOYER.newPassthroughProtocolAdapter(registry, vault, admin);

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
        PassthroughProtocolAdapter adapter = I_DEPLOYER.newPassthroughProtocolAdapter(registry, vault, admin);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ZeroRegistry.selector));
        adapter.setRegistry(OracleRegistry(address(0)));
    }

    /// Test setAdmin by admin.
    function testSetAdmin(address registryAdmin, address vault, address admin, address newAdmin) external {
        vm.assume(registryAdmin != address(0));
        vm.assume(vault != address(0));
        vm.assume(admin != address(0));
        vm.assume(newAdmin != address(0));

        OracleRegistry registry = _createRegistry(registryAdmin);
        PassthroughProtocolAdapter adapter = I_DEPLOYER.newPassthroughProtocolAdapter(registry, vault, admin);

        vm.expectEmit(true, true, true, true);
        emit PassthroughProtocolAdapter.AdminSet(admin, newAdmin);
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
        PassthroughProtocolAdapter adapter = I_DEPLOYER.newPassthroughProtocolAdapter(registry, vault, admin);

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
        PassthroughProtocolAdapter adapter = I_DEPLOYER.newPassthroughProtocolAdapter(registry, vault, admin);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ZeroAdmin.selector));
        adapter.setAdmin(address(0));
    }

    /// Test passthrough functions revert when oracle not found.
    function testOracleNotFound(address registryAdmin, address vault, address admin) external {
        vm.assume(registryAdmin != address(0));
        vm.assume(vault != address(0));
        vm.assume(admin != address(0));

        OracleRegistry registry = _createRegistry(registryAdmin);
        PassthroughProtocolAdapter adapter = I_DEPLOYER.newPassthroughProtocolAdapter(registry, vault, admin);

        vm.expectRevert(abi.encodeWithSelector(OracleNotFound.selector));
        adapter.decimals();

        vm.expectRevert(abi.encodeWithSelector(OracleNotFound.selector));
        adapter.description();

        vm.expectRevert(abi.encodeWithSelector(OracleNotFound.selector));
        adapter.version();

        vm.expectRevert(abi.encodeWithSelector(OracleNotFound.selector));
        adapter.latestAnswer();

        vm.expectRevert(abi.encodeWithSelector(OracleNotFound.selector));
        adapter.latestRoundData();
    }

    /// Test passthrough of decimals.
    function testPassthroughDecimals(address admin) external {
        vm.assume(admin != address(0));

        address vault = address(uint160(uint256(keccak256("vault"))));
        address mockOracle = address(uint160(uint256(keccak256("mock.oracle"))));

        // Create registry and register oracle
        OracleRegistry registry = _createRegistry(admin);
        vm.prank(admin);
        registry.setOracle(vault, AggregatorV2V3Interface(mockOracle));

        vm.mockCall(mockOracle, abi.encodeWithSelector(AggregatorV2V3Interface.decimals.selector), abi.encode(uint8(8)));

        PassthroughProtocolAdapter adapter = I_DEPLOYER.newPassthroughProtocolAdapter(registry, vault, admin);

        assertEq(adapter.decimals(), 8);
    }

    /// Test passthrough of latestAnswer.
    ///
    /// `mockPrice` is intentionally unbounded — the Passthrough adapter is a
    /// literal forwarder by contract (no `NonPositivePrice` guard like
    /// MorphoProtocolAdapter). Asserting verbatim equality over the full
    /// int256 range pins that intent: if the contract were ever changed to
    /// reject non-positive inputs, this fuzz would catch the regression on
    /// the first negative/zero sample. See audit #68.
    function testPassthroughLatestAnswer(address admin, int256 mockPrice) external {
        vm.assume(admin != address(0));

        address vault = address(uint160(uint256(keccak256("vault"))));
        address mockOracle = address(uint160(uint256(keccak256("mock.oracle"))));

        // Create registry and register oracle
        OracleRegistry registry = _createRegistry(admin);
        vm.prank(admin);
        registry.setOracle(vault, AggregatorV2V3Interface(mockOracle));

        vm.mockCall(
            mockOracle, abi.encodeWithSelector(AggregatorV2V3Interface.latestAnswer.selector), abi.encode(mockPrice)
        );

        PassthroughProtocolAdapter adapter = I_DEPLOYER.newPassthroughProtocolAdapter(registry, vault, admin);

        assertEq(adapter.latestAnswer(), mockPrice, "Passthrough must forward verbatim");
    }

    /// Passthrough must forward the underlying oracle's revert verbatim for
    /// every `AggregatorV2V3Interface` accessor. The
    /// `OracleNotFound` path (registry miss) is already tested; this covers
    /// the registry-hit-but-oracle-reverts path. Closes audit #68.
    function testPassthroughForwardsUnderlyingRevert(address admin) external {
        vm.assume(admin != address(0));

        address vault = address(uint160(uint256(keccak256("vault"))));
        address mockOracle = address(uint160(uint256(keccak256("mock.oracle"))));

        OracleRegistry registry = _createRegistry(admin);
        vm.prank(admin);
        registry.setOracle(vault, AggregatorV2V3Interface(mockOracle));

        bytes memory revertData = bytes("stale");
        vm.mockCallRevert(mockOracle, abi.encodeWithSelector(AggregatorV2V3Interface.latestAnswer.selector), revertData);
        vm.mockCallRevert(
            mockOracle, abi.encodeWithSelector(AggregatorV2V3Interface.latestRoundData.selector), revertData
        );
        vm.mockCallRevert(mockOracle, abi.encodeWithSelector(AggregatorV2V3Interface.decimals.selector), revertData);
        vm.mockCallRevert(mockOracle, abi.encodeWithSelector(AggregatorV2V3Interface.description.selector), revertData);
        vm.mockCallRevert(mockOracle, abi.encodeWithSelector(AggregatorV2V3Interface.version.selector), revertData);

        PassthroughProtocolAdapter adapter = I_DEPLOYER.newPassthroughProtocolAdapter(registry, vault, admin);

        vm.expectRevert(revertData);
        adapter.latestAnswer();
        vm.expectRevert(revertData);
        adapter.latestRoundData();
        vm.expectRevert(revertData);
        adapter.decimals();
        vm.expectRevert(revertData);
        adapter.description();
        vm.expectRevert(revertData);
        adapter.version();
    }

    /// Test passthrough of latestRoundData.
    function testPassthroughLatestRoundData(address admin) external {
        vm.assume(admin != address(0));

        address vault = address(uint160(uint256(keccak256("vault"))));
        address mockOracle = address(uint160(uint256(keccak256("mock.oracle"))));

        // Create registry and register oracle
        OracleRegistry registry = _createRegistry(admin);
        vm.prank(admin);
        registry.setOracle(vault, AggregatorV2V3Interface(mockOracle));

        vm.mockCall(
            mockOracle,
            abi.encodeWithSelector(AggregatorV2V3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(10000e8), uint256(1000), uint256(1000), uint80(1))
        );

        PassthroughProtocolAdapter adapter = I_DEPLOYER.newPassthroughProtocolAdapter(registry, vault, admin);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            adapter.latestRoundData();

        assertEq(roundId, 1);
        assertEq(answer, 10000e8);
        assertEq(startedAt, 1000);
        assertEq(updatedAt, 1000);
        assertEq(answeredInRound, 1);
    }

    /// Test passthrough of description.
    function testPassthroughDescription(address admin) external {
        vm.assume(admin != address(0));

        address vault = address(uint160(uint256(keccak256("vault"))));
        address mockOracle = address(uint160(uint256(keccak256("mock.oracle"))));

        // Create registry and register oracle
        OracleRegistry registry = _createRegistry(admin);
        vm.prank(admin);
        registry.setOracle(vault, AggregatorV2V3Interface(mockOracle));

        vm.mockCall(mockOracle, abi.encodeWithSelector(AggregatorV2V3Interface.description.selector), abi.encode(""));

        PassthroughProtocolAdapter adapter = I_DEPLOYER.newPassthroughProtocolAdapter(registry, vault, admin);

        assertEq(adapter.description(), "");
    }

    /// Test passthrough of version.
    function testPassthroughVersion(address admin) external {
        vm.assume(admin != address(0));

        address vault = address(uint160(uint256(keccak256("vault"))));
        address mockOracle = address(uint160(uint256(keccak256("mock.oracle"))));

        // Create registry and register oracle
        OracleRegistry registry = _createRegistry(admin);
        vm.prank(admin);
        registry.setOracle(vault, AggregatorV2V3Interface(mockOracle));

        vm.mockCall(
            mockOracle, abi.encodeWithSelector(AggregatorV2V3Interface.version.selector), abi.encode(uint256(1))
        );

        PassthroughProtocolAdapter adapter = I_DEPLOYER.newPassthroughProtocolAdapter(registry, vault, admin);

        assertEq(adapter.version(), 1);
    }

    /// `getRoundData` is forwarded to the underlying oracle unchanged. A
    /// Chainlink-backed oracle would return historical round data here.
    function testPassthroughGetRoundData(address admin, uint80 requestedRound, int256 answer, uint256 ts) external {
        vm.assume(admin != address(0));

        address vault = address(uint160(uint256(keccak256("vault"))));
        address mockOracle = address(uint160(uint256(keccak256("mock.oracle"))));

        OracleRegistry registry = _createRegistry(admin);
        vm.prank(admin);
        registry.setOracle(vault, AggregatorV2V3Interface(mockOracle));

        vm.mockCall(
            mockOracle,
            abi.encodeWithSelector(AggregatorV2V3Interface.getRoundData.selector, requestedRound),
            abi.encode(uint80(7), answer, ts, ts, uint80(7))
        );

        PassthroughProtocolAdapter adapter = I_DEPLOYER.newPassthroughProtocolAdapter(registry, vault, admin);

        (uint80 roundId, int256 a, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            adapter.getRoundData(requestedRound);
        assertEq(roundId, 7);
        assertEq(a, answer);
        assertEq(startedAt, ts);
        assertEq(updatedAt, ts);
        assertEq(answeredInRound, 7);
    }

    /// When the underlying oracle is a Pyth-backed adapter, `getRoundData`
    /// reverts with `HistoricalRoundDataUnsupported(roundId)`. The Passthrough
    /// surfaces the revert (selector + payload) unchanged — integrators can
    /// disambiguate on the wire.
    function testPassthroughGetRoundDataRevertSelectorPropagates(address admin, uint80 requestedRound) external {
        vm.assume(admin != address(0));

        address vault = address(uint160(uint256(keccak256("vault"))));
        address mockOracle = address(uint160(uint256(keccak256("mock.oracle"))));

        OracleRegistry registry = _createRegistry(admin);
        vm.prank(admin);
        registry.setOracle(vault, AggregatorV2V3Interface(mockOracle));

        bytes memory revertData = abi.encodeWithSignature("HistoricalRoundDataUnsupported(uint80)", requestedRound);
        vm.mockCallRevert(
            mockOracle,
            abi.encodeWithSelector(AggregatorV2V3Interface.getRoundData.selector, requestedRound),
            revertData
        );

        PassthroughProtocolAdapter adapter = I_DEPLOYER.newPassthroughProtocolAdapter(registry, vault, admin);

        vm.expectRevert(revertData);
        adapter.getRoundData(requestedRound);
    }
}
