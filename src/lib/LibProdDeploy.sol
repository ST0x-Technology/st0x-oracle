// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity ^0.8.25;

/// @title LibProdDeploy
/// @notice Hardcoded production deployment addresses. Provides an audit trail
/// in git of any address modifications.
library LibProdDeploy {
    /// rainlang.eth founder multisig.
    address constant BEACON_INITIAL_OWNER = 0x8E4bdeec7CEB9570D440676345dA1dCe10329f5b;

    /// Deployed to Base 2026-02-13. Run: 21981134736.
    address constant PYTH_ORACLE_ADAPTER_BEACON_SET_DEPLOYER = 0x29295438119dA1E773f6A103cC935c89BfdEbc4A;

    /// Deployed to Base 2026-02-13. Run: 21981948500.
    address constant MORPHO_PROTOCOL_ADAPTER_BEACON_SET_DEPLOYER = 0x5022bb2ecB539Ad54E49871389E134fb2c9fE9a5;

    /// Deployed to Base 2026-02-13. Run: 21982188432.
    address constant PASSTHROUGH_PROTOCOL_ADAPTER_BEACON_SET_DEPLOYER = 0x62bb7076075a78dEc0e888668C44482235B93CD0;

    /// TODO: Set after initial deployment to Base.
    address constant ORACLE_UNIFIED_DEPLOYER = address(0);

    /// TODO: Set after initial deployment to Base.
    address constant ORACLE_REGISTRY_BEACON_SET_DEPLOYER = address(0);

    /// TODO: Set after initial deployment to Base.
    address constant ORACLE_REGISTRY = address(0);
}
