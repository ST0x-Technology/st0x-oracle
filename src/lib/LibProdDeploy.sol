// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity ^0.8.25;

/// @title LibProdDeploy
/// @notice Hardcoded production deployment addresses. Provides an audit trail
/// in git of any address modifications.
library LibProdDeploy {
    /// TODO: Set to the founder multisig address.
    address constant BEACON_INITIAL_OWNER = address(0);

    /// TODO: Set after initial deployment to Base.
    address constant PYTH_ORACLE_ADAPTER_BEACON_SET_DEPLOYER = address(0);

    /// TODO: Set after initial deployment to Base.
    address constant MORPHO_PROTOCOL_ADAPTER_BEACON_SET_DEPLOYER = address(0);

    /// TODO: Set after initial deployment to Base.
    address constant PASSTHROUGH_PROTOCOL_ADAPTER_BEACON_SET_DEPLOYER = address(0);

    /// TODO: Set after initial deployment to Base.
    address constant ORACLE_UNIFIED_DEPLOYER = address(0);

    /// TODO: Set after initial deployment to Base.
    address constant ORACLE_REGISTRY_BEACON_SET_DEPLOYER = address(0);

    /// TODO: Set after initial deployment to Base.
    address constant ORACLE_REGISTRY = address(0);
}
