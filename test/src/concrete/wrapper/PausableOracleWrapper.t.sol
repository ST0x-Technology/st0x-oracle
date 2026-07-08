// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.1/src/Test.sol";
import {Initializable} from "@openzeppelin-contracts-5.6.1/proxy/utils/Initializable.sol";
import {ICLONEABLE_V2_SUCCESS, ICloneableV2} from "rain-factory-0.1.1/src/interface/ICloneableV2.sol";
import {AggregatorV2V3Interface} from "src/interface/IAggregatorV2V3.sol";
import {
    PausableOracleWrapper,
    PausableOracleWrapperConfig,
    CorporateActionPauseConfig,
    OraclePausedManual,
    OraclePausedCorporateAction,
    ZeroUpstream,
    ZeroAdmin,
    OnlyAdmin
} from "src/concrete/wrapper/PausableOracleWrapper.sol";
import {MockAggregatorV2V3} from "test/mocks/MockAggregatorV2V3.sol";
import {MockCorporateActions} from "test/mocks/MockCorporateActions.sol";
import {ACTION_TYPE_STOCK_SPLIT_V1} from "st0x-deploy-0.1.1/src/interface/ICorporateActionsV1.sol";
import {TestERC1967Proxy} from "test/mocks/TestERC1967Proxy.sol";

