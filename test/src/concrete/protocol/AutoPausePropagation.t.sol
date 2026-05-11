// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPyth} from "pyth-sdk/IPyth.sol";
import {PythStructs} from "pyth-sdk/PythStructs.sol";
import {AggregatorV2V3Interface} from "src/interface/IAggregatorV2V3.sol";
import {ICorporateActionsV1, ACTION_TYPE_STOCK_SPLIT_V1} from "st0x.deploy/src/interface/ICorporateActionsV1.sol";
import {CompletionFilter, NODE_NONE} from "st0x.deploy/src/lib/LibCorporateActionNode.sol";
import {
    CorporateActionPauseConfig,
    OraclePausedCorporateAction,
    OraclePausedManual
} from "src/abstract/BasePythOracleAdapter.sol";
import {PythOracleAdapter, PythOracleAdapterConfig} from "src/concrete/oracle/PythOracleAdapter.sol";
import {
    PythOracleAdapterBeaconSetDeployer,
    PythOracleAdapterBeaconSetDeployerConfig
} from "src/concrete/deploy/PythOracleAdapterBeaconSetDeployer.sol";
import {OracleRegistry} from "src/concrete/registry/OracleRegistry.sol";
import {
    OracleRegistryBeaconSetDeployer,
    OracleRegistryBeaconSetDeployerConfig
} from "src/concrete/deploy/OracleRegistryBeaconSetDeployer.sol";
import {PassthroughProtocolAdapter} from "src/concrete/protocol/PassthroughProtocolAdapter.sol";
import {
    PassthroughProtocolAdapterBeaconSetDeployer,
    PassthroughProtocolAdapterBeaconSetDeployerConfig
} from "src/concrete/deploy/PassthroughProtocolAdapterBeaconSetDeployer.sol";
import {MorphoProtocolAdapter} from "src/concrete/protocol/MorphoProtocolAdapter.sol";
import {
    MorphoProtocolAdapterBeaconSetDeployer,
    MorphoProtocolAdapterBeaconSetDeployerConfig
} from "src/concrete/deploy/MorphoProtocolAdapterBeaconSetDeployer.sol";

/// @dev Pyth contract address on Base (from `LibPyth`). We mock at this
/// address so the oracle's runtime call resolves regardless of fork state.
address constant PYTH_BASE = 0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a;

uint256 constant BASE_CHAIN_ID = 8453;

/// @dev Arbitrary mock Pyth feed ID — responses are vm.mockCall'd.
bytes32 constant MOCK_PRICE_ID = bytes32(uint256(0xd00dface));

/// @dev Same shape as the auto-pause test; one place to maintain so the two
/// fixtures stay coherent.
contract MockCorporateActions is ICorporateActionsV1 {
    uint64 internal pendingEffectiveTime;
    uint256 internal pendingActionType;
    uint64 internal completedEffectiveTime;
    uint256 internal completedActionType;

    function setEarliestPending(uint256 actionType, uint64 effectiveTime) external {
        pendingActionType = actionType;
        pendingEffectiveTime = effectiveTime;
    }

    function setLatestCompleted(uint256 actionType, uint64 effectiveTime) external {
        completedActionType = actionType;
        completedEffectiveTime = effectiveTime;
    }

    function earliestActionOfType(uint256 mask, CompletionFilter filter)
        external
        view
        override
        returns (uint256, uint256, uint64)
    {
        if (filter != CompletionFilter.PENDING) revert("mock: only PENDING expected");
        if (pendingEffectiveTime == 0) return (NODE_NONE, 0, 0);
        if (pendingActionType & mask == 0) return (NODE_NONE, 0, 0);
        return (1, pendingActionType, pendingEffectiveTime);
    }

    function latestActionOfType(uint256 mask, CompletionFilter filter)
        external
        view
        override
        returns (uint256, uint256, uint64)
    {
        if (filter != CompletionFilter.COMPLETED) revert("mock: only COMPLETED expected");
        if (completedEffectiveTime == 0) return (NODE_NONE, 0, 0);
        if (completedActionType & mask == 0) return (NODE_NONE, 0, 0);
        return (1, completedActionType, completedEffectiveTime);
    }

    function scheduleCorporateAction(bytes32, uint64, bytes calldata) external pure override returns (uint256) {
        revert("mock: not implemented");
    }

    function cancelCorporateAction(uint256) external pure override {
        revert("mock: not implemented");
    }

    function completedActionCount() external pure override returns (uint256) {
        revert("mock: not implemented");
    }

    function nextOfType(uint256, uint256, CompletionFilter) external pure override returns (uint256, uint256, uint64) {
        revert("mock: not implemented");
    }

    function prevOfType(uint256, uint256, CompletionFilter) external pure override returns (uint256, uint256, uint64) {
        revert("mock: not implemented");
    }

    function getActionParameters(uint256) external pure override returns (bytes memory) {
        revert("mock: not implemented");
    }
}

