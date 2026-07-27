// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.1/src/Test.sol";
import {IDIAOracleV2} from "../../../src/interface/IDIAOracleV2.sol";
import {DIAVaultOracle, DIAVaultOracleConfig} from "../../../src/concrete/oracle/DIAVaultOracle.sol";
import {
    DIAVaultOracleBeaconSetDeployer,
    DIAVaultOracleBeaconSetDeployerConfig
} from "../../../src/concrete/deploy/DIAVaultOracleBeaconSetDeployer.sol";
import {
    DeployRecordLib,
    DeployRecordCodehashMismatch,
    DeployRecordAddressMismatch
} from "../../../src/generated/DeployRecordLib.sol";
import {DeployRecordHarness} from "./DeployRecordHarness.sol";
import {MockDIAOracle} from "../../mocks/MockDIAOracle.sol";
import {MockERC4626} from "../../mocks/MockERC4626.sol";
import {MockCorporateActions} from "../../mocks/MockCorporateActions.sol";
import {ACTION_TYPE_STOCK_SPLIT_V1} from "st0x-deploy-0.1.1/src/interface/ICorporateActionsV1.sol";

/// @title DeployRecordSelfTest
/// @notice Proves the deployment-record CHECK MECHANISM works, independently of
/// any real prod record (which may be empty pending a deploy). It deploys the
/// DIA stack locally exactly as `script/Deploy.sol` does (impl → beacon-set
/// deployer → CREATE2 proxy), snapshots each resulting address and its
/// `address.code` codehash — i.e. builds a record the same way a real deploy
/// would — and then asserts the check logic against that fresh record:
///   * `verifyCodehash` passes when the recorded codehash equals the live one
///     and reverts `DeployRecordCodehashMismatch` when the code has changed;
///   * `verifyBeaconProxyAddress` confirms the proxy sits at its deterministic
///     CREATE2 address and reverts `DeployRecordAddressMismatch` on a wrong salt.
/// If this harness is correct, an empty prod record is a matter of populating
/// constants at next deploy — the verification path is already proven sound.
contract DeployRecordSelfTest is Test {
    address internal constant BEACON_OWNER = address(0xB6ACD0);

    DIAVaultOracleBeaconSetDeployer internal sBsd;
    MockDIAOracle internal sDiaOracle;
    MockERC4626 internal sVault;
    MockCorporateActions internal sActions;
    DeployRecordHarness internal sHarness;

    function setUp() public {
        sHarness = new DeployRecordHarness();
        sDiaOracle = new MockDIAOracle();
        sVault = new MockERC4626();
        sActions = new MockCorporateActions();
        sVault.setAsset(address(sActions));
        vm.warp(1_000_000);

        // Mirror `deployDIAStackInfra`: fresh implementation, then the
        // beacon-set deployer that owns the beacon over it.
        DIAVaultOracle implementation = new DIAVaultOracle();
        sBsd = new DIAVaultOracleBeaconSetDeployer(
            DIAVaultOracleBeaconSetDeployerConfig({
                initialOwner: BEACON_OWNER, initialDIAVaultOracleImplementation: address(implementation)
            })
        );
    }

    function _config() internal view returns (DIAVaultOracleConfig memory) {
        return DIAVaultOracleConfig({
            diaOracle: IDIAOracleV2(address(sDiaOracle)),
            symbol: "COIN",
            vault: address(sVault),
            maxAge: 1 hours,
            actionTypeMask: ACTION_TYPE_STOCK_SPLIT_V1,
            pauseTimeBefore: 3600,
            pauseTimeAfter: 3600
        });
    }

    /// @notice Record-then-verify round trip: deploy the stack, freeze each
    /// address + `address.code` codehash into a local record, and prove
    /// `verifyCodehash` accepts every recorded entry against its live code. This
    /// is the exact check the fork test runs against the live chain, so its
    /// passing here proves the check logic is sound.
    function testSelfRecordedCodehashesVerify() external {
        DIAVaultOracle proxy = sBsd.newDIAVaultOracle(_config());

        address beacon = address(sBsd.I_DIA_VAULT_ORACLE_BEACON());

        // "Record" = the address + keccak256(address.code) a real deploy freezes.
        address[3] memory accounts = [address(sBsd), beacon, address(proxy)];
        for (uint256 i = 0; i < accounts.length; i++) {
            bytes32 recorded = accounts[i].codehash;
            assertTrue(recorded != bytes32(0), "recorded account has code");
            // Passes: recorded codehash == live codehash at the recorded address.
            DeployRecordLib.verifyCodehash(accounts[i], recorded);
        }
    }

    /// @notice `verifyCodehash` MUST reject a record whose codehash no longer
    /// matches the live code — the whole point of the freeze is to catch a
    /// silent code swap under a recorded address.
    function testVerifyCodehashRevertsOnDivergence() external {
        DIAVaultOracle proxy = sBsd.newDIAVaultOracle(_config());
        address account = address(proxy);
        bytes32 live = account.codehash;
        bytes32 tampered = keccak256("not the recorded code");

        vm.expectRevert(abi.encodeWithSelector(DeployRecordCodehashMismatch.selector, account, tampered, live));
        sHarness.verifyCodehash(account, tampered);
    }

    /// @notice An unset record slot (`bytes32(0)`) is a no-op: an EMPTY prod
    /// record must not assert against `address(0)`. Proves the empty
    /// signed-price record in `DeployRecordBase` is safely skipped.
    function testVerifyCodehashSkipsEmptyRecord() external view {
        // No revert despite address(0) carrying no code.
        DeployRecordLib.verifyCodehash(address(0), bytes32(0));
    }

    /// @notice The CREATE2 proxy MUST sit at the address derived from
    /// `salt = keccak256(abi.encode(config))`, deployer and beacon — the
    /// deterministic commitment that makes a re-run collide instead of forking.
    /// Proves `verifyBeaconProxyAddress` accepts the real proxy.
    function testSelfProxyAddressIsDeterministic() external {
        DIAVaultOracleConfig memory cfg = _config();
        bytes32 salt = keccak256(abi.encode(cfg));
        address beacon = address(sBsd.I_DIA_VAULT_ORACLE_BEACON());

        DIAVaultOracle proxy = sBsd.newDIAVaultOracle(cfg);

        DeployRecordLib.verifyBeaconProxyAddress(address(proxy), address(sBsd), beacon, salt);
        assertEq(
            address(proxy),
            DeployRecordLib.deriveBeaconProxyAddress(address(sBsd), beacon, salt),
            "proxy at deterministic CREATE2 address"
        );
    }

    /// @notice `verifyBeaconProxyAddress` MUST reject a proxy that is NOT at its
    /// derived address (here: wrong salt) — catching a proxy that is not the
    /// deterministic commitment to its config.
    function testVerifyBeaconProxyAddressRevertsOnWrongSalt() external {
        DIAVaultOracleConfig memory cfg = _config();
        address beacon = address(sBsd.I_DIA_VAULT_ORACLE_BEACON());
        DIAVaultOracle proxy = sBsd.newDIAVaultOracle(cfg);

        bytes32 wrongSalt = keccak256("wrong salt");
        address wrongExpected = DeployRecordLib.deriveBeaconProxyAddress(address(sBsd), beacon, wrongSalt);

        vm.expectRevert(abi.encodeWithSelector(DeployRecordAddressMismatch.selector, wrongExpected, address(proxy)));
        sHarness.verifyBeaconProxyAddress(address(proxy), address(sBsd), beacon, wrongSalt);
    }
}
