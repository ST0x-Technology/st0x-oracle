// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.1/src/Test.sol";
import {ERC1967Proxy} from "@openzeppelin-contracts-5.6.1/proxy/ERC1967/ERC1967Proxy.sol";

/// @dev OZ v5's `ERC1967Proxy` reverts in its constructor when `_data` is
/// empty. Override `_unsafeAllowUninitialized` so the test harness can stand
/// the proxy up first and call `initialize(bytes)` explicitly — that lets
/// every init test go through the same path (`proxy.initialize(...)`) and
/// keeps return-value assertions on the success hash straightforward.
contract TestERC1967Proxy is ERC1967Proxy {
    constructor(address impl) ERC1967Proxy(impl, "") {}

    function _unsafeAllowUninitialized() internal pure override returns (bool) {
        return true;
    }
}
import {Initializable} from "@openzeppelin-contracts-5.6.1/proxy/utils/Initializable.sol";
import {ICLONEABLE_V2_SUCCESS, ICloneableV2} from "rain-factory-0.1.1/src/interface/ICloneableV2.sol";
import {IChronicle} from "src/interface/IChronicle.sol";
import {
    ChronicleVaultOracle,
    ChronicleVaultOracleConfig,
    ZeroChronicle,
    ZeroVault,
    ZeroMaxAge,
    ChroniclePriceStale,
    ZeroVaultSupply,
    ZeroVaultSharePrice,
    HistoricalRoundDataUnsupported
} from "src/concrete/oracle/ChronicleVaultOracle.sol";
import {MockChronicle} from "test/mocks/MockChronicle.sol";
import {MockERC4626} from "test/mocks/MockERC4626.sol";

