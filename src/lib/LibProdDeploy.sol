// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity ^0.8.25;

/// @title LibProdDeploy
/// @notice Hardcoded production deployment addresses. Provides an audit trail
/// in git of any address modifications.
/// @dev Per-address "Deployed to … Run: …" comments are hand-curated by the
/// operator after each workflow run (see `AGENTS.md` § Deployment). On a
/// re-deploy the operator MUST append a new line of the form
/// `Re-deployed to <network> <yyyy-mm-dd> with <reason>. Run: <runId>.`
/// rather than rewriting the existing line — losing prior provenance breaks
/// the audit trail. Tracked at #217 (Pass 6 hazard); future work moves this
/// metadata into a workflow-generated JSON artifact consumed by a codegen
/// step so the comments stop drifting from reality.
library LibProdDeploy {
    /// rainlang.eth founder multisig. Used as the `initialOwner` of every
    /// `UpgradeableBeacon` constructed by every `*BeaconSetDeployer` in
    /// `script/Deploy.sol`; per SPEC §13 this is the beacon upgrade authority.
    address constant BEACON_INITIAL_OWNER = 0x8E4bdeec7CEB9570D440676345dA1dCe10329f5b;

    /// Address of a deployed `PythOracleAdapterBeaconSetDeployer`. Deployed
    /// to Base 2026-02-13. Run: 21981134736.
    address constant PYTH_ORACLE_ADAPTER_BEACON_SET_DEPLOYER = 0x29295438119dA1E773f6A103cC935c89BfdEbc4A;

    /// Address of a deployed `MorphoProtocolAdapterBeaconSetDeployer`.
    /// Deployed to Base 2026-02-13. Run: 21981948500.
    address constant MORPHO_PROTOCOL_ADAPTER_BEACON_SET_DEPLOYER = 0x5022bb2ecB539Ad54E49871389E134fb2c9fE9a5;

    /// Address of a deployed `PassthroughProtocolAdapterBeaconSetDeployer`.
    /// Deployed to Base 2026-02-13. Run: 21982188432.
    address constant PASSTHROUGH_PROTOCOL_ADAPTER_BEACON_SET_DEPLOYER = 0x62bb7076075a78dEc0e888668C44482235B93CD0;

    /// Address of a deployed `OracleUnifiedDeployer`. Deployed to Base
    /// 2026-02-13. Run: 21982788744.
    address constant ORACLE_UNIFIED_DEPLOYER = 0x377c9657D1827b6bcd1e4B6d0a714815D5F2C615;

    /// Address of a deployed `OracleRegistryBeaconSetDeployer`. Deployed to
    /// Base 2026-02-13. Run: 21984615902.
    address constant ORACLE_REGISTRY_BEACON_SET_DEPLOYER = 0x3B8E2056Dce6E6847e853c3FEdda379802cD07d3;

    /// Address of a deployed `MultiPythOracleAdapterBeaconSetDeployer`.
    /// Deployed to Base 2026-02-17. Run: 22098089152.
    address constant MULTI_PYTH_ORACLE_ADAPTER_BEACON_SET_DEPLOYER = 0xDc555fb8043b50d449667eE718527eCad2A267ad;

    /// Address of a deployed `MultiOracleUnifiedDeployer`. Deployed to Base
    /// 2026-02-17. Run: 22098092240.
    /// Re-deployed to Base 2026-02-18 with updated constants. Run: 22101213391.
    address constant MULTI_ORACLE_UNIFIED_DEPLOYER = 0x4fcef5a7B3059586ad7A9552aCA0a60d075CB74c;

    /// Address of the canonical `OracleRegistry` proxy. Deployed to Base
    /// 2026-02-13.
    address constant ORACLE_REGISTRY = 0x36a14d00a8597731fb6dB1e0e7EeA0BB81ffD156;
}
