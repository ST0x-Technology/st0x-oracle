// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {LibFork} from "test/lib/LibFork.sol";
import {ZeroVault, ZeroAdmin} from "src/abstract/BasePythOracleAdapter.sol";
import {
    MultiPythOracleAdapter,
    MultiPythOracleAdapterConfig,
    FeedConfig,
    ZeroPriceId,
    ZeroMaxAge,
    ZeroFeeds,
    TooManyFeeds,
    MAX_FEEDS
} from "src/concrete/oracle/MultiPythOracleAdapter.sol";
import {
    MultiPythOracleAdapterBeaconSetDeployer,
    MultiPythOracleAdapterBeaconSetDeployerConfig
} from "src/concrete/deploy/MultiPythOracleAdapterBeaconSetDeployer.sol";

uint256 constant BASE_CHAIN_ID = 8453;

contract MultiPythOracleAdapterInitializeTest is Test {
    MultiPythOracleAdapterBeaconSetDeployer internal immutable I_DEPLOYER;

    bytes32 constant FEED_A = 0xfee33f2a978bf32dd6b662b65ba8083c6773b494f8401194ec1870c640860245;
    bytes32 constant FEED_B = 0x8bdee6bc9dc5a61b971e31dcfae96fc0c7eae37b2604aa6002ad22980bd3517c;

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

    function _singleFeedConfig() internal pure returns (FeedConfig[] memory) {
        FeedConfig[] memory feeds = new FeedConfig[](1);
        feeds[0] = FeedConfig({priceId: FEED_A, maxAge: 300});
        return feeds;
    }

    function _twoFeedConfig() internal pure returns (FeedConfig[] memory) {
        FeedConfig[] memory feeds = new FeedConfig[](2);
        feeds[0] = FeedConfig({priceId: FEED_A, maxAge: 300});
        feeds[1] = FeedConfig({priceId: FEED_B, maxAge: 600});
        return feeds;
    }

    /// Test basic initialization succeeds.
    function testInitializeBasic() external {
        address mockVault = address(uint160(uint256(keccak256("vault.multi.init"))));

        MultiPythOracleAdapter adapter = I_DEPLOYER.newMultiPythOracleAdapter(
            MultiPythOracleAdapterConfig({vault: mockVault, feeds: _twoFeedConfig(), admin: address(this)})
        );

        assertEq(adapter.vault(), mockVault);
        assertEq(adapter.admin(), address(this));
        assertEq(adapter.feedCount(), 2);
        assertEq(adapter.paused(), false);

        FeedConfig memory feed0 = adapter.getFeed(0);
        assertEq(feed0.priceId, FEED_A);
        assertEq(feed0.maxAge, 300);

        FeedConfig memory feed1 = adapter.getFeed(1);
        assertEq(feed1.priceId, FEED_B);
        assertEq(feed1.maxAge, 600);
    }

    /// Test getFeeds returns all feeds.
    function testGetFeeds() external {
        address mockVault = address(uint160(uint256(keccak256("vault.multi.getfeeds"))));

        MultiPythOracleAdapter adapter = I_DEPLOYER.newMultiPythOracleAdapter(
            MultiPythOracleAdapterConfig({vault: mockVault, feeds: _twoFeedConfig(), admin: address(this)})
        );

        FeedConfig[] memory feeds = adapter.getFeeds();
        assertEq(feeds.length, 2);
        assertEq(feeds[0].priceId, FEED_A);
        assertEq(feeds[1].priceId, FEED_B);
    }

    /// Test initialization reverts with zero vault.
    function testInitializeRevertsZeroVault() external {
        vm.expectRevert(abi.encodeWithSelector(ZeroVault.selector));
        I_DEPLOYER.newMultiPythOracleAdapter(
            MultiPythOracleAdapterConfig({vault: address(0), feeds: _singleFeedConfig(), admin: address(this)})
        );
    }

    /// Test initialization reverts with zero admin.
    function testInitializeRevertsZeroAdmin() external {
        address mockVault = address(uint160(uint256(keccak256("vault.multi.zeroadmin"))));
        vm.expectRevert(abi.encodeWithSelector(ZeroAdmin.selector));
        I_DEPLOYER.newMultiPythOracleAdapter(
            MultiPythOracleAdapterConfig({vault: mockVault, feeds: _singleFeedConfig(), admin: address(0)})
        );
    }

    /// Test initialization reverts with zero feeds.
    function testInitializeRevertsZeroFeeds() external {
        address mockVault = address(uint160(uint256(keccak256("vault.multi.zerofeeds"))));
        FeedConfig[] memory emptyFeeds = new FeedConfig[](0);
        vm.expectRevert(abi.encodeWithSelector(ZeroFeeds.selector));
        I_DEPLOYER.newMultiPythOracleAdapter(
            MultiPythOracleAdapterConfig({vault: mockVault, feeds: emptyFeeds, admin: address(this)})
        );
    }

    /// Test initialization reverts with too many feeds.
    function testInitializeRevertsTooManyFeeds() external {
        address mockVault = address(uint160(uint256(keccak256("vault.multi.toomany"))));
        FeedConfig[] memory feeds = new FeedConfig[](MAX_FEEDS + 1);
        for (uint256 i = 0; i < feeds.length; i++) {
            feeds[i] = FeedConfig({priceId: bytes32(uint256(i + 1)), maxAge: 300});
        }
        vm.expectRevert(abi.encodeWithSelector(TooManyFeeds.selector));
        I_DEPLOYER.newMultiPythOracleAdapter(
            MultiPythOracleAdapterConfig({vault: mockVault, feeds: feeds, admin: address(this)})
        );
    }

    /// Test initialization reverts with zero priceId in a feed.
    function testInitializeRevertsZeroPriceId() external {
        address mockVault = address(uint160(uint256(keccak256("vault.multi.zeropriceid"))));
        FeedConfig[] memory feeds = new FeedConfig[](1);
        feeds[0] = FeedConfig({priceId: bytes32(0), maxAge: 300});
        vm.expectRevert(abi.encodeWithSelector(ZeroPriceId.selector, 0));
        I_DEPLOYER.newMultiPythOracleAdapter(
            MultiPythOracleAdapterConfig({vault: mockVault, feeds: feeds, admin: address(this)})
        );
    }

    /// Test initialization reverts with zero maxAge in a feed.
    function testInitializeRevertsZeroMaxAge() external {
        address mockVault = address(uint160(uint256(keccak256("vault.multi.zeromaxage"))));
        FeedConfig[] memory feeds = new FeedConfig[](1);
        feeds[0] = FeedConfig({priceId: FEED_A, maxAge: 0});
        vm.expectRevert(abi.encodeWithSelector(ZeroMaxAge.selector, 0));
        I_DEPLOYER.newMultiPythOracleAdapter(
            MultiPythOracleAdapterConfig({vault: mockVault, feeds: feeds, admin: address(this)})
        );
    }

    /// Test decimals returns 8.
    function testDecimals() external {
        address mockVault = address(uint160(uint256(keccak256("vault.multi.decimals"))));
        MultiPythOracleAdapter adapter = I_DEPLOYER.newMultiPythOracleAdapter(
            MultiPythOracleAdapterConfig({vault: mockVault, feeds: _singleFeedConfig(), admin: address(this)})
        );
        assertEq(adapter.decimals(), 8);
    }

    /// Test version returns 1.
    function testVersion() external {
        address mockVault = address(uint160(uint256(keccak256("vault.multi.version"))));
        MultiPythOracleAdapter adapter = I_DEPLOYER.newMultiPythOracleAdapter(
            MultiPythOracleAdapterConfig({vault: mockVault, feeds: _singleFeedConfig(), admin: address(this)})
        );
        assertEq(adapter.version(), 1);
    }
}
