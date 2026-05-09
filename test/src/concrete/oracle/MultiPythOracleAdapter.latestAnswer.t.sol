// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.1/src/Test.sol";
import {LibFork} from "test/lib/LibFork.sol";
import {IERC4626} from "@openzeppelin-contracts-5.6.1/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin-contracts-5.6.1/token/ERC20/IERC20.sol";
import {IPyth} from "pyth-sdk/IPyth.sol";
import {PythStructs} from "pyth-sdk/PythStructs.sol";
import {LibPyth} from "rain-pyth-0.0.0-git/src/lib/pyth/LibPyth.sol";
import {
    ZeroVaultSupply,
    ZeroVaultSharePrice,
    NonPositivePrice,
    OraclePausedManual,
    CorporateActionPauseConfig
} from "src/abstract/BasePythOracleAdapter.sol";
import {
    MultiPythOracleAdapter,
    MultiPythOracleAdapterConfig,
    FeedConfig,
    AllFeedsStale
} from "src/concrete/oracle/MultiPythOracleAdapter.sol";
import {
    MultiPythOracleAdapterBeaconSetDeployer,
    MultiPythOracleAdapterBeaconSetDeployerConfig
} from "src/concrete/deploy/MultiPythOracleAdapterBeaconSetDeployer.sol";

/// @dev COIN/USD regular hours Pyth feed ID.
bytes32 constant FEED_COIN_REGULAR = 0xfee33f2a978bf32dd6b662b65ba8083c6773b494f8401194ec1870c640860245;
/// @dev COIN/USD pre-market Pyth feed ID.
bytes32 constant FEED_COIN_PRE = 0x8bdee6bc9dc5a61b971e31dcfae96fc0c7eae37b2604aa6002ad22980bd3517c;
/// @dev COIN/USD post-market Pyth feed ID.
bytes32 constant FEED_COIN_POST = 0x5c3bd92f2eed33779040caea9f82fac705f5121d26251f8f5e17ec35b9559cd4;
/// @dev COIN/USD overnight Pyth feed ID.
bytes32 constant FEED_COIN_OVERNIGHT = 0x42ded7a3ed036606ab22ece1c942f6f9245a67f6f4ec27cfad5974d45fe9d6b6;
/// @dev TSLA/USD regular hours Pyth feed ID.
bytes32 constant FEED_TSLA = 0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1;

uint256 constant BASE_CHAIN_ID = 8453;