/// @title AutoPausePropagationTest
/// @notice End-to-end check that an auto-pause revert from the oracle layer
/// propagates cleanly through the registry and into both protocol adapter
/// types (Passthrough for Aave/Compound, Morpho).
///
/// This is a unit-test variant of RAI-321's "fork tests on Base against a real
/// st0x.deploy vault" — we mock `ICorporateActionsV1` rather than scheduling a
/// real action, because no production vault has the new corporate-actions
/// facet deployed yet (RAI-327 / RAI-328 will). The chain wiring exercised
/// here is the same regardless of where the underlying revert originates.
contract AutoPausePropagationTest is Test {
    PythOracleAdapterBeaconSetDeployer internal oracleDeployer;
    OracleRegistryBeaconSetDeployer internal registryDeployer;
    PassthroughProtocolAdapterBeaconSetDeployer internal passthroughDeployer;
    MorphoProtocolAdapterBeaconSetDeployer internal morphoDeployer;

    OracleRegistry internal registry;
    PythOracleAdapter internal oracle;
    PassthroughProtocolAdapter internal passthroughAdapter;
    MorphoProtocolAdapter internal morphoAdapter;
    MockCorporateActions internal corporateActions;

    address internal mockVault;

    uint64 internal constant PAUSE_BEFORE = 3600;
    uint64 internal constant PAUSE_AFTER = 3600;

    function setUp() external {
        vm.chainId(BASE_CHAIN_ID);
        vm.warp(1_700_000_000);

        oracleDeployer = new PythOracleAdapterBeaconSetDeployer(
            PythOracleAdapterBeaconSetDeployerConfig({
                initialOwner: address(this), initialPythOracleAdapterImplementation: address(new PythOracleAdapter())
            })
        );
        registryDeployer = new OracleRegistryBeaconSetDeployer(
            OracleRegistryBeaconSetDeployerConfig({
                initialOwner: address(this), initialOracleRegistryImplementation: address(new OracleRegistry())
            })
        );
        passthroughDeployer = new PassthroughProtocolAdapterBeaconSetDeployer(
            PassthroughProtocolAdapterBeaconSetDeployerConfig({
                initialOwner: address(this),
                initialPassthroughProtocolAdapterImplementation: address(new PassthroughProtocolAdapter())
            })
        );
        morphoDeployer = new MorphoProtocolAdapterBeaconSetDeployer(
            MorphoProtocolAdapterBeaconSetDeployerConfig({
                initialOwner: address(this),
                initialMorphoProtocolAdapterImplementation: address(new MorphoProtocolAdapter())
            })
        );

        registry = registryDeployer.newOracleRegistry();
        corporateActions = new MockCorporateActions();
        mockVault = address(uint160(uint256(keccak256("vault.propagation"))));

        // Vault and Pyth mocks — these don't change between tests.
        vm.mockCall(mockVault, abi.encodeWithSelector(IERC4626.totalAssets.selector), abi.encode(1000e18));
        vm.mockCall(mockVault, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(1000e18));
        PythStructs.Price memory price =
            PythStructs.Price({price: 100e8, conf: 1e6, expo: -8, publishTime: uint64(block.timestamp)});
        vm.mockCall(PYTH_BASE, abi.encodeWithSelector(IPyth.getPriceNoOlderThan.selector), abi.encode(price));

        oracle = oracleDeployer.newPythOracleAdapter(
            PythOracleAdapterConfig({
                vault: mockVault,
                priceId: MOCK_PRICE_ID,
                maxAge: 3600,
                admin: address(this),
                pauseConfig: CorporateActionPauseConfig({
                    corporateActionsVault: address(corporateActions),
                    actionTypeMask: ACTION_TYPE_STOCK_SPLIT_V1,
                    pauseTimeBefore: PAUSE_BEFORE,
                    pauseTimeAfter: PAUSE_AFTER
                })
            })
        );

        passthroughAdapter = passthroughDeployer.newPassthroughProtocolAdapter(registry, mockVault, address(this));
        morphoAdapter = morphoDeployer.newMorphoProtocolAdapter(registry, mockVault, address(this));

        registry.setOracle(mockVault, AggregatorV2V3Interface(address(oracle)));
    }

    /// @notice Sanity: with no scheduled action the chain returns a price.
    function testHappyPathPropagatesPrice() external view {
        int256 answer = passthroughAdapter.latestAnswer();
        assertGt(answer, 0);
        uint256 morphoPrice = morphoAdapter.price();
        assertGt(morphoPrice, 0);
    }

    /// @notice Pending action in window → `PassthroughProtocolAdapter`
    /// surfaces the original `OraclePausedCorporateAction(effectiveTime)`
    /// selector unchanged.
    function testPassthroughPropagatesAutoPauseRevert() external {
        uint64 effectiveTime = uint64(block.timestamp + PAUSE_BEFORE / 2);
        corporateActions.setEarliestPending(ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);
        vm.expectRevert(abi.encodeWithSelector(OraclePausedCorporateAction.selector, effectiveTime));
        passthroughAdapter.latestAnswer();
        vm.expectRevert(abi.encodeWithSelector(OraclePausedCorporateAction.selector, effectiveTime));
        passthroughAdapter.latestRoundData();
    }

    /// @notice Same condition through `MorphoProtocolAdapter.price()` —
    /// distinct selector still propagates.
    function testMorphoPropagatesAutoPauseRevert() external {
        uint64 effectiveTime = uint64(block.timestamp + PAUSE_BEFORE / 2);
        corporateActions.setEarliestPending(ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);
        vm.expectRevert(abi.encodeWithSelector(OraclePausedCorporateAction.selector, effectiveTime));
        morphoAdapter.price();
    }

    /// @notice Manual pause precedence is preserved through the protocol
    /// adapter chain — even with an auto-pause condition also armed.
    function testManualPausePropagatesThroughChain() external {
        corporateActions.setEarliestPending(ACTION_TYPE_STOCK_SPLIT_V1, uint64(block.timestamp + PAUSE_BEFORE / 2));
        oracle.setPaused(true);
        vm.expectRevert(abi.encodeWithSelector(OraclePausedManual.selector));
        passthroughAdapter.latestAnswer();
        vm.expectRevert(abi.encodeWithSelector(OraclePausedManual.selector));
        morphoAdapter.price();
    }
}
