// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {LibFork} from "test/lib/LibFork.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {
    MultiPythOracleAdapter,
    MultiPythOracleAdapterConfig,
    FeedConfig,
    MultiOnlyAdmin,
    MultiOraclePaused,
    MultiZeroAdmin,
    MultiZeroMaxAge,
    ZeroFeeds,
    TooManyFeeds,
    FeedIndexOutOfBounds,
    MAX_FEEDS
} from "src/concrete/oracle/MultiPythOracleAdapter.sol";
import {
    MultiPythOracleAdapterBeaconSetDeployer,
    MultiPythOracleAdapterBeaconSetDeployerConfig
} from "src/concrete/deploy/MultiPythOracleAdapterBeaconSetDeployer.sol";

bytes32 constant FEED_TSLA = 0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1;
bytes32 constant FEED_COIN = 0xfee33f2a978bf32dd6b662b65ba8083c6773b494f8401194ec1870c640860245;

uint256 constant BASE_CHAIN_ID = 8453;

contract MultiPythOracleAdapterAdminTest is Test {
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

    function setUp() external {
        vm.chainId(BASE_CHAIN_ID);
    }

    function _mockVault(address vaultAddr) internal {
        vm.mockCall(vaultAddr, abi.encodeWithSelector(IERC4626.totalAssets.selector), abi.encode(1000e18));
        vm.mockCall(vaultAddr, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(1000e18));
    }

    function _deployAdapter() internal returns (MultiPythOracleAdapter) {
        address mockVault = address(uint160(uint256(keccak256("vault.multi.admin"))));
        _mockVault(mockVault);

        FeedConfig[] memory feeds = new FeedConfig[](1);
        feeds[0] = FeedConfig({priceId: FEED_TSLA, maxAge: 3600});

        return I_DEPLOYER.newMultiPythOracleAdapter(
            MultiPythOracleAdapterConfig({vault: mockVault, feeds: feeds, admin: address(this)})
        );
    }

    /// Test setPaused works for admin.
    function testSetPaused() external {
        MultiPythOracleAdapter adapter = _deployAdapter();

        adapter.setPaused(true);
        assertTrue(adapter.paused());

        vm.expectRevert(abi.encodeWithSelector(MultiOraclePaused.selector));
        adapter.latestAnswer();

        adapter.setPaused(false);
        assertFalse(adapter.paused());

        int256 answer = adapter.latestAnswer();
        assertTrue(answer > 0);
    }

    /// Test setPaused reverts for non-admin.
    function testSetPausedRevertsNonAdmin() external {
        MultiPythOracleAdapter adapter = _deployAdapter();

        vm.prank(address(0xdead));
        vm.expectRevert(abi.encodeWithSelector(MultiOnlyAdmin.selector));
        adapter.setPaused(true);
    }

    /// Test setAdmin works.
    function testSetAdmin() external {
        MultiPythOracleAdapter adapter = _deployAdapter();
        address newAdmin = address(0xBEEF);

        adapter.setAdmin(newAdmin);
        assertEq(adapter.admin(), newAdmin);

        // Old admin can no longer call admin functions.
        vm.expectRevert(abi.encodeWithSelector(MultiOnlyAdmin.selector));
        adapter.setPaused(true);

        // New admin can.
        vm.prank(newAdmin);
        adapter.setPaused(true);
        assertTrue(adapter.paused());
    }

    /// Test setAdmin reverts with zero address.
    function testSetAdminRevertsZero() external {
        MultiPythOracleAdapter adapter = _deployAdapter();

        vm.expectRevert(abi.encodeWithSelector(MultiZeroAdmin.selector));
        adapter.setAdmin(address(0));
    }

    /// Test setFeeds works.
    function testSetFeeds() external {
        MultiPythOracleAdapter adapter = _deployAdapter();

        FeedConfig[] memory newFeeds = new FeedConfig[](2);
        newFeeds[0] = FeedConfig({priceId: FEED_COIN, maxAge: 300});
        newFeeds[1] = FeedConfig({priceId: FEED_TSLA, maxAge: 600});

        adapter.setFeeds(newFeeds);

        assertEq(adapter.feedCount(), 2);
        FeedConfig memory feed0 = adapter.getFeed(0);
        assertEq(feed0.priceId, FEED_COIN);
        assertEq(feed0.maxAge, 300);
        FeedConfig memory feed1 = adapter.getFeed(1);
        assertEq(feed1.priceId, FEED_TSLA);
        assertEq(feed1.maxAge, 600);
    }

    /// Test setFeeds clears old feeds when shrinking.
    function testSetFeedsShrinks() external {
        MultiPythOracleAdapter adapter = _deployAdapter();

        // First set 3 feeds.
        FeedConfig[] memory threeFeeds = new FeedConfig[](3);
        threeFeeds[0] = FeedConfig({priceId: FEED_TSLA, maxAge: 300});
        threeFeeds[1] = FeedConfig({priceId: FEED_COIN, maxAge: 300});
        threeFeeds[2] = FeedConfig({priceId: FEED_TSLA, maxAge: 600});
        adapter.setFeeds(threeFeeds);
        assertEq(adapter.feedCount(), 3);

        // Shrink to 1 feed.
        FeedConfig[] memory oneFeed = new FeedConfig[](1);
        oneFeed[0] = FeedConfig({priceId: FEED_COIN, maxAge: 300});
        adapter.setFeeds(oneFeed);
        assertEq(adapter.feedCount(), 1);

        // Old index 1 should be out of bounds.
        vm.expectRevert(abi.encodeWithSelector(FeedIndexOutOfBounds.selector, 1, 1));
        adapter.getFeed(1);
    }

    /// Test setFeeds reverts for non-admin.
    function testSetFeedsRevertsNonAdmin() external {
        MultiPythOracleAdapter adapter = _deployAdapter();

        FeedConfig[] memory feeds = new FeedConfig[](1);
        feeds[0] = FeedConfig({priceId: FEED_TSLA, maxAge: 300});

        vm.prank(address(0xdead));
        vm.expectRevert(abi.encodeWithSelector(MultiOnlyAdmin.selector));
        adapter.setFeeds(feeds);
    }

    /// Test setFeeds reverts with zero feeds.
    function testSetFeedsRevertsZero() external {
        MultiPythOracleAdapter adapter = _deployAdapter();

        FeedConfig[] memory empty = new FeedConfig[](0);
        vm.expectRevert(abi.encodeWithSelector(ZeroFeeds.selector));
        adapter.setFeeds(empty);
    }

    /// Test setFeeds reverts with too many feeds.
    function testSetFeedsRevertsTooMany() external {
        MultiPythOracleAdapter adapter = _deployAdapter();

        FeedConfig[] memory feeds = new FeedConfig[](MAX_FEEDS + 1);
        for (uint256 i = 0; i < feeds.length; i++) {
            feeds[i] = FeedConfig({priceId: bytes32(uint256(i + 1)), maxAge: 300});
        }
        vm.expectRevert(abi.encodeWithSelector(TooManyFeeds.selector));
        adapter.setFeeds(feeds);
    }

    /// Test setMaxAge works.
    function testSetMaxAge() external {
        MultiPythOracleAdapter adapter = _deployAdapter();

        adapter.setMaxAge(0, 600);
        FeedConfig memory feed = adapter.getFeed(0);
        assertEq(feed.maxAge, 600);
    }

    /// Test setMaxAge reverts with zero.
    function testSetMaxAgeRevertsZero() external {
        MultiPythOracleAdapter adapter = _deployAdapter();

        vm.expectRevert(abi.encodeWithSelector(MultiZeroMaxAge.selector, 0));
        adapter.setMaxAge(0, 0);
    }

    /// Test setMaxAge reverts out of bounds.
    function testSetMaxAgeRevertsOutOfBounds() external {
        MultiPythOracleAdapter adapter = _deployAdapter();

        vm.expectRevert(abi.encodeWithSelector(FeedIndexOutOfBounds.selector, 5, 1));
        adapter.setMaxAge(5, 600);
    }

    /// Test setMaxAge reverts for non-admin.
    function testSetMaxAgeRevertsNonAdmin() external {
        MultiPythOracleAdapter adapter = _deployAdapter();

        vm.prank(address(0xdead));
        vm.expectRevert(abi.encodeWithSelector(MultiOnlyAdmin.selector));
        adapter.setMaxAge(0, 600);
    }

    /// Test getFeed reverts out of bounds.
    function testGetFeedRevertsOutOfBounds() external {
        MultiPythOracleAdapter adapter = _deployAdapter();

        vm.expectRevert(abi.encodeWithSelector(FeedIndexOutOfBounds.selector, 1, 1));
        adapter.getFeed(1);
    }
}