contract MultiPythOracleAdapterLatestAnswerTest is Test {
    MultiPythOracleAdapterBeaconSetDeployer internal immutable I_DEPLOYER;

    constructor() {
        LibFork.createSelectForkBase(vm);

        MultiPythOracleAdapter implementation = new MultiPythOracleAdapter();
        I_DEPLOYER = new MultiPythOracleAdapterBeaconSetDeployer(
            MultiPythOracleAdapterBeaconSetDeployerConfig({
                initialOwner: address(this), initialMultiPythOracleAdapterImplementation: address(implementation)
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

    function _mockVault(address vaultAddr, uint256 totalAssets, uint256 totalSupply) internal {
        vm.mockCall(vaultAddr, abi.encodeWithSelector(IERC4626.totalAssets.selector), abi.encode(totalAssets));
        vm.mockCall(vaultAddr, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(totalSupply));
    }

    /// Test single feed returns price (equivalent to PythOracleAdapter).
    function testSingleFeedReturnsPrice() external {
        address mockVault = address(uint160(uint256(keccak256("vault.multi.single"))));
        _mockVault(mockVault, 1000e18, 1000e18);

        FeedConfig[] memory feeds = new FeedConfig[](1);
        // Use TSLA which should be valid at the fork block (regular market hours).
        feeds[0] = FeedConfig({priceId: FEED_TSLA, maxAge: 3600});

        MultiPythOracleAdapter adapter = I_DEPLOYER.newMultiPythOracleAdapter(
            MultiPythOracleAdapterConfig({
                vault: mockVault, feeds: feeds, admin: address(this), pauseConfig: _emptyPauseConfig()
            })
        );

        int256 answer = adapter.latestAnswer();
        assertTrue(answer > 0, "Price should be positive");
        assertTrue(answer > 100e8, "Price too low for TSLA");
        assertTrue(answer < 100_000e8, "Price too high for TSLA");
    }

    /// Test multiple feeds — first valid feed is used.
    /// Uses TSLA as first feed with a generous maxAge so it should hit.
    function testMultipleFeedsFirstValid() external {
        address mockVault = address(uint160(uint256(keccak256("vault.multi.firstvalid"))));
        _mockVault(mockVault, 1000e18, 1000e18);

        FeedConfig[] memory feeds = new FeedConfig[](2);
        feeds[0] = FeedConfig({priceId: FEED_TSLA, maxAge: 3600});
        feeds[1] = FeedConfig({priceId: FEED_COIN_REGULAR, maxAge: 3600});

        MultiPythOracleAdapter adapter = I_DEPLOYER.newMultiPythOracleAdapter(
            MultiPythOracleAdapterConfig({
                vault: mockVault, feeds: feeds, admin: address(this), pauseConfig: _emptyPauseConfig()
            })
        );

        int256 answer = adapter.latestAnswer();
        assertTrue(answer > 0, "Price should be positive");
    }

    /// Test fallback — first feed stale (maxAge=1), second feed valid.
    function testFallbackToSecondFeed() external {
        address mockVault = address(uint160(uint256(keccak256("vault.multi.fallback"))));
        _mockVault(mockVault, 1000e18, 1000e18);

        // First feed with maxAge=1 (will be stale), second with generous maxAge.
        FeedConfig[] memory feeds = new FeedConfig[](2);
        feeds[0] = FeedConfig({priceId: FEED_TSLA, maxAge: 1});
        feeds[1] = FeedConfig({priceId: FEED_COIN_REGULAR, maxAge: 3600});

        MultiPythOracleAdapter adapter = I_DEPLOYER.newMultiPythOracleAdapter(
            MultiPythOracleAdapterConfig({
                vault: mockVault, feeds: feeds, admin: address(this), pauseConfig: _emptyPauseConfig()
            })
        );

        int256 answer = adapter.latestAnswer();
        assertTrue(answer > 0, "Fallback should return positive price");
    }

    /// Test all feeds stale reverts.
    function testAllFeedsStaleReverts() external {
        address mockVault = address(uint160(uint256(keccak256("vault.multi.allstale"))));
        _mockVault(mockVault, 1000e18, 1000e18);

        FeedConfig[] memory feeds = new FeedConfig[](2);
        feeds[0] = FeedConfig({priceId: FEED_TSLA, maxAge: 1});
        feeds[1] = FeedConfig({priceId: FEED_COIN_REGULAR, maxAge: 1});

        MultiPythOracleAdapter adapter = I_DEPLOYER.newMultiPythOracleAdapter(
            MultiPythOracleAdapterConfig({
                vault: mockVault, feeds: feeds, admin: address(this), pauseConfig: _emptyPauseConfig()
            })
        );

        vm.expectRevert(abi.encodeWithSelector(AllFeedsStale.selector));
        adapter.latestAnswer();
    }

    /// Test vault ratio works correctly with multi-feed.
    function testVaultRatioWithMultiFeed() external {
        address mockVault2x = address(uint160(uint256(keccak256("vault.multi.2x"))));
        _mockVault(mockVault2x, 2000e18, 1000e18);

        address mockVault1x = address(uint160(uint256(keccak256("vault.multi.1x"))));
        _mockVault(mockVault1x, 1000e18, 1000e18);

        FeedConfig[] memory feeds = new FeedConfig[](1);
        feeds[0] = FeedConfig({priceId: FEED_TSLA, maxAge: 3600});

        MultiPythOracleAdapter adapter2x = I_DEPLOYER.newMultiPythOracleAdapter(
            MultiPythOracleAdapterConfig({
                vault: mockVault2x, feeds: feeds, admin: address(this), pauseConfig: _emptyPauseConfig()
            })
        );
        MultiPythOracleAdapter adapter1x = I_DEPLOYER.newMultiPythOracleAdapter(
            MultiPythOracleAdapterConfig({
                vault: mockVault1x, feeds: feeds, admin: address(this), pauseConfig: _emptyPauseConfig()
            })
        );

        assertEq(adapter2x.latestAnswer(), adapter1x.latestAnswer() * 2, "2:1 vault ratio should double");
    }

    /// Test zero vault supply reverts.
    function testRevertsOnZeroVaultSupply() external {
        address mockVault = address(uint160(uint256(keccak256("vault.multi.zerosupply"))));
        _mockVault(mockVault, 0, 0);

        FeedConfig[] memory feeds = new FeedConfig[](1);
        feeds[0] = FeedConfig({priceId: FEED_TSLA, maxAge: 3600});

        MultiPythOracleAdapter adapter = I_DEPLOYER.newMultiPythOracleAdapter(
            MultiPythOracleAdapterConfig({
                vault: mockVault, feeds: feeds, admin: address(this), pauseConfig: _emptyPauseConfig()
            })
        );

        vm.expectRevert(abi.encodeWithSelector(ZeroVaultSupply.selector));
        adapter.latestAnswer();
    }

    /// Test latestRoundData returns consistent data.
    function testLatestRoundData() external {
        address mockVault = address(uint160(uint256(keccak256("vault.multi.rounddata"))));
        _mockVault(mockVault, 1000e18, 1000e18);

        FeedConfig[] memory feeds = new FeedConfig[](1);
        feeds[0] = FeedConfig({priceId: FEED_TSLA, maxAge: 3600});

        MultiPythOracleAdapter adapter = I_DEPLOYER.newMultiPythOracleAdapter(
            MultiPythOracleAdapterConfig({
                vault: mockVault, feeds: feeds, admin: address(this), pauseConfig: _emptyPauseConfig()
            })
        );

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            adapter.latestRoundData();

        assertEq(roundId, 1);
        assertEq(answeredInRound, 1);
        assertTrue(answer > 0, "Price should be positive");
        assertTrue(startedAt > 0, "startedAt should be nonzero");
        assertEq(startedAt, updatedAt);
        assertEq(answer, adapter.latestAnswer());
    }

    /// Test reverts when paused.
    function testRevertsWhenPaused() external {
        address mockVault = address(uint160(uint256(keccak256("vault.multi.paused"))));
        _mockVault(mockVault, 1000e18, 1000e18);

        FeedConfig[] memory feeds = new FeedConfig[](1);
        feeds[0] = FeedConfig({priceId: FEED_TSLA, maxAge: 3600});

        MultiPythOracleAdapter adapter = I_DEPLOYER.newMultiPythOracleAdapter(
            MultiPythOracleAdapterConfig({
                vault: mockVault, feeds: feeds, admin: address(this), pauseConfig: _emptyPauseConfig()
            })
        );

        adapter.setPaused(true);

        vm.expectRevert(abi.encodeWithSelector(OraclePausedManual.selector));
        adapter.latestAnswer();
    }

    /// Test reverts when paused (latestRoundData).
    function testLatestRoundDataRevertsWhenPaused() external {
        address mockVault = address(uint160(uint256(keccak256("vault.multi.paused.rounddata"))));
        _mockVault(mockVault, 1000e18, 1000e18);

        FeedConfig[] memory feeds = new FeedConfig[](1);
        feeds[0] = FeedConfig({priceId: FEED_TSLA, maxAge: 3600});

        MultiPythOracleAdapter adapter = I_DEPLOYER.newMultiPythOracleAdapter(
            MultiPythOracleAdapterConfig({
                vault: mockVault, feeds: feeds, admin: address(this), pauseConfig: _emptyPauseConfig()
            })
        );

        adapter.setPaused(true);

        vm.expectRevert(abi.encodeWithSelector(OraclePausedManual.selector));
        adapter.latestRoundData();
    }

    /// Test NonPositivePrice reverts when confidence >= price.
    /// We mock the Pyth contract to return a price where conf >= price.
    function testRevertsNonPositivePrice() external {
        address mockVault = address(uint160(uint256(keccak256("vault.multi.nonpositive"))));
        _mockVault(mockVault, 1000e18, 1000e18);

        FeedConfig[] memory feeds = new FeedConfig[](1);
        feeds[0] = FeedConfig({priceId: FEED_TSLA, maxAge: 3600});

        MultiPythOracleAdapter adapter = I_DEPLOYER.newMultiPythOracleAdapter(
            MultiPythOracleAdapterConfig({
                vault: mockVault, feeds: feeds, admin: address(this), pauseConfig: _emptyPauseConfig()
            })
        );

        // Mock Pyth to return price where conf >= price (conservative price <= 0).
        address pythAddr = address(LibPyth.getPriceFeedContract(block.chainid));
        PythStructs.Price memory badPrice =
            PythStructs.Price({price: 100, conf: 200, expo: -8, publishTime: block.timestamp});
        vm.mockCall(
            pythAddr,
            abi.encodeWithSelector(IPyth.getPriceNoOlderThan.selector, FEED_TSLA, uint256(3600)),
            abi.encode(badPrice)
        );

        vm.expectRevert(abi.encodeWithSelector(NonPositivePrice.selector, int256(100) - int256(200)));
        adapter.latestAnswer();
    }

    /// Test ZeroVaultSharePrice reverts when totalAssets is tiny relative to
    /// totalSupply, causing the price to round to zero.
    function testRevertsZeroVaultSharePrice() external {
        address mockVault = address(uint160(uint256(keccak256("vault.multi.zeroshareprice"))));
        // totalAssets = 1 wei, totalSupply = huge => price rounds to 0
        _mockVault(mockVault, 1, type(uint128).max);

        FeedConfig[] memory feeds = new FeedConfig[](1);
        feeds[0] = FeedConfig({priceId: FEED_TSLA, maxAge: 3600});

        MultiPythOracleAdapter adapter = I_DEPLOYER.newMultiPythOracleAdapter(
            MultiPythOracleAdapterConfig({
                vault: mockVault, feeds: feeds, admin: address(this), pauseConfig: _emptyPauseConfig()
            })
        );

        vm.expectRevert(abi.encodeWithSelector(ZeroVaultSharePrice.selector));
        adapter.latestAnswer();
    }
}
