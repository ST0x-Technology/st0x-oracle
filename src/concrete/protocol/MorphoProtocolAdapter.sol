// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {ICLONEABLE_V2_SUCCESS, ICloneableV2} from "rain-factory-0.1.1/src/interface/ICloneableV2.sol";
import {Initializable} from "@openzeppelin-contracts-5.6.1/proxy/utils/Initializable.sol";
import {AggregatorV3Interface} from "src/interface/IAggregatorV3.sol";
import {OracleRegistry} from "src/concrete/registry/OracleRegistry.sol";

/// @dev Error raised when the caller is not the admin.
error OnlyAdmin();

/// @dev Error raised when a zero address is provided for the admin.
error ZeroAdmin();

/// @dev Error raised when a zero address is provided for the registry.
error ZeroRegistry();

/// @dev Error raised when a zero address is provided for the vault.
error ZeroVault();

/// @dev Error raised when the price is not positive.
error NonPositivePrice();

/// @dev Error raised when no oracle is found for the vault in the registry.
error OracleNotFound();

/// @dev Morpho Blue's IOracle interface.
interface IOracle {
    function price() external view returns (uint256);
}

/// @title MorphoProtocolAdapterConfig
/// @notice Configuration for MorphoProtocolAdapter initialization.
/// @param registry The oracle registry address.
/// @param vault The vault address this adapter serves.
/// @param admin The admin address.
struct MorphoProtocolAdapterConfig {
    OracleRegistry registry;
    address vault;
    address admin;
}

/// @title MorphoProtocolAdapter
/// @notice Protocol adapter for Morpho Blue. Implements Morpho's IOracle
/// interface by reading from an underlying AggregatorV3Interface oracle and
/// scaling from 8 decimals to 36 decimals.
/// The registry reference is updatable by the admin, allowing oracle swaps
/// without Morpho governance (oracle addresses are immutable in Morpho markets).
contract MorphoProtocolAdapter is IOracle, ICloneableV2, Initializable {
    /// @dev The oracle registry for looking up the oracle adapter.
    OracleRegistry public registry;
    /// @dev The vault address this adapter serves.
    address public vault;
    /// @dev Admin address for governance actions.
    address public admin;

    /// @dev Emitted when the adapter is initialized.
    event MorphoProtocolAdapterInitialized(address indexed sender, MorphoProtocolAdapterConfig config);
    /// @dev Emitted when the registry reference is updated.
    event RegistrySet(address indexed oldRegistry, address indexed newRegistry);
    /// @dev Emitted when the admin is changed.
    event AdminSet(address indexed oldAdmin, address indexed newAdmin);

    constructor() {
        _disableInitializers();
    }

    /// As per ICloneableV2, this overload MUST always revert. Documents the
    /// signature of the initialize function.
    /// @param config The initialization configuration.
    function initialize(MorphoProtocolAdapterConfig memory config) external pure returns (bytes32) {
        (config);
        revert InitializeSignatureFn();
    }

    /// @inheritdoc ICloneableV2
    function initialize(bytes calldata data) external initializer returns (bytes32) {
        MorphoProtocolAdapterConfig memory config = abi.decode(data, (MorphoProtocolAdapterConfig));

        if (address(config.registry) == address(0)) revert ZeroRegistry();
        if (config.vault == address(0)) revert ZeroVault();
        if (config.admin == address(0)) revert ZeroAdmin();

        registry = config.registry;
        vault = config.vault;
        admin = config.admin;

        emit MorphoProtocolAdapterInitialized(msg.sender, config);

        return ICLONEABLE_V2_SUCCESS;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    /// @notice Update the registry reference. Admin only.
    function setRegistry(OracleRegistry newRegistry) external onlyAdmin {
        if (address(newRegistry) == address(0)) revert ZeroRegistry();
        emit RegistrySet(address(registry), address(newRegistry));
        registry = newRegistry;
    }

    /// @notice Update the admin address. Admin only.
    /// @param newAdmin The new admin address.
    function setAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAdmin();
        emit AdminSet(admin, newAdmin);
        admin = newAdmin;
    }

    /// @notice Returns the price scaled to 36 decimals as required by Morpho
    /// Blue.
    /// @return The price as uint256 scaled to 1e36.
    function price() external view override returns (uint256) {
        AggregatorV3Interface oracle = registry.getOracle(vault);
        if (address(oracle) == address(0)) revert OracleNotFound();

        int256 answer = oracle.latestAnswer();
        if (answer <= 0) revert NonPositivePrice();

        // Scale from 8 decimals to 36 decimals
        return uint256(answer) * 1e28;
    }
}
