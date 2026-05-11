# CLAUDE.md - ST0x Oracle Development Guide

## Project Overview

Solidity oracle adapter system that prices ERC-4626 vault shares by combining Pyth Network price feeds with vault share ratios, for DeFi lending protocols (Morpho Blue, Aave V3, Compound V3). Three-layer architecture: oracle adapters (price source), oracle registry (centralized vault→oracle mapping), and protocol adapters (protocol-specific interface). The oracle computes `vaultSharePrice = pythPrice * totalAssets / totalSupply`. Single-feed (`PythOracleAdapter`) and multi-feed cascading (`MultiPythOracleAdapter`) variants share an abstract `BasePythOracleAdapter`. Both expose an auto-pause mechanism keyed off the vault's `ICorporateActionsV1` schedule, reverting with `OraclePausedCorporateAction(uint64 effectiveTime)` when a scheduled action sits inside its pre- or post-window; the manual admin flag remains as the independent `OraclePausedManual()` escape hatch.

## Environment Setup

This project uses Nix flakes for reproducible toolchain management (Foundry, solc, etc.) via the `rainix` flake. **Always enter the nix shell before running any commands.**

```bash
nix develop          # Enter the nix dev shell (provides forge, solc, etc.)
```

If `nix develop` is not available, use `nix-shell` or ensure `direnv` is configured to auto-load the flake.

## Build & Test

All commands below assume you are inside the nix dev shell.

```bash
forge build          # Compile contracts
forge test           # Run all tests
forge test -vvv      # Verbose test output
forge fmt            # Format Solidity code
forge fmt --check    # Check formatting without modifying
```

## Architecture (Three Layers)

