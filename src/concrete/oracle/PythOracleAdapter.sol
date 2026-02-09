// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {IPyth} from "pyth-sdk/IPyth.sol";
import {PythStructs} from "pyth-sdk/PythStructs.sol";
import {LibPyth} from "rain.pyth/src/lib/pyth/LibPyth.sol";
import {LibDecimalFloat, Float} from "rain.math.float/lib/LibDecimalFloat.sol";
import {ICLONEABLE_V2_SUCCESS, ICloneableV2} from "rain.factory/interface/ICloneableV2.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {AggregatorV3Interface} from "src/interface/IAggregatorV3.sol";

/// @dev Error raised when the oracle is paused.
error OraclePaused();

/// @dev Error raised when the conservative price (price - confidence) is not
/// positive.
error NonPositivePrice(int256 price);

/// @dev Error raised when a zero address is provided for the vault.
error ZeroVault();

/// @dev Error raised when a zero price ID is provided.
error ZeroPriceId();

/// @dev Error raised when a zero max age is provided.
error ZeroMaxAge();

/// @dev Error raised when the caller is not the admin.
error OnlyAdmin();

/// @dev Error raised when a zero address is provided for the admin.
error ZeroAdmin();

/// @dev Error raised when the vault has zero total supply (no shares minted).
error ZeroVaultSupply();

/// @dev Error raised when the computed vault share price is zero.
error ZeroVaultSharePrice();

/// @title PythOracleAdapterConfig
/// @notice Configuration for PythOracleAdapter initialization.
/// @param vault The ERC-4626 vault address this oracle prices shares for.
/// @param priceId The Pyth price feed ID for the underlying asset.
/// @param maxAge Maximum acceptable price age in seconds.
/// @param admin The admin address for governance.
struct PythOracleAdapterConfig {
    address vault;
    bytes32 priceId;
    uint256 maxAge;
    address admin;
}

