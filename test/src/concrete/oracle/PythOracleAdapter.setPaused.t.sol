// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {PythOracleAdapterTest} from "test/abstract/PythOracleAdapterTest.sol";
import {OraclePausedManual, OnlyAdmin, BasePythOracleAdapter} from "src/abstract/BasePythOracleAdapter.sol";
import {PythOracleAdapter} from "src/concrete/oracle/PythOracleAdapter.sol";
import {AggregatorV2V3Interface} from "src/interface/IAggregatorV2V3.sol";

contract PythOracleAdapterSetPausedTest is PythOracleAdapterTest {
    /// Test that setPaused works for admin.
    function testSetPaused(address vault, bytes32 priceId, uint256 maxAge, address admin) external {
        vm.assume(vault != address(0));
        vm.assume(priceId != bytes32(0));
        vm.assume(maxAge > 0);
        vm.assume(admin != address(0));

        PythOracleAdapter oracle = createOracle(vault, priceId, maxAge, admin);

        assertEq(oracle.paused(), false);

        vm.prank(admin);
        oracle.setPaused(true);
        assertEq(oracle.paused(), true);

        vm.prank(admin);
        oracle.setPaused(false);
        assertEq(oracle.paused(), false);
    }

    /// Test that setPaused reverts for non-admin.
    function testSetPausedOnlyAdmin(address vault, bytes32 priceId, uint256 maxAge, address admin, address nonAdmin)
        external
    {
        vm.assume(vault != address(0));
        vm.assume(priceId != bytes32(0));
        vm.assume(maxAge > 0);
        vm.assume(admin != address(0));
        vm.assume(nonAdmin != admin);

        PythOracleAdapter oracle = createOracle(vault, priceId, maxAge, admin);

        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(OnlyAdmin.selector));
        oracle.setPaused(true);
    }

    /// Test that latestAnswer reverts when paused.
    function testLatestAnswerWhenPaused(address vault, bytes32 priceId, uint256 maxAge, address admin) external {
        vm.assume(vault != address(0));
        vm.assume(priceId != bytes32(0));
        vm.assume(maxAge > 0);
        vm.assume(admin != address(0));

        PythOracleAdapter oracle = createOracle(vault, priceId, maxAge, admin);

        vm.prank(admin);
        oracle.setPaused(true);

        vm.expectRevert(abi.encodeWithSelector(OraclePausedManual.selector));
        oracle.latestAnswer();
    }

    /// Test that latestRoundData reverts when paused.
    function testLatestRoundDataWhenPaused(address vault, bytes32 priceId, uint256 maxAge, address admin) external {
        vm.assume(vault != address(0));
        vm.assume(priceId != bytes32(0));
        vm.assume(maxAge > 0);
        vm.assume(admin != address(0));

        PythOracleAdapter oracle = createOracle(vault, priceId, maxAge, admin);

        vm.prank(admin);
        oracle.setPaused(true);

        vm.expectRevert(abi.encodeWithSelector(OraclePausedManual.selector));
        oracle.latestRoundData();
    }

    /// Test that PauseSet event is emitted.
    function testPauseSetEvent(address vault, bytes32 priceId, uint256 maxAge, address admin) external {
        vm.assume(vault != address(0));
        vm.assume(priceId != bytes32(0));
        vm.assume(maxAge > 0);
        vm.assume(admin != address(0));

        PythOracleAdapter oracle = createOracle(vault, priceId, maxAge, admin);

        vm.expectEmit();
        emit BasePythOracleAdapter.PauseSet(true);
        vm.prank(admin);
        oracle.setPaused(true);

        vm.expectEmit();
        emit BasePythOracleAdapter.PauseSet(false);
        vm.prank(admin);
        oracle.setPaused(false);
    }
}
