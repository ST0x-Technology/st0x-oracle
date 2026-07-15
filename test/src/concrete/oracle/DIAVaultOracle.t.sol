// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.1/src/Test.sol";
import {Initializable} from "@openzeppelin-contracts-5.6.1/proxy/utils/Initializable.sol";
import {ICLONEABLE_V2_SUCCESS, ICloneableV2} from "rain-factory-0.1.1/src/interface/ICloneableV2.sol";
import {IDIAOracleV2} from "../../../../src/interface/IDIAOracleV2.sol";
import {
    DIAVaultOracle,
    DIAVaultOracleConfig,
    ZeroDIAOracle,
    ZeroVault,
    ZeroMaxAge,
    EmptySymbol,
    DIAPriceNotSet,
    DIAPriceStale,
    ZeroVaultSupply,
    ZeroVaultSharePrice,
    VaultSharePriceOverflow,
    HistoricalRoundDataUnsupported
} from "../../../../src/concrete/oracle/DIAVaultOracle.sol";
import {MockDIAOracle} from "../../../mocks/MockDIAOracle.sol";
import {MockERC4626} from "../../../mocks/MockERC4626.sol";
import {TestERC1967Proxy} from "../../../mocks/TestERC1967Proxy.sol";

contract DIAVaultOracleTest is Test {
    DIAVaultOracle internal implementation;
    MockDIAOracle internal diaOracle;
    MockERC4626 internal vault;
    string internal constant SYMBOL = "COIN";
    uint256 internal constant MAX_AGE = 1 hours;

    event DIAVaultOracleInitialized(address indexed sender, DIAVaultOracleConfig config);

    function setUp() public {
        implementation = new DIAVaultOracle();
        diaOracle = new MockDIAOracle();
        vault = new MockERC4626();
        // Warp far enough in that `block.timestamp - maxAge` doesn't underflow.
        vm.warp(1_000_000);
    }

    function _deployUninit() internal returns (DIAVaultOracle) {
        // Bare ERC1967 proxy is enough — beacon semantics are irrelevant for
        // unit tests of the implementation surface.
        TestERC1967Proxy proxy = new TestERC1967Proxy(address(implementation));
        return DIAVaultOracle(address(proxy));
    }

    function _deployProxy(DIAVaultOracleConfig memory config) internal returns (DIAVaultOracle) {
        DIAVaultOracle oracle = _deployUninit();
        bytes32 ok = oracle.initialize(abi.encode(config));
        assertEq(ok, ICLONEABLE_V2_SUCCESS);
        return oracle;
    }

    function _defaultConfig() internal view returns (DIAVaultOracleConfig memory) {
        return DIAVaultOracleConfig({
            diaOracle: IDIAOracleV2(address(diaOracle)), symbol: SYMBOL, vault: address(vault), maxAge: MAX_AGE
        });
    }

    // -------- ERC-7201 storage-layout pin (beacon-upgrade safety) --------

    /// @notice The `MainStorage` slot constant is a hardcoded hex literal with
    /// no getter. Pin it to the normative ERC-7201 derivation by proving
    /// storage actually lands there: after `initialize`, the first field
    /// (`diaOracle`) must be readable at the recomputed slot. If a future v2
    /// re-namespaces or drifts the layout, this fails — do not "fix" the test,
    /// fix the layout (a drift corrupts every live proxy on beacon upgrade).
    function testMainStorageLocationMatchesErc7201Derivation() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        bytes32 derived =
            keccak256(abi.encode(uint256(keccak256("st0x.diavaultoracle.main")) - 1)) & ~bytes32(uint256(0xff));
        // diaOracle is the first member of MainStorage → sits exactly at the slot.
        address storedDIAOracle = address(uint160(uint256(vm.load(address(oracle), derived))));
        assertEq(
            storedDIAOracle, address(oracle.diaOracle()), "MainStorage must be namespaced at the ERC-7201 derived slot"
        );
    }

    // -------- Init validation --------

    function testInitRevertsZeroDIAOracle() external {
        DIAVaultOracle oracle = _deployUninit();
        DIAVaultOracleConfig memory config = _defaultConfig();
        config.diaOracle = IDIAOracleV2(address(0));
        vm.expectRevert(ZeroDIAOracle.selector);
        oracle.initialize(abi.encode(config));
    }

    function testInitRevertsZeroVault() external {
        DIAVaultOracle oracle = _deployUninit();
        DIAVaultOracleConfig memory config = _defaultConfig();
        config.vault = address(0);
        vm.expectRevert(ZeroVault.selector);
        oracle.initialize(abi.encode(config));
    }

    function testInitRevertsZeroMaxAge() external {
        DIAVaultOracle oracle = _deployUninit();
        DIAVaultOracleConfig memory config = _defaultConfig();
        config.maxAge = 0;
        vm.expectRevert(ZeroMaxAge.selector);
        oracle.initialize(abi.encode(config));
    }

    function testInitRevertsEmptySymbol() external {
        DIAVaultOracle oracle = _deployUninit();
        DIAVaultOracleConfig memory config = _defaultConfig();
        config.symbol = "";
        vm.expectRevert(EmptySymbol.selector);
        oracle.initialize(abi.encode(config));
    }

    // -------- Init success --------

    function testInitSuccessSetsStorageEmitsAndReturnsSuccess() external {
        DIAVaultOracle oracle = _deployUninit();
        DIAVaultOracleConfig memory config = _defaultConfig();

        vm.expectEmit(true, false, false, true, address(oracle));
        emit DIAVaultOracleInitialized(address(this), config);

        bytes32 ok = oracle.initialize(abi.encode(config));
        assertEq(ok, ICLONEABLE_V2_SUCCESS);
        assertEq(address(oracle.diaOracle()), address(diaOracle));
        assertEq(oracle.symbol(), SYMBOL);
        assertEq(oracle.vault(), address(vault));
        assertEq(oracle.maxAge(), MAX_AGE);
    }

    // -------- Typed overload reverts --------

    function testTypedInitializeAlwaysReverts() external {
        // The typed overload is `pure` and MUST always revert per
        // `ICloneableV2`. Call against the implementation directly so we
        // don't burn an initializer slot on a real proxy.
        DIAVaultOracleConfig memory config = _defaultConfig();
        vm.expectRevert(ICloneableV2.InitializeSignatureFn.selector);
        implementation.initialize(config);
    }

    // -------- Constants --------

    function testConstants() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        assertEq(oracle.decimals(), 8);
        assertEq(oracle.description(), SYMBOL);
        assertEq(oracle.version(), 1);
    }

    // -------- latestAnswer happy path --------

    function testLatestAnswerHappyPath() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        // DIA: $100 at 18dp.
        diaOracle.setValue(SYMBOL, 100e18, uint128(block.timestamp));
        // Vault: 2 assets per share.
        vault.setTotalAssets(2e18);
        vault.setTotalSupply(1e18);

        // 100 * 2 / 1 = 200, scaled to 8dp = 200e8.
        int256 answer = oracle.latestAnswer();
        assertEq(answer, int256(200e8));
    }

    // -------- latestAnswer DIA not set --------

    function testLatestAnswerRevertsDIAPriceNotSet() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        // Mock returns (0, 0) for an unset key by default.
        vault.setTotalAssets(1e18);
        vault.setTotalSupply(1e18);

        vm.expectRevert(DIAPriceNotSet.selector);
        oracle.latestAnswer();
    }

    // -------- latestAnswer stale --------

    function testLatestAnswerRevertsWhenStale() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        uint128 staleTimestamp = uint128(block.timestamp - MAX_AGE - 1);
        diaOracle.setValue(SYMBOL, 100e18, staleTimestamp);
        vault.setTotalAssets(1e18);
        vault.setTotalSupply(1e18);

        vm.expectRevert(abi.encodeWithSelector(DIAPriceStale.selector, uint256(staleTimestamp)));
        oracle.latestAnswer();
    }

    function testLatestAnswerAtMaxAgeBoundaryNotStale() external {
        // `block.timestamp - timestamp > maxAge` reverts — equal is OK.
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        uint128 boundary = uint128(block.timestamp - MAX_AGE);
        diaOracle.setValue(SYMBOL, 100e18, boundary);
        vault.setTotalAssets(1e18);
        vault.setTotalSupply(1e18);

        int256 answer = oracle.latestAnswer();
        assertEq(answer, int256(100e8));
    }

    // -------- latestAnswer zero supply --------

    function testLatestAnswerRevertsZeroSupply() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        diaOracle.setValue(SYMBOL, 100e18, uint128(block.timestamp));
        vault.setTotalAssets(2e18);
        vault.setTotalSupply(0);

        vm.expectRevert(ZeroVaultSupply.selector);
        oracle.latestAnswer();
    }

    // -------- latestAnswer zero share price --------

    function testLatestAnswerRevertsZeroSharePrice() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        // diaPrice = 1 (raw uint with 18dp = 1e-18 USD).
        // totalAssets = 1, totalSupply = 1e18 → ratio = 1e-18.
        // Final = 1e-18 * 1e-18 = 1e-36, scaled to 8dp -> 0.
        diaOracle.setValue(SYMBOL, 1, uint128(block.timestamp));
        vault.setTotalAssets(1);
        vault.setTotalSupply(1e18);

        vm.expectRevert(ZeroVaultSharePrice.selector);
        oracle.latestAnswer();
    }

    // -------- latestAnswer overflow --------

    /// @notice Drive the computed 8-decimal share price above `int256.max` so
    /// the `int256(price8)` cast would be unsafe, and assert the contract
    /// reverts `VaultSharePriceOverflow` instead of returning a wrapped
    /// negative price. A regression that dropped the overflow guard (returning
    /// `int256(price8)` directly) would produce a garbage negative answer and
    /// fail this test.
    ///
    /// Magnitude: the 8dp share price must land strictly BETWEEN int256.max
    /// (~5.79e76) and uint256.max (~1.16e77) — below the lower bound the value
    /// fits an int256 and no revert fires; above the upper bound the earlier
    /// `toFixedDecimalLossy(_, 8)` step itself reverts `FixedDecimalOverflow`
    /// before the guard is reached. diaPrice raw = 1e38 (natural 1e20 at 18dp),
    /// totalAssets = 7e48, totalSupply = 1 → natural 7e68 → 8dp 7e76, which sits
    /// in that window. All operands are clean powers-of-ten so BOTH the
    /// intermediate `fromFixedDecimalLosslessPacked` and the final 8dp
    /// conversion are lossless, giving an exact `price8 == 7e76` — so we assert
    /// the full selector + args rather than the bare selector.
    function testLatestAnswerRevertsVaultSharePriceOverflow() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        diaOracle.setValue(SYMBOL, 1e38, uint128(block.timestamp));
        vault.setTotalAssets(7e48);
        vault.setTotalSupply(1);

        vm.expectRevert(abi.encodeWithSelector(VaultSharePriceOverflow.selector, uint256(7e76)));
        oracle.latestAnswer();
    }

    // -------- latestRoundData --------

    function testLatestRoundData() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        uint128 timestamp = uint128(block.timestamp - 5);
        diaOracle.setValue(SYMBOL, 100e18, timestamp);
        vault.setTotalAssets(2e18);
        vault.setTotalSupply(1e18);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            oracle.latestRoundData();

        assertEq(answer, int256(200e8));
        assertEq(uint256(roundId), uint256(timestamp));
        assertEq(uint256(answeredInRound), uint256(timestamp));
        assertEq(startedAt, uint256(timestamp));
        assertEq(updatedAt, uint256(timestamp));
    }

    function testLatestRoundDataMatchesLatestAnswer() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        diaOracle.setValue(SYMBOL, 123e18, uint128(block.timestamp));
        vault.setTotalAssets(7e18);
        vault.setTotalSupply(3e18);

        int256 expected = oracle.latestAnswer();
        (, int256 answer,,,) = oracle.latestRoundData();
        assertEq(answer, expected);
    }

    // -------- getRoundData always reverts --------

    function testGetRoundDataAlwaysReverts(uint80 roundId) external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
        vm.expectRevert(abi.encodeWithSelector(HistoricalRoundDataUnsupported.selector, roundId));
        oracle.getRoundData(roundId);
    }

    // -------- initializer modifier --------

    function testCannotInitializeTwice() external {
        DIAVaultOracle oracle = _deployProxy(_defaultConfig());
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
