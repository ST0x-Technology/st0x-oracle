// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {ICLONEABLE_V2_SUCCESS, ICloneableV2} from "rain-factory-0.1.1/src/interface/ICloneableV2.sol";
import {Initializable} from "@openzeppelin-contracts-5.6.1/proxy/utils/Initializable.sol";
import {AggregatorV2V3Interface} from "src/interface/IAggregatorV2V3.sol";
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

/// @dev Error raised when the currently-pointed registry has no entry for
/// `vault`. This includes both the canonical-registry-never-registered case
/// AND the `setRegistry`-pointed-elsewhere case (where the admin swapped
/// the registry to one that doesn't know about this vault).
error OracleNotFound();

/// @dev Error raised when the registered oracle reports decimals other than 8.
/// The `* 1e28` scaling in `price()` assumes an 8-decimal upstream; any other
/// value would silently mis-price collateral by orders of magnitude. Surfaces
/// loudly to force a fix at registry-rebind time rather than letting
/// Morpho borrow against a 10^N×-wrong price.
error UnexpectedOracleDecimals(uint8 actual, uint8 expected);

/// @notice Morpho Blue's IOracle interface — the minimum surface a Morpho
/// market expects from its oracle.
interface IOracle {
    /// @notice Returns the price scaled to 1e36 as required by Morpho Blue.
    /// @return The price as uint256 scaled to 1e36.
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
/// interface by reading from an underlying AggregatorV2V3Interface oracle and
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

    /// @notice Emitted when the adapter is initialized.
    /// @param sender The caller that initialized the proxy.
    /// @param config The initialization configuration.
    event MorphoProtocolAdapterInitialized(address indexed sender, MorphoProtocolAdapterConfig config);
    /// @notice Emitted when the registry reference is updated.
    /// @param oldRegistry The previous registry address.
    /// @param newRegistry The new registry address.
    event RegistrySet(address indexed oldRegistry, address indexed newRegistry);
    /// @notice Emitted when the admin is changed.
    /// @param oldAdmin The previous admin address.
    /// @param newAdmin The new admin address.
    event AdminSet(address indexed oldAdmin, address indexed newAdmin);

    constructor() {
        _disableInitializers();
    }

    /// @notice Documents the typed signature of the initialize function. Per
    /// ICloneableV2 this overload MUST always revert; callers should use the
    /// `bytes calldata` overload instead.
    /// @dev Always reverts with `InitializeSignatureFn`.
    /// @param config The initialization configuration. Ignored.
    /// @return Never returns; included only for the function signature.
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
    /// @param newRegistry The new oracle registry address.
    function setRegistry(OracleRegistry newRegistry) external onlyAdmin {
        if (address(newRegistry) == address(0)) revert ZeroRegistry();
        emit RegistrySet(address(registry), address(newRegistry));
        registry = newRegistry;
    }

    /// @notice Update the admin address. Admin only.
    /// @dev One-step transfer — the new admin takes effect immediately. A
    /// wrong `newAdmin` will lock the adapter's governance permanently:
    /// `setRegistry` will become uncallable by the intended principal. The
    /// only recovery is `OracleRegistry.setOracle(vault, newOracle)` to
    /// redirect downstream protocols to a different `MorphoProtocolAdapter`
    /// proxy. Use a multisig that cannot be misaddressed.
    /// @param newAdmin The new admin address.
    function setAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAdmin();
        emit AdminSet(admin, newAdmin);
        admin = newAdmin;
    }

    /// @dev Expected upstream oracle decimals. Hard-coded because the `* 1e28`
    /// scaling factor below is derived from `36 - 8`.
    uint8 internal constant EXPECTED_ORACLE_DECIMALS = 8;

    /// @notice Returns the price scaled to 36 decimals as required by Morpho
    /// Blue.
    /// @return The price as uint256 scaled to 1e36.
    /// @dev Verifies the upstream oracle reports exactly
    /// `EXPECTED_ORACLE_DECIMALS` (= 8) before scaling. A registry swap to a
    /// non-8-decimal feed would otherwise silently mis-price by `10^N` —
    /// catch loudly with `UnexpectedOracleDecimals` instead.
    function price() external view override returns (uint256) {
        AggregatorV2V3Interface oracle = registry.getOracle(vault);
        if (address(oracle) == address(0)) revert OracleNotFound();

        uint8 oracleDecimals = oracle.decimals();
        if (oracleDecimals != EXPECTED_ORACLE_DECIMALS) {
            revert UnexpectedOracleDecimals(oracleDecimals, EXPECTED_ORACLE_DECIMALS);
        }

        int256 answer = oracle.latestAnswer();
        if (answer <= 0) revert NonPositivePrice();

        // Scale from 8 decimals to 36 decimals
        return uint256(answer) * 1e28;
    }
}