contract PausableOracleWrapperTest is Test {
    PausableOracleWrapper internal implementation;
    MockAggregatorV2V3 internal upstream;
    MockCorporateActions internal actions;

    address internal constant ADMIN = address(0xA11CE);
    address internal constant NON_ADMIN = address(0xB0B);

    uint64 internal constant PAUSE_BEFORE = 3600;
    uint64 internal constant PAUSE_AFTER = 3600;

    event PauseSet(bool isPaused);
    event AdminSet(address indexed oldAdmin, address indexed newAdmin);
    event PausableOracleWrapperInitialized(address indexed sender, PausableOracleWrapperConfig config);

    function setUp() public {
        implementation = new PausableOracleWrapper();
        upstream = new MockAggregatorV2V3();
        actions = new MockCorporateActions();
        // Warp far enough in that `block.timestamp - window` can't underflow.
        vm.warp(1_000_000);
    }

    function _deployUninit() internal returns (PausableOracleWrapper) {
        // Bare ERC1967 proxy is enough — beacon semantics are irrelevant for
        // unit tests of the implementation surface.
        TestERC1967Proxy proxy = new TestERC1967Proxy(address(implementation));
        return PausableOracleWrapper(address(proxy));
    }

    function _deployProxy(PausableOracleWrapperConfig memory config) internal returns (PausableOracleWrapper) {
        PausableOracleWrapper wrapper = _deployUninit();
        bytes32 ok = wrapper.initialize(abi.encode(config));
        assertEq(ok, ICLONEABLE_V2_SUCCESS);
        return wrapper;
    }

    function _disabledPauseConfig() internal pure returns (CorporateActionPauseConfig memory) {
        return CorporateActionPauseConfig({
            corporateActionsVault: address(0), actionTypeMask: 0, pauseTimeBefore: 0, pauseTimeAfter: 0
        });
    }

    function _enabledPauseConfig() internal view returns (CorporateActionPauseConfig memory) {
        return CorporateActionPauseConfig({
            corporateActionsVault: address(actions),
            actionTypeMask: ACTION_TYPE_STOCK_SPLIT_V1,
            pauseTimeBefore: PAUSE_BEFORE,
            pauseTimeAfter: PAUSE_AFTER
        });
    }

    function _defaultConfig() internal view returns (PausableOracleWrapperConfig memory) {
        return PausableOracleWrapperConfig({
            admin: ADMIN, upstream: AggregatorV2V3Interface(address(upstream)), pauseConfig: _disabledPauseConfig()
        });
    }

    function _enabledConfig() internal view returns (PausableOracleWrapperConfig memory) {
        return PausableOracleWrapperConfig({
            admin: ADMIN, upstream: AggregatorV2V3Interface(address(upstream)), pauseConfig: _enabledPauseConfig()
        });
    }

    // -------- Init validation --------

    function testInitRevertsZeroAdmin() external {
        PausableOracleWrapper wrapper = _deployUninit();
        PausableOracleWrapperConfig memory config = _defaultConfig();
        config.admin = address(0);
        vm.expectRevert(ZeroAdmin.selector);
        wrapper.initialize(abi.encode(config));
    }

    function testInitRevertsZeroUpstream() external {
        PausableOracleWrapper wrapper = _deployUninit();
        PausableOracleWrapperConfig memory config = _defaultConfig();
        config.upstream = AggregatorV2V3Interface(address(0));
        vm.expectRevert(ZeroUpstream.selector);
        wrapper.initialize(abi.encode(config));
    }

    // -------- Init success --------

    function testInitSuccessSetsStorageEmitsAndReturnsSuccess() external {
        PausableOracleWrapper wrapper = _deployUninit();
        PausableOracleWrapperConfig memory config = _enabledConfig();

        vm.expectEmit(true, false, false, true, address(wrapper));
        emit PausableOracleWrapperInitialized(address(this), config);

        bytes32 ok = wrapper.initialize(abi.encode(config));
        assertEq(ok, ICLONEABLE_V2_SUCCESS);
        assertEq(wrapper.admin(), ADMIN);
        assertEq(address(wrapper.upstream()), address(upstream));
        assertEq(wrapper.corporateActionsVault(), address(actions));
        assertEq(wrapper.actionTypeMask(), ACTION_TYPE_STOCK_SPLIT_V1);
        assertEq(wrapper.pauseTimeBefore(), PAUSE_BEFORE);
        assertEq(wrapper.pauseTimeAfter(), PAUSE_AFTER);
        assertEq(wrapper.paused(), false);
    }

    function testInitAllZeroPauseConfigStoresCleanly() external {
        PausableOracleWrapper wrapper = _deployProxy(_defaultConfig());
        assertEq(wrapper.corporateActionsVault(), address(0));
        assertEq(wrapper.actionTypeMask(), 0);
        assertEq(wrapper.pauseTimeBefore(), 0);
        assertEq(wrapper.pauseTimeAfter(), 0);
    }

    // -------- Typed overload reverts --------

    function testTypedInitializeAlwaysReverts() external {
        // The typed overload is `pure` and MUST always revert per
        // `ICloneableV2`. Call against the implementation directly so we
        // don't burn an initializer slot on a real proxy.
        PausableOracleWrapperConfig memory config = _defaultConfig();
        vm.expectRevert(ICloneableV2.InitializeSignatureFn.selector);
        implementation.initialize(config);
    }

    // -------- initializer modifier --------

    function testCannotInitializeTwice() external {
        PausableOracleWrapper wrapper = _deployProxy(_defaultConfig());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        wrapper.initialize(abi.encode(_defaultConfig()));
    }

    function testImplementationCannotBeInitialized() external {
        // Constructor calls `_disableInitializers()` — direct calls to the
        // implementation must revert.
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(abi.encode(_defaultConfig()));
    }

    // -------- Delegation (no pause) --------

    function testDecimalsDelegatesToUpstream() external {
        PausableOracleWrapper wrapper = _deployProxy(_defaultConfig());
        upstream.setDecimals(8);
        assertEq(wrapper.decimals(), 8);
        upstream.setDecimals(18);
        assertEq(wrapper.decimals(), 18);
    }

    function testDescriptionDelegatesToUpstream() external {
        PausableOracleWrapper wrapper = _deployProxy(_defaultConfig());
        upstream.setDescription("AAPL / USD");
        assertEq(wrapper.description(), "AAPL / USD");
    }

    function testVersionDelegatesToUpstream() external {
        PausableOracleWrapper wrapper = _deployProxy(_defaultConfig());
        upstream.setVersion(42);
        assertEq(wrapper.version(), 42);
    }

    function testLatestAnswerDelegatesToUpstream() external {
        PausableOracleWrapper wrapper = _deployProxy(_defaultConfig());
        upstream.setLatestAnswer(int256(123_456));
        assertEq(wrapper.latestAnswer(), int256(123_456));
    }

    function testLatestRoundDataDelegatesToUpstream() external {
        PausableOracleWrapper wrapper = _deployProxy(_defaultConfig());
        upstream.setLatestRoundData(uint80(7), int256(999), 100, 200, uint80(7));
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            wrapper.latestRoundData();
        assertEq(uint256(roundId), 7);
        assertEq(answer, int256(999));
        assertEq(startedAt, 100);
        assertEq(updatedAt, 200);
        assertEq(uint256(answeredInRound), 7);
    }

    function testGetRoundDataDelegatesToUpstream() external {
        PausableOracleWrapper wrapper = _deployProxy(_defaultConfig());
        upstream.setLatestRoundData(uint80(11), int256(555), 300, 400, uint80(11));
        upstream.setGetRoundDataReverts(false);
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            wrapper.getRoundData(uint80(11));
        assertEq(uint256(roundId), 11);
        assertEq(answer, int256(555));
        assertEq(startedAt, 300);
        assertEq(updatedAt, 400);
        assertEq(uint256(answeredInRound), 11);
    }

    // -------- Manual pause: access control --------

    function testSetPausedOnlyAdmin() external {
        PausableOracleWrapper wrapper = _deployProxy(_defaultConfig());
        vm.prank(NON_ADMIN);
        vm.expectRevert(OnlyAdmin.selector);
        wrapper.setPaused(true);
    }

    function testSetPausedAdminSucceedsEmitsAndSetsFlag() external {
        PausableOracleWrapper wrapper = _deployProxy(_defaultConfig());
        vm.expectEmit(false, false, false, true, address(wrapper));
        emit PauseSet(true);
        vm.prank(ADMIN);
        wrapper.setPaused(true);
        assertEq(wrapper.paused(), true);
    }

    // -------- Manual pause: gating --------

    function testLatestAnswerRevertsWhenManuallyPaused() external {
        PausableOracleWrapper wrapper = _deployProxy(_defaultConfig());
        upstream.setLatestAnswer(int256(123));
        vm.prank(ADMIN);
        wrapper.setPaused(true);
        vm.expectRevert(OraclePausedManual.selector);
        wrapper.latestAnswer();
    }

    function testLatestRoundDataRevertsWhenManuallyPaused() external {
        PausableOracleWrapper wrapper = _deployProxy(_defaultConfig());
        vm.prank(ADMIN);
        wrapper.setPaused(true);
        vm.expectRevert(OraclePausedManual.selector);
        wrapper.latestRoundData();
    }

    function testGetRoundDataRevertsWhenManuallyPaused() external {
        PausableOracleWrapper wrapper = _deployProxy(_defaultConfig());
        // Note: upstream `getRoundData` reverts by default — the wrapper's
        // pause check MUST fire first or this test would surface the mock's
        // revert string instead of `OraclePausedManual`.
        vm.prank(ADMIN);
        wrapper.setPaused(true);
        vm.expectRevert(OraclePausedManual.selector);
        wrapper.getRoundData(uint80(1));
    }

    function testUnpauseRestoresReads() external {
        PausableOracleWrapper wrapper = _deployProxy(_defaultConfig());
        upstream.setLatestAnswer(int256(777));
        vm.prank(ADMIN);
        wrapper.setPaused(true);
        vm.expectRevert(OraclePausedManual.selector);
        wrapper.latestAnswer();
        vm.prank(ADMIN);
        wrapper.setPaused(false);
        assertEq(wrapper.paused(), false);
        assertEq(wrapper.latestAnswer(), int256(777));
    }

    function testMetadataNotPauseGated() external {
        // decimals / description / version remain readable while paused —
        // they're config metadata, not pricing data.
        PausableOracleWrapper wrapper = _deployProxy(_defaultConfig());
        upstream.setDecimals(8);
        upstream.setDescription("AAPL / USD");
        upstream.setVersion(1);
        vm.prank(ADMIN);
        wrapper.setPaused(true);
        assertEq(wrapper.decimals(), 8);
        assertEq(wrapper.description(), "AAPL / USD");
        assertEq(wrapper.version(), 1);
    }

    // -------- Admin rotation --------

    function testSetAdminOnlyAdmin() external {
        PausableOracleWrapper wrapper = _deployProxy(_defaultConfig());
        vm.prank(NON_ADMIN);
        vm.expectRevert(OnlyAdmin.selector);
        wrapper.setAdmin(NON_ADMIN);
    }

    function testSetAdminRevertsZero() external {
        PausableOracleWrapper wrapper = _deployProxy(_defaultConfig());
        vm.prank(ADMIN);
        vm.expectRevert(ZeroAdmin.selector);
        wrapper.setAdmin(address(0));
    }

    function testSetAdminEmitsAndUpdates() external {
        PausableOracleWrapper wrapper = _deployProxy(_defaultConfig());
        address newAdmin = address(0xC0FFEE);
        vm.expectEmit(true, true, false, false, address(wrapper));
        emit AdminSet(ADMIN, newAdmin);
        vm.prank(ADMIN);
        wrapper.setAdmin(newAdmin);
        assertEq(wrapper.admin(), newAdmin);
    }

    function testOldAdminCannotPauseAfterRotation() external {
        PausableOracleWrapper wrapper = _deployProxy(_defaultConfig());
        address newAdmin = address(0xC0FFEE);
        vm.prank(ADMIN);
        wrapper.setAdmin(newAdmin);
        vm.prank(ADMIN);
        vm.expectRevert(OnlyAdmin.selector);
        wrapper.setPaused(true);
        // Sanity: new admin can.
        vm.prank(newAdmin);
        wrapper.setPaused(true);
        assertEq(wrapper.paused(), true);
    }

    // -------- Corporate-action auto-pause --------

    function testAutoPauseDisabledIgnoresMockState() external {
        // pauseConfig is all-zero. Even if the mock has a pending action whose
        // window would otherwise fire, the wrapper short-circuits because
        // `corporateActionsVault == address(0)`.
        PausableOracleWrapper wrapper = _deployProxy(_defaultConfig());
        actions.setEarliestPending(1, ACTION_TYPE_STOCK_SPLIT_V1, uint64(block.timestamp + 60));
        upstream.setLatestAnswer(int256(42));
        assertEq(wrapper.latestAnswer(), int256(42));
    }

    function testAutoPausePendingInsidePreWindowReverts() external {
        PausableOracleWrapper wrapper = _deployProxy(_enabledConfig());
        uint64 effectiveTime = uint64(block.timestamp + PAUSE_BEFORE / 2);
        actions.setEarliestPending(1, ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);
        upstream.setLatestAnswer(int256(42));
        vm.expectRevert(abi.encodeWithSelector(OraclePausedCorporateAction.selector, effectiveTime));
        wrapper.latestAnswer();
    }

    function testAutoPauseCompletedInsidePostWindowReverts() external {
        PausableOracleWrapper wrapper = _deployProxy(_enabledConfig());
        uint64 effectiveTime = uint64(block.timestamp - PAUSE_AFTER / 2);
        actions.setLatestCompleted(1, ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);
        upstream.setLatestAnswer(int256(42));
        vm.expectRevert(abi.encodeWithSelector(OraclePausedCorporateAction.selector, effectiveTime));
        wrapper.latestAnswer();
    }

    function testAutoPauseNoMatchingActionReadsSucceed() external {
        // Pause config enabled, but mock has no actions scripted → reads work.
        PausableOracleWrapper wrapper = _deployProxy(_enabledConfig());
        upstream.setLatestAnswer(int256(123));
        assertEq(wrapper.latestAnswer(), int256(123));
    }

    function testManualPauseTakesPrecedenceOverAutoPause() external {
        // Both conditions would fire — manual pause is checked first so its
        // selector is what the integrator sees.
        PausableOracleWrapper wrapper = _deployProxy(_enabledConfig());
        uint64 effectiveTime = uint64(block.timestamp + PAUSE_BEFORE / 2);
        actions.setEarliestPending(1, ACTION_TYPE_STOCK_SPLIT_V1, effectiveTime);
        vm.prank(ADMIN);
        wrapper.setPaused(true);
        vm.expectRevert(OraclePausedManual.selector);
        wrapper.latestAnswer();
    }
}
