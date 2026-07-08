// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.1/src/Test.sol";
import {IERC4626} from "@openzeppelin-contracts-5.6.1/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin-contracts-5.6.1/token/ERC20/IERC20.sol";
import {IPyth} from "pyth-sdk/IPyth.sol";
import {PythStructs} from "pyth-sdk/PythStructs.sol";
import {ZeroVaultSupply, ZeroVaultSharePrice, NonPositivePrice} from "src/abstract/BasePythOracleAdapter.sol";
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

/// @dev Pyth contract address on Base (from LibPyth).
address constant PYTH_BASE = 0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a;

/// @dev Canonical feed ID used for vault ratio tests (arbitrary, all mocked).
bytes32 constant MOCK_FEED = bytes32(uint256(0xdeadbeef));

uint256 constant BASE_CHAIN_ID = 8453;

/// @title MultiPythOracleAdapterFuzzTest
/// @notice Pure fuzz tests — no fork required. All Pyth responses are mocked.
contract MultiPythOracleAdapterFuzzTest is Test {
    MultiPythOracleAdapterBeaconSetDeployer internal immutable I_DEPLOYER;

    constructor() {
        // Set chain ID so LibPyth resolves the Base Pyth address.
        vm.chainId(BASE_CHAIN_ID);

        MultiPythOracleAdapter implementation = new MultiPythOracleAdapter();
        I_DEPLOYER = new MultiPythOracleAdapterBeaconSetDeployer(
            MultiPythOracleAdapterBeaconSetDeployerConfig({
                initialOwner: address(this), initialMultiPythOracleAdapterImplementation: address(implementation)
            })
        );
    }

    function setUp() external {
        vm.chainId(BASE_CHAIN_ID);
    }

    function _mockVault(address vaultAddr, uint256 totalAssets, uint256 totalSupply) internal {
        vm.mockCall(vaultAddr, abi.encodeWithSelector(IERC4626.totalAssets.selector), abi.encode(totalAssets));
        vm.mockCall(vaultAddr, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(totalSupply));
    }

    /// @dev Mock Pyth to return a valid price for the given feed.
    function _mockFreshFeed(bytes32 feedId, uint256 maxAge, int64 price, uint64 conf) internal {
        PythStructs.Price memory p =
            PythStructs.Price({price: price, conf: conf, expo: -8, publishTime: block.timestamp});
        vm.mockCall(
            PYTH_BASE, abi.encodeWithSelector(IPyth.getPriceNoOlderThan.selector, feedId, maxAge), abi.encode(p)
        );
    }

    /// @dev Mock Pyth to revert (stale) for the given feed.
    function _mockStaleFeed(bytes32 feedId, uint256 maxAge) internal {
        vm.mockCallRevert(
            PYTH_BASE, abi.encodeWithSelector(IPyth.getPriceNoOlderThan.selector, feedId, maxAge), "stale"
        );
    }

    /// @notice Fuzz vault ratio: for any valid totalAssets/totalSupply,
    /// adapter with ratio vault == base adapter price * totalAssets / totalSupply.
    function testFuzzVaultRatio(uint256 totalAssets, uint256 totalSupply) external {
        // Constrain to avoid overflow and edge-case reverts.
        vm.assume(totalSupply > 0);
        vm.assume(totalAssets > 0);
        vm.assume(totalAssets <= 1e30);
        vm.assume(totalSupply <= 1e30);

        // Mock a TSLA-like price: $350 at 8 decimals = 35000000000.
        // Conservative price = price - conf = 35000000000 - 1 = 34999999999.
        int64 mockPrice = 35000000000;
        uint64 mockConf = 1;
        int256 conservativePrice = int256(int64(mockPrice)) - int256(uint256(mockConf));

        // Skip if vault ratio would make final price zero.
        vm.assume(uint256(conservativePrice) * totalAssets / totalSupply > 0);

        address vaultRatio = address(uint160(uint256(keccak256(abi.encode("v.ratio", totalAssets, totalSupply)))));
        _mockVault(vaultRatio, totalAssets, totalSupply);

        address vaultBase = address(uint160(uint256(keccak256(abi.encode("v.base", totalAssets, totalSupply)))));
        _mockVault(vaultBase, 1e18, 1e18);

        FeedConfig[] memory feeds = new FeedConfig[](1);
        feeds[0] = FeedConfig({priceId: MOCK_FEED, maxAge: 300});

        _mockFreshFeed(MOCK_FEED, 300, mockPrice, mockConf);

        MultiPythOracleAdapter adapterRatio = I_DEPLOYER.newMultiPythOracleAdapter(
            MultiPythOracleAdapterConfig({vault: vaultRatio, feeds: feeds, admin: address(this)})
        );
        MultiPythOracleAdapter adapterBase = I_DEPLOYER.newMultiPythOracleAdapter(
            MultiPythOracleAdapterConfig({vault: vaultBase, feeds: feeds, admin: address(this)})
        );

        int256 ratioAnswer = adapterRatio.latestAnswer();
        int256 baseAnswer = adapterBase.latestAnswer();

        assertEq(ratioAnswer, int256(uint256(baseAnswer) * totalAssets / totalSupply), "Vault ratio mismatch");
    }

    /// @notice Fuzz staleness patterns: given N feeds (2-8), fuzz which are
    /// stale via a bitmap. Assert the first non-stale feed is chosen, or
    /// AllFeedsStale if all are stale.
    function testFuzzStalenessPatterns(uint8 feedCountRaw, uint8 staleBitmap) external {
        uint256 numFeeds = bound(feedCountRaw, 2, 8);

        address mockVault = address(uint160(uint256(keccak256(abi.encode("v.stale", feedCountRaw, staleBitmap)))));
        _mockVault(mockVault, 1000e18, 1000e18);

        // Generate distinct feed IDs.
        FeedConfig[] memory feeds = new FeedConfig[](numFeeds);
        bytes32[] memory feedIds = new bytes32[](numFeeds);
        for (uint256 i = 0; i < numFeeds; i++) {
            feedIds[i] = keccak256(abi.encode("feed", i));
            feeds[i] = FeedConfig({priceId: feedIds[i], maxAge: 300});
        }

        MultiPythOracleAdapter adapter = I_DEPLOYER.newMultiPythOracleAdapter(
            MultiPythOracleAdapterConfig({vault: mockVault, feeds: feeds, admin: address(this)})
        );

        // Mock each feed based on staleBitmap.
        int256 firstFreshExpectedPrice = 0;
        bool allStale = true;

        for (uint256 i = 0; i < numFeeds; i++) {
            bool isStale = (staleBitmap >> i) & 1 == 1;

            if (isStale) {
                _mockStaleFeed(feedIds[i], 300);
            } else {
                // Each fresh feed gets a distinct price: (i+1)*100 at expo -8.
                int64 feedPrice = int64(int256((i + 1) * 100));
                _mockFreshFeed(feedIds[i], 300, feedPrice, 1);

                if (allStale) {
                    // First non-stale: conservative = feedPrice - 1.
                    firstFreshExpectedPrice = int256(int64(feedPrice)) - 1;
                    allStale = false;
                }
            }
        }

        if (allStale) {
            vm.expectRevert(abi.encodeWithSelector(AllFeedsStale.selector));
            adapter.latestAnswer();
        } else {
            int256 answer = adapter.latestAnswer();
            assertEq(answer, firstFreshExpectedPrice, "Should use first non-stale feed");
        }
    }
}
