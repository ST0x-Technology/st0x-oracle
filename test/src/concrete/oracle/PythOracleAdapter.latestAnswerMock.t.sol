// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPyth} from "pyth-sdk/IPyth.sol";
import {PythStructs} from "pyth-sdk/PythStructs.sol";
import {LibPyth} from "rain.pyth/src/lib/pyth/LibPyth.sol";
import {
    NonPositivePrice,
    ZeroVaultSharePrice,
    CorporateActionPauseConfig
} from "st0x.oracle/abstract/BasePythOracleAdapter.sol";
import {PythOracleAdapter, PythOracleAdapterConfig} from "st0x.oracle/concrete/oracle/PythOracleAdapter.sol";
import {
    PythOracleAdapterBeaconSetDeployer,
    PythOracleAdapterBeaconSetDeployerConfig
} from "st0x.oracle/concrete/deploy/PythOracleAdapterBeaconSetDeployer.sol";

/// @dev TSLA/USD Pyth price feed ID (matches the fork test file).
bytes32 constant PRICE_FEED_ID_EQUITY_US_TSLA_USD = 0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1;

/// @dev Base chain ID — `LibPyth.getPriceFeedContract` is keyed on chain id;
/// pinning to Base lets us address-match `vm.mockCall` regardless of fork env.
uint256 constant BASE_CHAIN_ID = 8453;

/// @title PythOracleAdapterLatestAnswerMockTest
/// @notice Mocked equivalents of the cases in
/// `PythOracleAdapter.latestAnswer.t.sol` that don't actually need a Base fork
/// — they all mock both the vault and Pyth so the only thing exercised is the
/// adapter's own price/share logic. The fork-only file is excluded from
/// non-fork CI (it depends on `RPC_URL_BASE_FORK`); these tests close the
/// resulting single-feed coverage gap. Closes audit #64, #65.
contract PythOracleAdapterLatestAnswerMockTest is Test {
    PythOracleAdapterBeaconSetDeployer internal immutable I_DEPLOYER;

    constructor() {
        PythOracleAdapter implementation = new PythOracleAdapter();
        I_DEPLOYER = new PythOracleAdapterBeaconSetDeployer(
            PythOracleAdapterBeaconSetDeployerConfig({
                initialOwner: address(this), initialPythOracleAdapterImplementation: address(implementation)
            })
        );
    }

    function setUp() external {
        vm.chainId(BASE_CHAIN_ID);
    }

    function _emptyPauseConfig() internal pure returns (CorporateActionPauseConfig memory) {
        return CorporateActionPauseConfig({
            corporateActionsVault: address(0), actionTypeMask: 0, pauseTimeBefore: 0, pauseTimeAfter: 0
        });
    }

    /// @dev Helper to mock a vault with given totalAssets and totalSupply.
    function _mockVault(address vaultAddr, uint256 totalAssets, uint256 totalSupply) internal {
        vm.mockCall(vaultAddr, abi.encodeWithSelector(IERC4626.totalAssets.selector), abi.encode(totalAssets));
        vm.mockCall(vaultAddr, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(totalSupply));
    }

    /// @dev Helper to mock the Pyth feed at the Base address for our priceId.
    function _mockPyth(PythStructs.Price memory price) internal {
        address pythAddr = address(LibPyth.getPriceFeedContract(block.chainid));
        vm.mockCall(
            pythAddr,
            abi.encodeWithSelector(IPyth.getPriceNoOlderThan.selector, PRICE_FEED_ID_EQUITY_US_TSLA_USD, uint256(3600)),
            abi.encode(price)
        );
    }

    /// `_conservativePriceFloat` MUST revert `NonPositivePrice(conservative)`
    /// when `price - conf <= 0`. The multi-feed adapter has a sibling test;
    /// the single-feed gap is closed here. Closes audit #64.
    function testLatestAnswerRevertsNonPositivePrice() external {
        address mockVault = address(uint160(uint256(keccak256("vault.tsla.nonpositive"))));
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

        // price = 100, conf = 200 → conservative = -100 → NonPositivePrice(-100).
        PythStructs.Price memory bad =
            PythStructs.Price({price: 100, conf: 200, expo: -8, publishTime: block.timestamp});
        _mockPyth(bad);

        vm.expectRevert(abi.encodeWithSelector(NonPositivePrice.selector, int256(100) - int256(200)));
        oracle.latestAnswer();
    }

    /// `_vaultSharePrice` MUST revert `ZeroVaultSharePrice` when the computed
    /// share price truncates to zero. The multi-feed adapter has a sibling
    /// test; the single-feed gap is closed here. Closes audit #64.
    function testLatestAnswerRevertsZeroVaultSharePrice() external {
        address mockVault = address(uint160(uint256(keccak256("vault.tsla.zeroshareprice"))));
        // Tiny totalAssets / huge totalSupply → assets-per-share underflows.
        _mockVault(mockVault, 1, type(uint128).max);

        PythOracleAdapter oracle = I_DEPLOYER.newPythOracleAdapter(
            PythOracleAdapterConfig({
                vault: mockVault,
                priceId: PRICE_FEED_ID_EQUITY_US_TSLA_USD,
                maxAge: 3600,
                admin: address(this),
                pauseConfig: _emptyPauseConfig()
            })
        );

        // Tiny conservative price + tiny ratio → truncates to 0.
        PythStructs.Price memory tiny = PythStructs.Price({price: 1, conf: 0, expo: -8, publishTime: block.timestamp});
        _mockPyth(tiny);

        vm.expectRevert(ZeroVaultSharePrice.selector);
        oracle.latestAnswer();
    }

    /// `latestRoundData` MUST encode the Pyth `publishTime` into both
    /// `startedAt` and `updatedAt`. The fork test only asserts `startedAt > 0
    /// && startedAt == updatedAt`; a regression that swapped the field order
    /// (e.g. used `block.timestamp` instead) would slip through. Pin the
    /// numeric value here. Closes audit #65.
    function testLatestRoundDataPublishTimeMatchesPyth() external {
        address mockVault = address(uint160(uint256(keccak256("vault.publishtime"))));
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

        uint256 expectedPublishTime = 1234567890;
        PythStructs.Price memory mockPrice =
            PythStructs.Price({price: 100e8, conf: 1e6, expo: -8, publishTime: expectedPublishTime});
        _mockPyth(mockPrice);

        (,, uint256 startedAt, uint256 updatedAt,) = oracle.latestRoundData();
        assertEq(startedAt, expectedPublishTime, "startedAt should equal Pyth publishTime");
        assertEq(updatedAt, expectedPublishTime, "updatedAt should equal Pyth publishTime");
    }
}
