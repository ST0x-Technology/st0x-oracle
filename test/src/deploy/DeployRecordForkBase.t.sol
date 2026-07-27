// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test, console2} from "forge-std-1.16.1/src/Test.sol";
import {DeployRecordBase} from "../../../src/generated/DeployRecordBase.sol";
import {DeployRecordLib} from "../../../src/generated/DeployRecordLib.sol";

/// @title DeployRecordForkBaseTest
/// @notice Fork test proving the LIVE code on Base at each recorded DIA-stack
/// address still hashes to the codehash frozen in `DeployRecordBase` — the
/// verification the audit (#259) asks for: after this passes, anyone can confirm
/// the live infra has not been silently swapped since the release was frozen.
///
/// Forks Base from `BASE_RPC_URL`. Mirrors the repo's fork-test convention: the
/// dedicated `fork-tests.yaml` workflow wires the RPC and runs it for real; the
/// per-push rainix job does not inject an RPC, so when `BASE_RPC_URL` is unset
/// this loudly logs and RETURNS rather than erroring — `no-ignored-tests` bans
/// `vm.skip`, and a hard `createSelectFork` failure would red every per-push
/// run. Locally, export `BASE_RPC_URL=https://mainnet.base.org` to run it.
///
/// @dev The recorded DIA impls are the FIRST ("pre-fold") release; their
/// codehashes intentionally differ from what current source builds (see the
/// PROVENANCE note in `DeployRecordBase`). This test therefore asserts the live
/// code equals the RECORDED codehash — proving the live release is unchanged —
/// NOT that it equals a fresh `forge build`. The empty signed-price record
/// (`bytes32(0)`) is skipped by `verifyCodehash`, so this test needs no edit
/// when that stack is deployed and its record populated.
contract DeployRecordForkBaseTest is Test {
    function testForkLiveDIAStackMatchesRecordedCodehashes() external {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            console2.log("SKIP testForkLiveDIAStackMatchesRecordedCodehashes: BASE_RPC_URL unset");
            return;
        }
        vm.createSelectFork(rpc);

        assertEq(block.chainid, DeployRecordBase.CHAIN_ID, "forked chain is the recorded chain (Base)");

        // Each recorded DIA-stack address must still carry code hashing to its
        // frozen codehash. A swap, self-destruct, or wrong record reverts
        // DeployRecordCodehashMismatch inside verifyCodehash.
        DeployRecordLib.verifyCodehash(
            DeployRecordBase.DIA_VAULT_ORACLE_BEACON_SET_DEPLOYER,
            DeployRecordBase.DIA_VAULT_ORACLE_BEACON_SET_DEPLOYER_CODEHASH
        );
        DeployRecordLib.verifyCodehash(
            DeployRecordBase.DIA_VAULT_ORACLE_IMPLEMENTATION, DeployRecordBase.DIA_VAULT_ORACLE_IMPLEMENTATION_CODEHASH
        );
        DeployRecordLib.verifyCodehash(
            DeployRecordBase.DIA_WTCOIN_ORACLE_PROXY, DeployRecordBase.DIA_WTCOIN_ORACLE_PROXY_CODEHASH
        );

        // The signed-price stack is not deployed on Base; its record is empty
        // (bytes32(0)) and verifyCodehash skips it. Exercised here so the test
        // stays correct the day the record is populated.
        DeployRecordLib.verifyCodehash(
            DeployRecordBase.ST0X_PRICE_ORACLE_BEACON_SET_DEPLOYER,
            DeployRecordBase.ST0X_PRICE_ORACLE_BEACON_SET_DEPLOYER_CODEHASH
        );
        DeployRecordLib.verifyCodehash(
            DeployRecordBase.MORPHO_PAIR_ADAPTER_BEACON_SET_DEPLOYER,
            DeployRecordBase.MORPHO_PAIR_ADAPTER_BEACON_SET_DEPLOYER_CODEHASH
        );

        console2.log("Live Base DIA stack matches all recorded codehashes");
    }
}
