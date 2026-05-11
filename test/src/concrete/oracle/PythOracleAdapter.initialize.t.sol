// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {PythOracleAdapterTest} from "test/abstract/PythOracleAdapterTest.sol";
import {ZeroVault, ZeroAdmin} from "st0x.oracle/abstract/BasePythOracleAdapter.sol";
import {
    PythOracleAdapter,
    PythOracleAdapterConfig,
    ZeroPriceId,
    ZeroMaxAge
} from "st0x.oracle/concrete/oracle/PythOracleAdapter.sol";
import {ICloneableV2} from "rain.factory/interface/ICloneableV2.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {Vm} from "forge-std/Test.sol";

contract PythOracleAdapterInitializeTest is PythOracleAdapterTest {
    /// Test that zero vault address reverts.
    function testInitializeZeroVault(bytes32 priceId, uint256 maxAge, address admin) external {
        vm.assume(priceId != bytes32(0));
        vm.assume(maxAge > 0);
        vm.assume(admin != address(0));
        vm.expectRevert(ZeroVault.selector);
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
        vm.expectRevert(ZeroPriceId.selector);
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
        vm.expectRevert(ZeroMaxAge.selector);
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
        vm.expectRevert(ZeroAdmin.selector);
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

    /// Per `ICloneableV2`, the typed `initialize(<Config>)` overload MUST
    /// always revert with `InitializeSignatureFn`. Implementations call it
    /// only for ABI documentation, never as a real entry point. Pin the
    /// behaviour directly on the implementation so a refactor that lets it
    /// succeed (and silently bypass the proper `initialize(bytes)` path) fails
    /// here. Closes audit #61.
    function testInitializeSignatureOverloadAlwaysReverts(address vault, bytes32 priceId, uint256 maxAge, address admin)
        external
    {
        PythOracleAdapter impl = new PythOracleAdapter();

        PythOracleAdapterConfig memory cfg = PythOracleAdapterConfig({
            vault: vault, priceId: priceId, maxAge: maxAge, admin: admin, pauseConfig: _emptyPauseConfig()
        });

        vm.expectRevert(abi.encodeWithSelector(ICloneableV2.InitializeSignatureFn.selector));
        impl.initialize(cfg);
    }

    /// OZ `Initializable.initializer` modifier MUST reject a second
    /// `initialize(bytes)` call on an already-initialized proxy with
    /// `InvalidInitialization()`. If the modifier is ever removed or the
    /// contract switched to `reinitializer`, double-init would silently reset
    /// core state — catch loudly here. Closes audit #62.
    function testCannotDoubleInitialize(address vault, bytes32 priceId, uint256 maxAge, address admin) external {
        vm.assume(vault != address(0));
        vm.assume(priceId != bytes32(0));
        vm.assume(maxAge > 0);
        vm.assume(admin != address(0));

        PythOracleAdapter oracle = createOracle(vault, priceId, maxAge, admin);

        bytes memory data = abi.encode(
            PythOracleAdapterConfig({
                vault: vault, priceId: priceId, maxAge: maxAge, admin: admin, pauseConfig: _emptyPauseConfig()
            })
        );

        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        oracle.initialize(data);
    }

    /// `description()` is documented to return the empty string on every
    /// `BasePythOracleAdapter` subclass (the Aggregator metadata is intentionally
    /// blank). Pin the contract directly so a future override that returns a
    /// non-empty description surfaces immediately. Closes audit #51.
    function testDescription(address vault, bytes32 priceId, uint256 maxAge, address admin) external {
        vm.assume(vault != address(0));
        vm.assume(priceId != bytes32(0));
        vm.assume(maxAge > 0);
        vm.assume(admin != address(0));

        PythOracleAdapter oracle = createOracle(vault, priceId, maxAge, admin);
        assertEq(oracle.description(), "");
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
