// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test, Vm} from "forge-std/Test.sol";
import {LibFork} from "test/lib/LibFork.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPyth} from "pyth-sdk/IPyth.sol";
import {PythStructs} from "pyth-sdk/PythStructs.sol";
import {LibPyth} from "rain.pyth/src/lib/pyth/LibPyth.sol";
import {
    ZeroVaultSupply,
    VaultSharePriceOverflow,
    CorporateActionPauseConfig
} from "st0x.oracle/abstract/BasePythOracleAdapter.sol";
import {PythOracleAdapter, PythOracleAdapterConfig} from "st0x.oracle/concrete/oracle/PythOracleAdapter.sol";
import {
    PythOracleAdapterBeaconSetDeployer,
    PythOracleAdapterBeaconSetDeployerConfig
} from "st0x.oracle/concrete/deploy/PythOracleAdapterBeaconSetDeployer.sol";

/// @dev TSLA/USD Pyth price feed ID.
bytes32 constant PRICE_FEED_ID_EQUITY_US_TSLA_USD = 0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1;

/// @dev Base chain ID.
uint256 constant BASE_CHAIN_ID = 8453;

contract PythOracleAdapterLatestAnswerTest is Test {
    PythOracleAdapterBeaconSetDeployer internal immutable I_DEPLOYER;

    constructor() {
        LibFork.createSelectForkBase(vm);

        PythOracleAdapter implementation = new PythOracleAdapter();
        I_DEPLOYER = new PythOracleAdapterBeaconSetDeployer(
            PythOracleAdapterBeaconSetDeployerConfig({
                initialOwner: address(this), initialPythOracleAdapterImplementation: address(implementation)
            })
        );
    }

    function _emptyPauseConfig() internal pure returns (CorporateActionPauseConfig memory) {
        return CorporateActionPauseConfig({
            corporateActionsVault: address(0), actionTypeMask: 0, pauseTimeBefore: 0, pauseTimeAfter: 0
        });
    }

    function setUp() external {
        vm.chainId(BASE_CHAIN_ID);
    }

    /// @dev Helper to mock a vault with given totalAssets and totalSupply.
    function _mockVault(address vaultAddr, uint256 totalAssets, uint256 totalSupply) internal {
        vm.mockCall(vaultAddr, abi.encodeWithSelector(IERC4626.totalAssets.selector), abi.encode(totalAssets));
        vm.mockCall(vaultAddr, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(totalSupply));
    }

    /// Test that latestAnswer returns a positive price on a real Base fork
    /// with a 1:1 vault ratio.
    function testLatestAnswerBaseFork() external {
        address mockVault = address(uint160(uint256(keccak256("vault.tsla"))));
        _mockVault(mockVault, 1000e18, 1000e18);

        PythOracleAdapter oracle = I_DEPLOYER.newPythOracleAdapter(
            PythOracleAdapterConfig({
                vault: mockVault,
                priceId: PRICE_FEED_ID_EQUITY_US_TSLA_USD,
                maxAge: 3600,
                admin: address(this),
                pauseConfig: _emptyPauseConfig()
            })
        );

        int256 answer = oracle.latestAnswer();
        assertTrue(answer > 0, "Price should be positive");
        // TSLA price should be in a reasonable range at 8 decimals.
        // At block 38996123, TSLA was roughly $440.
        assertTrue(answer > 100e8, "Price too low for TSLA");
        assertTrue(answer < 100_000e8, "Price too high for TSLA");
    }

    /// Test that latestAnswer correctly scales with a vault ratio > 1
    /// (e.g., after a 2:1 stock split where totalAssets doubles).
    function testLatestAnswerVaultRatioAboveOne() external {
        address mockVault2x = address(uint160(uint256(keccak256("vault.tsla.split"))));
        _mockVault(mockVault2x, 2000e18, 1000e18);

        PythOracleAdapter oracle2x = I_DEPLOYER.newPythOracleAdapter(
            PythOracleAdapterConfig({
                vault: mockVault2x,
                priceId: PRICE_FEED_ID_EQUITY_US_TSLA_USD,
                maxAge: 3600,
                admin: address(this),
                pauseConfig: _emptyPauseConfig()
            })
        );

        address mockVault1x = address(uint160(uint256(keccak256("vault.tsla.1to1"))));
        _mockVault(mockVault1x, 1000e18, 1000e18);

        PythOracleAdapter oracle1x = I_DEPLOYER.newPythOracleAdapter(
            PythOracleAdapterConfig({
                vault: mockVault1x,
                priceId: PRICE_FEED_ID_EQUITY_US_TSLA_USD,
                maxAge: 3600,
                admin: address(this),
                pauseConfig: _emptyPauseConfig()
            })
        );

        int256 answer2x = oracle2x.latestAnswer();
        int256 answer1x = oracle1x.latestAnswer();

        assertTrue(answer2x > 0, "2x price should be positive");
        assertEq(answer2x, answer1x * 2, "Vault ratio 2:1 should double the price");
    }

    /// Test that latestAnswer reverts when vault has zero total supply.
    function testLatestAnswerRevertsOnZeroVaultSupply() external {
        address mockVault = address(uint160(uint256(keccak256("vault.tsla.empty"))));
        _mockVault(mockVault, 0, 0);

        PythOracleAdapter oracle = I_DEPLOYER.newPythOracleAdapter(
            PythOracleAdapterConfig({
                vault: mockVault,
                priceId: PRICE_FEED_ID_EQUITY_US_TSLA_USD,
                maxAge: 3600,
                admin: address(this),
                pauseConfig: _emptyPauseConfig()
            })
        );

        vm.expectRevert(abi.encodeWithSelector(ZeroVaultSupply.selector));
        oracle.latestAnswer();
    }

    /// Test that latestRoundData returns consistent data with vault ratio.
    function testLatestRoundDataBaseFork() external {
        address mockVault = address(uint160(uint256(keccak256("vault.tsla.rounddata"))));
        _mockVault(mockVault, 1000e18, 1000e18);

        PythOracleAdapter oracle = I_DEPLOYER.newPythOracleAdapter(
            PythOracleAdapterConfig({
                vault: mockVault,
                priceId: PRICE_FEED_ID_EQUITY_US_TSLA_USD,
                maxAge: 3600,
                admin: address(this),
                pauseConfig: _emptyPauseConfig()
            })
        );

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            oracle.latestRoundData();

        // Per audit #43, roundId / answeredInRound now encode the Pyth
        // publishTime (truncated to uint80) so consumers can diff fresh
        // rounds. publishTime > 0 on a live feed.
        assertTrue(roundId > 0, "roundId should be derived from publishTime > 0");
        assertEq(answeredInRound, roundId, "answeredInRound should equal roundId");
        assertTrue(answer > 0, "Price should be positive");
        assertTrue(startedAt > 0, "startedAt should be nonzero");
        assertEq(startedAt, updatedAt);
        assertEq(uint256(roundId), startedAt, "roundId should equal startedAt for uint80-fitting publishTimes");

        assertEq(answer, oracle.latestAnswer());
    }

    /// Test that decimals returns 8.
    function testDecimalsBaseFork() external {
        address mockVault = address(uint160(uint256(keccak256("vault.tsla.decimals"))));
        _mockVault(mockVault, 1000e18, 1000e18);

        PythOracleAdapter oracle = I_DEPLOYER.newPythOracleAdapter(
            PythOracleAdapterConfig({
                vault: mockVault,
                priceId: PRICE_FEED_ID_EQUITY_US_TSLA_USD,
                maxAge: 3600,
                admin: address(this),
                pauseConfig: _emptyPauseConfig()
            })
        );

        assertEq(oracle.decimals(), 8);
    }

    /// `_vaultSharePrice` reverts with `VaultSharePriceOverflow(price8)` when
    /// the computed 8-decimal price exceeds `uint256(type(int256).max)`. The
    /// two adjacent reverts on this path (`ZeroVaultSupply`,
    /// `ZeroVaultSharePrice`) have tests; the upper-bound check is silent
    /// without this. Mock both the vault and the Pyth feed so the exact
    /// pre-condition is reachable without depending on the live TSLA price.
    /// Closes audit #52.
    function testRevertsVaultSharePriceOverflow() external {
        address mockVault = address(uint160(uint256(keccak256("vault.tsla.overflow"))));
        // Vault returns a massive ratio (totalAssets >> totalSupply).
        // Combined with a giant Pyth price, this drives the 8-decimal output
        // above uint256(type(int256).max).
        _mockVault(mockVault, type(uint256).max, 1);

        // Mock Pyth to return the max positive int64 price at expo 0 (no
        // scaling further than the eventual 8-decimal conversion). This
        // guarantees the multiplication overflows int256 regardless of the
        // fork's live TSLA price.
        address pythAddr = address(LibPyth.getPriceFeedContract(block.chainid));
        PythStructs.Price memory hugePrice =
            PythStructs.Price({price: type(int64).max, conf: 0, expo: 0, publishTime: block.timestamp});
        vm.mockCall(
            pythAddr,
            abi.encodeWithSelector(IPyth.getPriceNoOlderThan.selector, PRICE_FEED_ID_EQUITY_US_TSLA_USD, uint256(3600)),
            abi.encode(hugePrice)
        );

        PythOracleAdapter oracle = I_DEPLOYER.newPythOracleAdapter(
            PythOracleAdapterConfig({
                vault: mockVault,
                priceId: PRICE_FEED_ID_EQUITY_US_TSLA_USD,
                maxAge: 3600,
                admin: address(this),
                pauseConfig: _emptyPauseConfig()
            })
        );

        // The overflow path after the rain.float refactor (PR #18) traps in
        // LibDecimalFloat — converting a uint256 of magnitude > 2**128 to a
        // Float reverts with `LossyConversionToFloat` before reaching the
        // final `int256(price8)` cast in `_vaultSharePrice`. Accept either
        // selector; both witness the same overflow-protection contract.
        (bool ok, bytes memory data) = address(oracle).staticcall(abi.encodeWithSelector(oracle.latestAnswer.selector));
        assertFalse(ok, "latestAnswer must revert on overflow inputs");
        require(data.length >= 4, "expected a custom error selector");
        bytes4 selector;
        assembly {
            selector := mload(add(data, 0x20))
        }
        assertTrue(
            selector == VaultSharePriceOverflow.selector
                || selector == bytes4(keccak256("LossyConversionToFloat(int256,int256)")),
            "expected VaultSharePriceOverflow or LossyConversionToFloat"
        );
    }

    /// Test vault ratio with dividend reinvestment scenario.
    /// After dividends: 1050 assets / 1000 shares = 1.05x multiplier.
    function testLatestAnswerVaultRatioDividend() external {
        address mockVaultDiv = address(uint160(uint256(keccak256("vault.tsla.dividend"))));
        _mockVault(mockVaultDiv, 1050e18, 1000e18);

        PythOracleAdapter oracleDiv = I_DEPLOYER.newPythOracleAdapter(
            PythOracleAdapterConfig({
                vault: mockVaultDiv,
                priceId: PRICE_FEED_ID_EQUITY_US_TSLA_USD,
                maxAge: 3600,
                admin: address(this),
                pauseConfig: _emptyPauseConfig()
            })
        );

        address mockVault1x = address(uint160(uint256(keccak256("vault.tsla.div.1to1"))));
        _mockVault(mockVault1x, 1000e18, 1000e18);

        PythOracleAdapter oracle1x = I_DEPLOYER.newPythOracleAdapter(
            PythOracleAdapterConfig({
                vault: mockVault1x,
                priceId: PRICE_FEED_ID_EQUITY_US_TSLA_USD,
                maxAge: 3600,
                admin: address(this),
                pauseConfig: _emptyPauseConfig()
            })
        );

        int256 answerDiv = oracleDiv.latestAnswer();
        int256 answer1x = oracle1x.latestAnswer();

        assertTrue(answerDiv > answer1x, "Dividend vault price should exceed 1:1 price");
        assertEq(answerDiv, answer1x * 1050 / 1000, "Dividend vault price should be 1.05x base");
    }
}
