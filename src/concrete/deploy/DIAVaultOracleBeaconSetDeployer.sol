// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {IBeacon} from "@openzeppelin-contracts-5.6.1/proxy/beacon/IBeacon.sol";
import {UpgradeableBeacon} from "@openzeppelin-contracts-5.6.1/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin-contracts-5.6.1/proxy/beacon/BeaconProxy.sol";
import {ICLONEABLE_V2_SUCCESS} from "rain-factory-0.1.1/src/interface/ICloneableV2.sol";
import {DIAVaultOracle, DIAVaultOracleConfig} from "../oracle/DIAVaultOracle.sol";

/// @dev Error raised when a zero address is provided for the implementation.
error ZeroImplementation();

/// @dev Error raised when a zero address is provided for the initial beacon
/// owner. Only constrains construction-time ownership; subsequent owner
/// rotations are the beacon's concern.
error ZeroBeaconOwner();

/// @dev Error raised when initialization of the oracle returns the wrong
/// magic value (i.e. not `ICLONEABLE_V2_SUCCESS`). Indicates an
/// implementation regression — should never fire in production.
error InitializeOracleFailed();

/// @title DIAVaultOracleBeaconSetDeployerConfig
/// @notice Configuration for the `DIAVaultOracleBeaconSetDeployer`
/// constructor.
/// @param initialOwner The initial owner of the beacon (controls upgrades).
/// @param initialDIAVaultOracleImplementation The initial implementation
/// contract behind the beacon.
struct DIAVaultOracleBeaconSetDeployerConfig {
    address initialOwner;
    address initialDIAVaultOracleImplementation;
}

/// @title DIAVaultOracleBeaconSetDeployer
/// @notice Deploys a beacon and the `DIAVaultOracle` proxies that share it.
/// Beacon management (upgrades, ownership transfer) is performed externally
/// by the beacon owner; this contract retains no authority over the beacon
/// after construction. Follows the canonical `st0x.deploy`-style
/// BeaconSetDeployer pattern.
contract DIAVaultOracleBeaconSetDeployer {
    /// @notice Emitted when a new DIAVaultOracle proxy is deployed.
    /// @param caller The direct on-chain caller of `newDIAVaultOracle`.
    /// Indexed for filtering — but note minting is PERMISSIONLESS and the salt
    /// is derived from the config alone (msg.sender excluded), so a third party
    /// who sees the intended public config can front-run the mint and appear
    /// here as `caller`. Monitoring that must identify a specific operator
    /// should key on the deterministic proxy address (a commitment to the
    /// config), not on this field. A front-run mint is config-identical,
    /// `initializer`-guarded and sits behind the governance-owned beacon, so it
    /// grants the front-runner no authority — it only reverts the operator's own
    /// later mint on the CREATE2 collision.
    ///
    /// The COMPLEMENTARY case is a mint with a DIFFERENT,
    /// attacker-chosen config: equally permissionless, equally behind the
    /// governance-owned beacon, and equally announced by this event from the
    /// official deployer. NEITHER beacon membership NOR a `Deployment` event
    /// therefore authenticates an instance — for `DIAVaultOracle` an
    /// arbitrary config means an attacker-controlled DIA feed and vault,
    /// which fully determine the served price.
    /// The ONLY authenticity signal is the published deployment address list
    /// (the CI-authored deploy artifacts): consumers MUST be wired from that
    /// list and must never discover instances by scanning events or beacon
    /// membership. Minting stays permissionless on purpose — a gate would add
    /// an owner key to operate for every mint without protecting a correctly
    /// wired consumer (a config-divergent proxy grants its minter no authority
    /// over any instance a consumer was actually pointed at), and the
    /// CREATE2 config-commitment means a published address is itself
    /// verifiable against its claimed config.
    /// @param oracle The address of the new proxy. Indexed for filtering.
    event Deployment(address indexed caller, address indexed oracle);

    /// The beacon for the DIAVaultOracle implementation contracts.
    IBeacon public immutable iDIAVaultOracleBeacon;

    constructor(DIAVaultOracleBeaconSetDeployerConfig memory config) {
        if (config.initialDIAVaultOracleImplementation == address(0)) {
            revert ZeroImplementation();
        }
        if (config.initialOwner == address(0)) {
            revert ZeroBeaconOwner();
        }

        iDIAVaultOracleBeacon = new UpgradeableBeacon(config.initialDIAVaultOracleImplementation, config.initialOwner);
    }

    /// @notice Deploys and initializes a new DIAVaultOracle proxy.
    /// @dev The proxy is minted via CREATE2 with `salt = keccak256(config)`, so
    /// its address is a deterministic commitment to its config and a re-run
    /// with identical config reverts on the CREATE2 collision instead of
    /// silently forking a second, divergent oracle.
    ///
    /// `config.diaOracle` is deliberately NOT validated against the
    /// `DIA_FEED_BASE` constant (src/lib/LibDIAFeed.sol): that address is
    /// Base's canonical DIA feed, and this deployer ships to multiple chains
    /// where DIA's feed lives at a different address — a hardcoded equality
    /// check would brick every non-Base deployment. Feed-address correctness
    /// is a deploy-layer concern (the per-chain deploy tooling pins the
    /// canonical feed for its chain), and instance authenticity is carried by
    /// the published address list, not by config validation here (see the
    /// `Deployment` event NatSpec).
    /// @param config The initialization configuration.
    /// @return oracle The deployed proxy as a typed reference.
    // slither-disable-next-line reentrancy-events
    function newDIAVaultOracle(DIAVaultOracleConfig memory config) external returns (DIAVaultOracle oracle) {
        bytes32 salt = keccak256(abi.encode(config));
        oracle = DIAVaultOracle(address(new BeaconProxy{salt: salt}(address(iDIAVaultOracleBeacon), "")));

        if (oracle.initialize(abi.encode(config)) != ICLONEABLE_V2_SUCCESS) {
            revert InitializeOracleFailed();
        }

        emit Deployment(msg.sender, address(oracle));

        return oracle;
    }
}