/// @title PythOracleAdapter
/// @notice Oracle adapter that prices ERC-4626 vault shares by fetching the
/// underlying asset price from Pyth Network and multiplying by the vault's
/// assets-per-share ratio. Exposes prices via Chainlink's
/// AggregatorV3Interface. This is the canonical oracle per vault.
/// Configuration (priceId, maxAge) is set once at initialization and is
/// immutable thereafter - deploy a new proxy to change config and update
/// protocol adapters via setOracle. Only governance is pause/unpause.
/// Pyth contract address is NOT stored - derived at runtime from
/// LibPyth.getPriceFeedContract(block.chainid).
/// Uses conservative pricing (price - confidence interval) per rain.pyth
/// patterns. Scaling uses LibDecimalFloat for audited precision.
///
/// Price formula: vaultSharePrice = pythPrice * totalAssets / totalSupply
contract PythOracleAdapter is AggregatorV3Interface, ICloneableV2, Initializable {
    /// @dev The ERC-4626 vault this oracle prices shares for.
    address public vault;
    /// @dev The Pyth price feed ID for the underlying asset.
    bytes32 public priceId;
    /// @dev Maximum acceptable price age in seconds.
    uint256 public maxAge;
    /// @dev Emergency pause flag.
    bool public paused;
    /// @dev Admin address for governance actions.
    address public admin;

    /// @dev Emitted when the oracle is initialized.
    event PythOracleAdapterInitialized(address indexed sender, PythOracleAdapterConfig config);
    /// @dev Emitted when the pause state changes.
    event PauseSet(bool isPaused);
    /// @dev Emitted when the admin is changed.
    event AdminSet(address indexed oldAdmin, address indexed newAdmin);

    constructor() {
        _disableInitializers();
    }

    /// As per ICloneableV2, this overload MUST always revert. Documents the
    /// signature of the initialize function.
    /// @param config The initialization configuration.
    function initialize(PythOracleAdapterConfig memory config) external pure returns (bytes32) {
        (config);
        revert InitializeSignatureFn();
    }

    /// @inheritdoc ICloneableV2
    function initialize(bytes calldata data) external initializer returns (bytes32) {
        PythOracleAdapterConfig memory config = abi.decode(data, (PythOracleAdapterConfig));

        if (config.vault == address(0)) revert ZeroVault();
        if (config.priceId == bytes32(0)) revert ZeroPriceId();
        if (config.maxAge == 0) revert ZeroMaxAge();
        if (config.admin == address(0)) revert ZeroAdmin();

        vault = config.vault;
        priceId = config.priceId;
        maxAge = config.maxAge;
        admin = config.admin;

        emit PythOracleAdapterInitialized(msg.sender, config);

        return ICLONEABLE_V2_SUCCESS;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    /// @inheritdoc AggregatorV3Interface
    function description() external pure override returns (string memory) {
        return "";
    }

    /// @inheritdoc AggregatorV3Interface
    function decimals() external pure override returns (uint8) {
        return 8;
    }

    /// @inheritdoc AggregatorV3Interface
    function version() external pure override returns (uint256) {
        return 1;
    }

    /// @inheritdoc AggregatorV3Interface
    // slither-disable-next-line pyth-unchecked-confidence
    function latestAnswer() external view override returns (int256) {
        _validateNotPaused();

        IPyth pyth = LibPyth.getPriceFeedContract(block.chainid);
        PythStructs.Price memory priceData = pyth.getPriceNoOlderThan(priceId, maxAge);

        // Confidence is checked in _vaultSharePrice -> _conservativeScaledPrice
        return _vaultSharePrice(priceData);
    }

    /// @inheritdoc AggregatorV3Interface
    // slither-disable-next-line pyth-unchecked-confidence
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        _validateNotPaused();

        IPyth pyth = LibPyth.getPriceFeedContract(block.chainid);
        // Confidence is checked in _vaultSharePrice -> _conservativeScaledPrice
        PythStructs.Price memory priceData = pyth.getPriceNoOlderThan(priceId, maxAge);

        int256 scaledPrice = _vaultSharePrice(priceData);

        return (
            1, // roundId - Pyth doesn't have rounds
            scaledPrice,
            uint256(uint64(priceData.publishTime)),
            uint256(uint64(priceData.publishTime)),
            1 // answeredInRound
        );
    }

    /// @notice Pause or unpause the oracle. Admin only.
    function setPaused(bool isPaused) external onlyAdmin {
        paused = isPaused;
        emit PauseSet(isPaused);
    }

    /// @notice Update the admin address. Admin only.
    /// @param newAdmin The new admin address.
    function setAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAdmin();
        emit AdminSet(admin, newAdmin);
        admin = newAdmin;
    }

    /// @dev Reverts if the oracle is paused.
    function _validateNotPaused() internal view {
        if (paused) revert OraclePaused();
    }

    /// @dev Computes conservative price (price - confidence) and scales to 8
    /// decimals using LibDecimalFloat. Reverts if the conservative price is not
    /// positive.
    /// @param priceData The Pyth price data.
    /// @return The conservative price scaled to 8 decimals.
    function _conservativeScaledPrice(PythStructs.Price memory priceData) internal pure returns (int256) {
        // Slither false positive, confidence is checked here.
        // slither-disable-next-line pyth-unchecked-confidence
        int256 conservativePrice = int256(priceData.price) - int256(uint256(priceData.conf));
        if (conservativePrice <= 0) {
            revert NonPositivePrice(conservativePrice);
        }
        // It is safe to pack lossless here because the price data uses only
        // 64 bits while we have 224 bits for a packed signed coefficient, and
        // the exponent bit size is the same for both.
        Float conservativePriceFloat = LibDecimalFloat.packLossless(conservativePrice, int256(priceData.expo));
        // We ignore precision loss here, truncating towards zero.
        //slither-disable-next-line unused-return
        (uint256 price8,) = LibDecimalFloat.toFixedDecimalLossy(conservativePriceFloat, 8);
        return int256(price8);
    }

    /// @dev Computes the vault share price by multiplying the conservative
    /// Pyth price by the vault's assets-per-share ratio.
    /// vaultSharePrice = pythPrice8 * totalAssets / totalSupply
    /// Reverts if the vault has zero total supply.
    /// @param priceData The Pyth price data.
    /// @return The vault share price at 8 decimals.
    function _vaultSharePrice(PythStructs.Price memory priceData) internal view returns (int256) {
        int256 price8 = _conservativeScaledPrice(priceData);

        IERC4626 vaultContract = IERC4626(vault);
        uint256 totalAssets = vaultContract.totalAssets();
        uint256 totalSupply = vaultContract.totalSupply();

        if (totalSupply == 0) revert ZeroVaultSupply();

        // Multiply before divide for precision. The 18-decimal units of
        // totalAssets and totalSupply cancel out, preserving the 8-decimal
        // scale of price8. Checked arithmetic guards against overflow.
        int256 vaultSharePrice = int256(uint256(price8) * totalAssets / totalSupply);

        if (vaultSharePrice == 0) revert ZeroVaultSharePrice();

        return vaultSharePrice;
    }
}