contract ChronicleVaultOracleTest is Test {
    ChronicleVaultOracle internal implementation;
    MockChronicle internal chronicle;
    MockERC4626 internal vault;
    uint256 internal constant MAX_AGE = 1 hours;

    event ChronicleVaultOracleInitialized(address indexed sender, ChronicleVaultOracleConfig config);

    function setUp() public {
        implementation = new ChronicleVaultOracle();
        chronicle = new MockChronicle();
        vault = new MockERC4626();
        // Warp far enough in that `block.timestamp - age` doesn't underflow.
        vm.warp(1_000_000);
    }

    function _deployUninit() internal returns (ChronicleVaultOracle) {
        // Bare ERC1967 proxy is enough — beacon semantics are irrelevant for
        // unit tests of the implementation surface.
        TestERC1967Proxy proxy = new TestERC1967Proxy(address(implementation));
        return ChronicleVaultOracle(address(proxy));
    }

    function _deployProxy(ChronicleVaultOracleConfig memory config) internal returns (ChronicleVaultOracle) {
        ChronicleVaultOracle oracle = _deployUninit();
        bytes32 ok = oracle.initialize(abi.encode(config));
        assertEq(ok, ICLONEABLE_V2_SUCCESS);
        return oracle;
    }

    function _defaultConfig() internal view returns (ChronicleVaultOracleConfig memory) {
        return ChronicleVaultOracleConfig({chronicle: chronicle, vault: address(vault), maxAge: MAX_AGE});
    }

    // -------- Init validation --------

    function testInitRevertsZeroChronicle() external {
        ChronicleVaultOracle oracle = _deployUninit();
        ChronicleVaultOracleConfig memory config =
            ChronicleVaultOracleConfig({chronicle: IChronicle(address(0)), vault: address(vault), maxAge: MAX_AGE});
        vm.expectRevert(ZeroChronicle.selector);
        oracle.initialize(abi.encode(config));
    }

    function testInitRevertsZeroVault() external {
        ChronicleVaultOracle oracle = _deployUninit();
        ChronicleVaultOracleConfig memory config =
            ChronicleVaultOracleConfig({chronicle: chronicle, vault: address(0), maxAge: MAX_AGE});
        vm.expectRevert(ZeroVault.selector);
        oracle.initialize(abi.encode(config));
    }

    function testInitRevertsZeroMaxAge() external {
        ChronicleVaultOracle oracle = _deployUninit();
        ChronicleVaultOracleConfig memory config =
            ChronicleVaultOracleConfig({chronicle: chronicle, vault: address(vault), maxAge: 0});
        vm.expectRevert(ZeroMaxAge.selector);
        oracle.initialize(abi.encode(config));
    }

    // -------- Init success --------

    function testInitSuccessSetsStorageEmitsAndReturnsSuccess() external {
        ChronicleVaultOracle oracle = _deployUninit();
        ChronicleVaultOracleConfig memory config = _defaultConfig();

        vm.expectEmit(true, false, false, true, address(oracle));
        emit ChronicleVaultOracleInitialized(address(this), config);

        bytes32 ok = oracle.initialize(abi.encode(config));
        assertEq(ok, ICLONEABLE_V2_SUCCESS);
        assertEq(address(oracle.chronicle()), address(chronicle));
        assertEq(oracle.vault(), address(vault));
        assertEq(oracle.maxAge(), MAX_AGE);
    }

    // -------- Typed overload reverts --------

    function testTypedInitializeAlwaysReverts() external {
        // The typed overload is `pure` and MUST always revert per
        // `ICloneableV2`. Call against the implementation directly so we
        // don't burn an initializer slot on a real proxy.
        ChronicleVaultOracleConfig memory config = _defaultConfig();
        vm.expectRevert(ICloneableV2.InitializeSignatureFn.selector);
        implementation.initialize(config);
    }

    // -------- Constants --------

    function testConstants() external {
        ChronicleVaultOracle oracle = _deployProxy(_defaultConfig());
        assertEq(oracle.decimals(), 8);
        assertEq(oracle.description(), "");
        assertEq(oracle.version(), 1);
    }

    // -------- latestAnswer happy path --------

    function testLatestAnswerHappyPath() external {
        ChronicleVaultOracle oracle = _deployProxy(_defaultConfig());
        // Chronicle: $100 at 18dp.
        chronicle.setReadWithAge(100e18, block.timestamp);
        // Vault: 2 assets per share.
        vault.setTotalAssets(2e18);
        vault.setTotalSupply(1e18);

        // 100 * 2 / 1 = 200, scaled to 8dp = 200e8.
        int256 answer = oracle.latestAnswer();
        assertEq(answer, int256(200e8));
    }

    // -------- latestAnswer stale --------

    function testLatestAnswerRevertsWhenStale() external {
        ChronicleVaultOracle oracle = _deployProxy(_defaultConfig());
        uint256 staleAge = block.timestamp - MAX_AGE - 1;
        chronicle.setReadWithAge(100e18, staleAge);
        vault.setTotalAssets(1e18);
        vault.setTotalSupply(1e18);

        vm.expectRevert(abi.encodeWithSelector(ChroniclePriceStale.selector, staleAge));
        oracle.latestAnswer();
    }

    function testLatestAnswerAtMaxAgeBoundaryNotStale() external {
        // `block.timestamp - age > maxAge` reverts — equal is OK.
        ChronicleVaultOracle oracle = _deployProxy(_defaultConfig());
        uint256 age = block.timestamp - MAX_AGE;
        chronicle.setReadWithAge(100e18, age);
        vault.setTotalAssets(1e18);
        vault.setTotalSupply(1e18);

        int256 answer = oracle.latestAnswer();
        assertEq(answer, int256(100e8));
    }

    // -------- latestAnswer zero supply --------

    function testLatestAnswerRevertsZeroSupply() external {
        ChronicleVaultOracle oracle = _deployProxy(_defaultConfig());
        chronicle.setReadWithAge(100e18, block.timestamp);
        vault.setTotalAssets(2e18);
        vault.setTotalSupply(0);

        vm.expectRevert(ZeroVaultSupply.selector);
        oracle.latestAnswer();
    }

    // -------- latestAnswer zero share price --------

    function testLatestAnswerRevertsZeroSharePrice() external {
        ChronicleVaultOracle oracle = _deployProxy(_defaultConfig());
        // chroniclePrice = 1 (raw uint with 18dp = 1e-18 USD).
        // totalAssets = 1, totalSupply = 1e18 → ratio = 1e-18.
        // Final = 1e-18 * 1e-18 = 1e-36, scaled to 8dp -> 0.
        chronicle.setReadWithAge(1, block.timestamp);
        vault.setTotalAssets(1);
        vault.setTotalSupply(1e18);

        vm.expectRevert(ZeroVaultSharePrice.selector);
        oracle.latestAnswer();
    }

    // -------- latestRoundData --------

    function testLatestRoundData() external {
        ChronicleVaultOracle oracle = _deployProxy(_defaultConfig());
        uint256 age = block.timestamp - 5;
        chronicle.setReadWithAge(100e18, age);
        vault.setTotalAssets(2e18);
        vault.setTotalSupply(1e18);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            oracle.latestRoundData();

        assertEq(answer, int256(200e8));
        assertEq(uint256(roundId), age);
        assertEq(uint256(answeredInRound), age);
        assertEq(startedAt, age);
        assertEq(updatedAt, age);
    }

    function testLatestRoundDataMatchesLatestAnswer() external {
        ChronicleVaultOracle oracle = _deployProxy(_defaultConfig());
        chronicle.setReadWithAge(123e18, block.timestamp);
        vault.setTotalAssets(7e18);
        vault.setTotalSupply(3e18);

        int256 expected = oracle.latestAnswer();
        (, int256 answer,,,) = oracle.latestRoundData();
        assertEq(answer, expected);
    }

    // -------- getRoundData always reverts --------

    function testGetRoundDataAlwaysReverts(uint80 roundId) external {
        ChronicleVaultOracle oracle = _deployProxy(_defaultConfig());
        vm.expectRevert(abi.encodeWithSelector(HistoricalRoundDataUnsupported.selector, roundId));
        oracle.getRoundData(roundId);
    }

    function testGetRoundDataRevertsForZero() external {
        ChronicleVaultOracle oracle = _deployProxy(_defaultConfig());
        vm.expectRevert(abi.encodeWithSelector(HistoricalRoundDataUnsupported.selector, uint80(0)));
        oracle.getRoundData(0);
    }

    // -------- initializer modifier --------

    function testCannotInitializeTwice() external {
        ChronicleVaultOracle oracle = _deployProxy(_defaultConfig());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        oracle.initialize(abi.encode(_defaultConfig()));
    }

    function testImplementationCannotBeInitialized() external {
        // Constructor calls `_disableInitializers()` — direct calls to the
        // implementation must revert.
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(abi.encode(_defaultConfig()));
    }
}