**Oracle Layer** — canonical price source per vault, implements `AggregatorV2V3Interface` (8 decimals):
- `BasePythOracleAdapter` (abstract) — shared logic for conservative pricing (price - confidence), vault-share-ratio scaling via `LibDecimalFloat`, admin/manual-pause governance, and `ICorporateActionsV1` auto-pause via `LibCorporateActionsPause`. Subclasses only implement `_getPriceData()`.
- `PythOracleAdapter` — single-feed concrete. Fully immutable post-init; only governance is `setPaused` / `setAdmin`.
- `MultiPythOracleAdapter` — cascading multi-feed variant. Tries up to 8 feeds in order, returns the first non-stale price. Admin can `setFeeds` and `setMaxAge` (per-feed). Used for equities with separate session feeds (regular / pre-market / post-market / overnight).
- Both adapters revert via two distinct selectors: `OraclePausedManual()` (admin set the manual flag) and `OraclePausedCorporateAction(uint64 effectiveTime)` (a matching `ICorporateActionsV1` action's pre- or post-window is open). The auto-pause logic lives in `src/lib/LibCorporateActionsPause.sol` and is driven by `corporateActionsVault` / `actionTypeMask` / `pauseTimeBefore` / `pauseTimeAfter`, all immutable after initialize.

**Registry Layer** — centralized vault→oracle mapping:
- `OracleRegistry` — maintains `vault → oracle adapter` mapping, allows admin to update oracles for all protocol adapters at once via single `setOracle()` call

**Protocol Layer** — indirection so oracle swaps don't require protocol governance:
- `PassthroughProtocolAdapter` — for Aave/Compound/any Chainlink-compatible protocol, looks up oracle from registry
- `MorphoProtocolAdapter` — implements Morpho's `IOracle.price()`, looks up oracle from registry, scales 8→36 decimals

**Deployers** — beacon proxy pattern per `st0x.deploy`:
- Each contract type has a `BeaconSetDeployer` that owns a beacon and deploys proxies
- `OracleUnifiedDeployer` orchestrates deploying a single-feed oracle + all protocol adapters for a new vault
- `MultiOracleUnifiedDeployer` is the same flow for multi-feed oracles (uses `MultiPythOracleAdapterBeaconSetDeployer`)

## Key Design Decisions

- **Vault-aware pricing**: Oracle stores an ERC-4626 vault address and prices shares as `pythPrice * totalAssets / totalSupply`
- **No stored Pyth address**: Use `LibPyth.getPriceFeedContract(block.chainid)` at runtime (from `rain.pyth`)
- **AggregatorV3Interface as boundary**: Industry standard between oracle and protocol layers
- **Beacon proxies**: All instances share implementations, upgradeable via beacon owner
- **Registry-based oracle lookup**: Protocol adapters store `registry + vault`, look up oracle via `registry.getOracle(vault)` at runtime
- **Single registry update propagates everywhere**: Calling `registry.setOracle(vault, newOracle)` updates the oracle for all protocol adapters serving that vault
- **"Opt out" via setRegistry**: Protocol adapters can point to a different registry entirely via `setRegistry()`
- **Two-step deployment**: `OracleUnifiedDeployer` deploys oracle + adapters, admin calls `registry.setOracle()` separately
- **Two protocol adapter contracts, not three**: `PassthroughProtocolAdapter` serves Aave, Compound, and any future Chainlink-compatible protocol via separate proxy instances

## Repository Structure

```
src/
├── abstract/
│   └── BasePythOracleAdapter.sol           # shared base for both oracle adapters
├── concrete/
│   ├── oracle/
│   │   ├── PythOracleAdapter.sol           # Single-feed concrete, AggregatorV2V3Interface
│   │   └── MultiPythOracleAdapter.sol      # Multi-feed cascading variant
│   ├── registry/
│   │   └── OracleRegistry.sol              # Centralized vault→oracle mapping
│   ├── protocol/
│   │   ├── MorphoProtocolAdapter.sol       # IOracle, scales 8→36, uses registry
│   │   └── PassthroughProtocolAdapter.sol  # AggregatorV2V3Interface passthrough, uses registry
│   └── deploy/
│       ├── PythOracleAdapterBeaconSetDeployer.sol
│       ├── MultiPythOracleAdapterBeaconSetDeployer.sol
│       ├── OracleRegistryBeaconSetDeployer.sol
│       ├── MorphoProtocolAdapterBeaconSetDeployer.sol
│       ├── PassthroughProtocolAdapterBeaconSetDeployer.sol
│       ├── OracleUnifiedDeployer.sol
│       └── MultiOracleUnifiedDeployer.sol
├── interface/
│   └── IAggregatorV2V3.sol                 # Hand-typed Chainlink-compatible interface
└── lib/
    ├── LibCorporateActionsPause.sol        # Auto-pause reader (consults ICorporateActionsV1)
    └── LibProdDeploy.sol
```

## Dependencies

- `rain.pyth` — `LibPyth.getPriceFeedContract()` and price feed ID constants
- `pyth-sdk-solidity` — `IPyth`, `PythStructs`
- `st0x.deploy` — `BeaconSetDeployer` pattern, `ICloneableV2`, `ICorporateActionsV1` (consumed by `LibCorporateActionsPause`)
- `openzeppelin-contracts` — `UpgradeableBeacon`, `BeaconProxy`, `Initializable`, `IERC4626`

## Security Rules

- Pyth prices can be negative — always revert on `answer <= 0`
- Scaling math must not overflow — use checked arithmetic
- `maxAge` must be enforced on every price read
- Vault with zero total supply must revert (no valid price)
- Pause mechanism for corporate actions (splits, dividends)
- All admin roles held by founder multisig, no role separation
- Protocol adapters revert with `OracleNotFound` if vault not registered in registry

## Conventions

- Follow Foundry/forge-std conventions for tests
- Contract names match filenames exactly
- Use `I_` prefix for immutable beacon references (e.g., `I_PYTH_ORACLE_ADAPTER_BEACON`)
- Initializable pattern for proxy contracts (not constructors for state)
- Full spec is in `SPEC.md` — refer to it for detailed implementation guidance
