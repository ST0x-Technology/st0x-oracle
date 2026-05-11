// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {LibFork} from "test/lib/LibFork.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {
    OnlyAdmin,
    OraclePausedManual,
    ZeroAdmin,
    BasePythOracleAdapter,
    CorporateActionPauseConfig
} from "st0x.oracle/abstract/BasePythOracleAdapter.sol";
import {
    MultiPythOracleAdapter,
    MultiPythOracleAdapterConfig,
    FeedConfig,
    ZeroPriceId,
    ZeroMaxAge,
    ZeroFeeds,
    TooManyFeeds,
    FeedIndexOutOfBounds,
    MAX_FEEDS
} from "st0x.oracle/concrete/oracle/MultiPythOracleAdapter.sol";
import {
    MultiPythOracleAdapterBeaconSetDeployer,
    MultiPythOracleAdapterBeaconSetDeployerConfig
} from "st0x.oracle/concrete/deploy/MultiPythOracleAdapterBeaconSetDeployer.sol";

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

    function _emptyPauseConfig() internal pure returns (CorporateActionPauseConfig memory) {
        return CorporateActionPauseConfig({
            corporateActionsVault: address(0), actionTypeMask: 0, pauseTimeBefore: 0, pauseTimeAfter: 0
        });
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
            MultiPythOracleAdapterConfig({
                vault: mockVault, feeds: feeds, admin: address(this), pauseConfig: _emptyPauseConfig()
            })
        );
    }

    /// Test setPaused works for admin.
    function testSetPaused() external {
        MultiPythOracleAdapter adapter = _deployAdapter();

        adapter.setPaused(true);
        assertTrue(adapter.paused());

        vm.expectRevert(abi.encodeWithSelector(OraclePausedManual.selector));
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
        vm.expectRevert(abi.encodeWithSelector(OnlyAdmin.selector));
        adapter.setPaused(true);
    }

    /// Test setAdmin works.
    function testSetAdmin() external {
        MultiPythOracleAdapter adapter = _deployAdapter();
        address newAdmin = address(0xBEEF);

        adapter.setAdmin(newAdmin);
        assertEq(adapter.admin(), newAdmin);

        // Old admin can no longer call admin functions.
        vm.expectRevert(abi.encodeWithSelector(OnlyAdmin.selector));
        adapter.setPaused(true);

        // New admin can.
        vm.prank(newAdmin);
        adapter.setPaused(true);
        assertTrue(adapter.paused());
    }

    /// `setAdmin` must emit `AdminSet(old, new)` indexed on both addresses.
    /// Closes audit #50.
    function testSetAdminEmitsEvent() external {
        MultiPythOracleAdapter adapter = _deployAdapter();
        address newAdmin = address(0xBEEF);

        vm.expectEmit(true, true, true, true);
        emit BasePythOracleAdapter.AdminSet(address(this), newAdmin);
        adapter.setAdmin(newAdmin);
    }

    /// `setAdmin` from a non-admin caller must revert with `OnlyAdmin`. Closes
    /// audit #50.
    function testSetAdminRevertsNonAdmin() external {
        MultiPythOracleAdapter adapter = _deployAdapter();

        vm.prank(address(0xdead));
        vm.expectRevert(abi.encodeWithSelector(OnlyAdmin.selector));
        adapter.setAdmin(address(0xBEEF));
    }

    /// Test setAdmin reverts with zero address.
    function testSetAdminRevertsZero() external {
        MultiPythOracleAdapter adapter = _deployAdapter();

        vm.expectRevert(abi.encodeWithSelector(ZeroAdmin.selector));
        adapter.setAdmin(address(0));
    }

    /// `setFeeds` must emit `FeedsSet(feeds)` with the full new feed list.
    /// Closes audit #60.
    function testSetFeedsEmitsEvent() external {
        MultiPythOracleAdapter adapter = _deployAdapter();

        FeedConfig[] memory newFeeds = new FeedConfig[](2);
        newFeeds[0] = FeedConfig({priceId: FEED_COIN, maxAge: 300});
        newFeeds[1] = FeedConfig({priceId: FEED_TSLA, maxAge: 600});

        vm.expectEmit();
        emit MultiPythOracleAdapter.FeedsSet(newFeeds);
        adapter.setFeeds(newFeeds);
    }

    /// `setFeeds` must revert `ZeroPriceId(i)` when any entry has a zero
    /// priceId, reporting the offending index. Closes audit #60.
    function testSetFeedsRevertsZeroPriceIdInList() external {
        MultiPythOracleAdapter adapter = _deployAdapter();
        FeedConfig[] memory feeds = new FeedConfig[](2);
        feeds[0] = FeedConfig({priceId: FEED_TSLA, maxAge: 300});
        feeds[1] = FeedConfig({priceId: bytes32(0), maxAge: 300});
        vm.expectRevert(abi.encodeWithSelector(ZeroPriceId.selector, uint256(1)));
        adapter.setFeeds(feeds);
    }

    /// `setFeeds` must revert `ZeroMaxAge(i)` when any entry has a zero
    /// maxAge, reporting the offending index. Closes audit #60.
    function testSetFeedsRevertsZeroMaxAgeInList() external {
        MultiPythOracleAdapter adapter = _deployAdapter();
        FeedConfig[] memory feeds = new FeedConfig[](2);
        feeds[0] = FeedConfig({priceId: FEED_TSLA, maxAge: 300});
        feeds[1] = FeedConfig({priceId: FEED_COIN, maxAge: 0});
        vm.expectRevert(abi.encodeWithSelector(ZeroMaxAge.selector, uint256(1)));
        adapter.setFeeds(feeds);
    }

    /// `setMaxAge` must emit `FeedMaxAgeSet(index, maxAge)`. Closes audit #60.
    function testSetMaxAgeEmitsEvent() external {
        MultiPythOracleAdapter adapter = _deployAdapter();
        vm.expectEmit();
        emit MultiPythOracleAdapter.FeedMaxAgeSet(0, 600);
        adapter.setMaxAge(0, 600);
    }

    /// `_setFeeds` must clear the underlying storage slot when shrinking. Set
    /// 3 feeds, shrink to 1, then grow back to 3 with new values — the
    /// expanded slots must reflect the new values, not stale data from the
    /// first call. Closes audit #60.
    function testSetFeedsShrinkClearsUnderlyingSlot() external {
        MultiPythOracleAdapter adapter = _deployAdapter();
        FeedConfig[] memory threeFeeds = new FeedConfig[](3);
        threeFeeds[0] = FeedConfig({priceId: FEED_TSLA, maxAge: 300});
        threeFeeds[1] = FeedConfig({priceId: FEED_COIN, maxAge: 300});
        threeFeeds[2] = FeedConfig({priceId: FEED_TSLA, maxAge: 600});
        adapter.setFeeds(threeFeeds);

        FeedConfig[] memory oneFeed = new FeedConfig[](1);
        oneFeed[0] = FeedConfig({priceId: FEED_COIN, maxAge: 300});
        adapter.setFeeds(oneFeed);

        // Expand back to 3 feeds — slots 1 and 2 should reflect the new
        // entries, not whatever was at those positions before.
        FeedConfig[] memory threeAgain = new FeedConfig[](3);
        threeAgain[0] = FeedConfig({priceId: FEED_COIN, maxAge: 100});
        threeAgain[1] = FeedConfig({priceId: FEED_COIN, maxAge: 200});
        threeAgain[2] = FeedConfig({priceId: FEED_COIN, maxAge: 300});
        adapter.setFeeds(threeAgain);

        assertEq(adapter.getFeed(1).priceId, FEED_COIN);
        assertEq(adapter.getFeed(1).maxAge, 200);
        assertEq(adapter.getFeed(2).priceId, FEED_COIN);
        assertEq(adapter.getFeed(2).maxAge, 300);
    }

    /// `getFeeds()` must return exactly the live feed array after a shrink —
    /// no trailing stale entries. Closes audit #60.
    function testGetFeedsAfterShrink() external {
        MultiPythOracleAdapter adapter = _deployAdapter();
        FeedConfig[] memory threeFeeds = new FeedConfig[](3);
        threeFeeds[0] = FeedConfig({priceId: FEED_TSLA, maxAge: 300});
        threeFeeds[1] = FeedConfig({priceId: FEED_COIN, maxAge: 300});
        threeFeeds[2] = FeedConfig({priceId: FEED_TSLA, maxAge: 600});
        adapter.setFeeds(threeFeeds);

        FeedConfig[] memory oneFeed = new FeedConfig[](1);
        oneFeed[0] = FeedConfig({priceId: FEED_COIN, maxAge: 300});
        adapter.setFeeds(oneFeed);

        FeedConfig[] memory all = adapter.getFeeds();
        assertEq(all.length, 1);
        assertEq(all[0].priceId, FEED_COIN);
        assertEq(all[0].maxAge, 300);
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
        vm.expectRevert(abi.encodeWithSelector(OnlyAdmin.selector));
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

        vm.expectRevert(abi.encodeWithSelector(ZeroMaxAge.selector, 0));
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
        vm.expectRevert(abi.encodeWithSelector(OnlyAdmin.selector));
        adapter.setMaxAge(0, 600);
    }

    /// Test getFeed reverts out of bounds.
    function testGetFeedRevertsOutOfBounds() external {
        MultiPythOracleAdapter adapter = _deployAdapter();

        vm.expectRevert(abi.encodeWithSelector(FeedIndexOutOfBounds.selector, 1, 1));
        adapter.getFeed(1);
    }
}
