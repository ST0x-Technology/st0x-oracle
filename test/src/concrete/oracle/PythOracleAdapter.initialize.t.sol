// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {PythOracleAdapterTest} from "test/abstract/PythOracleAdapterTest.sol";
import {ZeroVault, ZeroAdmin} from "src/abstract/BasePythOracleAdapter.sol";
import {
    PythOracleAdapter,
    PythOracleAdapterConfig,
    ZeroPriceId,
    ZeroMaxAge
} from "src/concrete/oracle/PythOracleAdapter.sol";
import {Vm} from "forge-std-1.16.1/src/Test.sol";

contract PythOracleAdapterInitializeTest is PythOracleAdapterTest {
    /// Test that zero vault address reverts.
    function testInitializeZeroVault(bytes32 priceId, uint256 maxAge, address admin) external {
        vm.assume(priceId != bytes32(0));
        vm.assume(maxAge > 0);
        vm.assume(admin != address(0));
        vm.expectRevert(abi.encodeWithSelector(ZeroVault.selector));
        I_DEPLOYER.newPythOracleAdapter(
            PythOracleAdapterConfig({
                vault: address(0), priceId: priceId, maxAge: maxAge, admin: admin, pauseConfig: _emptyPauseConfig()
            })
        );
    }

    /// Test that zero price ID reverts.
    function testInitializeZeroPriceId(address vault, uint256 maxAge, address admin) external {
        vm.assume(vault != address(0));
        vm.assume(maxAge > 0);
        vm.assume(admin != address(0));
        vm.expectRevert(abi.encodeWithSelector(ZeroPriceId.selector));
        I_DEPLOYER.newPythOracleAdapter(
            PythOracleAdapterConfig({
                vault: vault, priceId: bytes32(0), maxAge: maxAge, admin: admin, pauseConfig: _emptyPauseConfig()
            })
        );
    }

    /// Test that zero max age reverts.
    function testInitializeZeroMaxAge(address vault, bytes32 priceId, address admin) external {
        vm.assume(vault != address(0));
        vm.assume(priceId != bytes32(0));
        vm.assume(admin != address(0));
        vm.expectRevert(abi.encodeWithSelector(ZeroMaxAge.selector));
        I_DEPLOYER.newPythOracleAdapter(
            PythOracleAdapterConfig({
                vault: vault, priceId: priceId, maxAge: 0, admin: admin, pauseConfig: _emptyPauseConfig()
            })
        );
    }

    /// Test that zero admin address reverts.
    function testInitializeZeroAdmin(address vault, bytes32 priceId, uint256 maxAge) external {
        vm.assume(vault != address(0));
        vm.assume(priceId != bytes32(0));
        vm.assume(maxAge > 0);
        vm.expectRevert(abi.encodeWithSelector(ZeroAdmin.selector));
        I_DEPLOYER.newPythOracleAdapter(
            PythOracleAdapterConfig({
                vault: vault, priceId: priceId, maxAge: maxAge, admin: address(0), pauseConfig: _emptyPauseConfig()
            })
        );
    }

    /// Test successful initialization sets all storage correctly.
    function testInitializeSuccess(address vault, bytes32 priceId, uint256 maxAge, address admin) external {
        vm.assume(vault != address(0));
        vm.assume(priceId != bytes32(0));
        vm.assume(maxAge > 0);
        vm.assume(admin != address(0));

        PythOracleAdapter oracle = createOracle(vault, priceId, maxAge, admin);

        assertEq(oracle.vault(), vault);
        assertEq(oracle.priceId(), priceId);
        assertEq(oracle.maxAge(), maxAge);
        assertEq(oracle.admin(), admin);
        assertEq(oracle.paused(), false);
        assertEq(oracle.decimals(), 8);
        assertEq(oracle.version(), 1);
    }

    /// Test that PythOracleAdapterInitialized event is emitted.
    function testInitializeEvent(address vault, bytes32 priceId, uint256 maxAge, address admin) external {
        vm.assume(vault != address(0));
        vm.assume(priceId != bytes32(0));
        vm.assume(maxAge > 0);
        vm.assume(admin != address(0));

        vm.recordLogs();
        PythOracleAdapter oracle = createOracle(vault, priceId, maxAge, admin);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool eventFound = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].topics[0]
                    == keccak256(
                        "PythOracleAdapterInitialized(address,(address,bytes32,uint256,address,(address,uint256,uint64,uint64)))"
                    )
            ) {
                // sender is indexed, so it's in topics[1].
                address sender = address(uint160(uint256(logs[i].topics[1])));
                PythOracleAdapterConfig memory config = abi.decode(logs[i].data, (PythOracleAdapterConfig));
                assertEq(sender, address(I_DEPLOYER));
                assertEq(config.vault, vault);
                assertEq(config.priceId, priceId);
                assertEq(config.maxAge, maxAge);
                assertEq(config.admin, admin);
                eventFound = true;
                break;
            }
        }
        assertTrue(eventFound, "PythOracleAdapterInitialized event not found");
        assertTrue(address(oracle) != address(0));
    }

    /// Test that deploying multiple oracles produces independent proxies.
    function testInitializeMultipleOracles(
        address vaultA,
        bytes32 priceIdA,
        address vaultB,
        bytes32 priceIdB,
        uint256 maxAge,
        address admin
    ) external {
        vm.assume(vaultA != address(0));
        vm.assume(vaultB != address(0));
        vm.assume(priceIdA != bytes32(0));
        vm.assume(priceIdB != bytes32(0));
        vm.assume(maxAge > 0);
        vm.assume(admin != address(0));

        PythOracleAdapter oracleA = createOracle(vaultA, priceIdA, maxAge, admin);
        PythOracleAdapter oracleB = createOracle(vaultB, priceIdB, maxAge, admin);

        assertTrue(address(oracleA) != address(oracleB));
        assertEq(oracleA.vault(), vaultA);
        assertEq(oracleB.vault(), vaultB);
        assertEq(oracleA.priceId(), priceIdA);
        assertEq(oracleB.priceId(), priceIdB);
    }
}
