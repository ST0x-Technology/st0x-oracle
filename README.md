# st0x.oracle

Oracle adapter system that bridges Pyth Network price feeds to DeFi lending protocols (Morpho Blue, Aave V3, Compound V3). Three-layer architecture: oracle adapters (price source), oracle registry (centralized vault→oracle mapping), and protocol adapters (protocol-specific interface). Allows independent upgrades, oracle swaps via single registry update, and protocol adapters that can opt-out to alternative registries.

## Architecture

```
  PROTOCOL ADAPTERS (looks up oracle from registry)

  ┌───────────────────────┐   ┌──────────────────────────────────────┐
  │ MorphoProtocolAdapter │   │ PassthroughProtocolAdapter           │
  │ IOracle (8→36 dec)    │   │ (instances: Aave, Compound, ...)     │
  │                       │   │ AggregatorV3Interface passthrough    │
  │ stores: registry,     │   │                                      │
  │         vault         │   │ stores: registry, vault              │
  └──────────┬────────────┘   └──────────────────┬───────────────────┘
             │                                   │
             └────────────────┬──────────────────┘
                              │
                              ▼
                  ┌───────────────────────┐
                  │    OracleRegistry     │  ← centralized vault→oracle mapping
                  │                       │
                  │  getOracle(vault)     │
                  │  setOracle(vault, o)  │
                  │  setOracleBulk(...)   │
                  └───────────┬───────────┘
                              │
                              ▼
                  ┌───────────────────────┐
                  │ AggregatorV3Interface │  ← contract boundary
                  └───────────────────────┘
                              ▲
                              │
                    ┌─────────┴─────────┐
                    │                   │
                    ▼                   ▼
  ┌──────────────────────┐   ┌──────────────────────┐
  │ PythOracleAdapter    │   │ Future adapters      │
  │ Pyth → 8 dec         │   │ (Chainlink etc)      │
  │ pause, admin         │   │                      │
  └──────────────────────┘   └──────────────────────┘

  ORACLE ADAPTERS (canonical price source per asset)
```

**Oracle layer** -- one `PythOracleAdapter` (or `MultiPythOracleAdapter` for near-24/7 multi-feed coverage) per vault, implements `AggregatorV3Interface` at 8 decimals. Prices vault shares as `pythPrice * totalAssets / totalSupply`. Two pause mechanisms: a manual admin flag, and an automatic corporate-action-aware pause that reads the vault's `ICorporateActionsV1` schedule on every price call -- see [§ Integrator notes: corporate actions](#integrator-notes-corporate-actions).

**Registry layer** -- `OracleRegistry` maintains centralized `vault → oracle` mapping. Single `setOracle()` call updates the oracle for all protocol adapters serving that vault. Supports bulk updates via `setOracleBulk()`.

**Protocol layer** -- `PassthroughProtocolAdapter` (Aave/Compound/any Chainlink-compatible) and `MorphoProtocolAdapter` (scales 8 to 36 decimals). Each stores `registry + vault` and looks up oracle at runtime. Can opt-out via `setRegistry()` to point to an alternative registry.

**Deployers** -- beacon proxy pattern via `st0x.deploy`. `OracleUnifiedDeployer` deploys an oracle adapter + all protocol adapters for a new vault. Admin must call `registry.setOracle()` separately to register the oracle.

## Integrator notes: corporate actions

A scheduled corporate action (today: stock splits) on the underlying vault makes Pyth's price feed and the on-chain rebased balances **temporarily out of sync** -- Pyth split-adjusts its feed asynchronously, and downstream RPC and indexer caches take additional time to catch up. To prevent stale prices being read during this window, the oracle reads the vault's `ICorporateActionsV1` interface on every `latestAnswer` / `latestRoundData` call and reverts when an action falls inside a configurable window around its `effectiveTime`.

Two distinct error selectors let integrators distinguish the cause:

```solidity
error OraclePausedManual();                                 // admin called setPaused(true)
error OraclePausedCorporateAction(uint64 effectiveTime);    // auto-pause window is open
```

`OraclePausedCorporateAction` carries the `effectiveTime` of the action whose window is currently open, so an integrator can surface "oracle paused for action at HH:MM:SS" without a separate storage read. When both a pending and a completed action's window overlap `now`, the **pending** action's `effectiveTime` is reported -- integrators see the next event coming, not the last one done.

Lending-market behaviour during the pause window:

- **Morpho Blue, Aave V3, Compound V3** -- a reverting oracle call is observable to the protocol's health-check / liquidation paths. The position becomes effectively frozen against the oracle: borrows revert, liquidations revert, repayments and supply-side actions that don't read the oracle are unaffected. This is intentional. See SPEC § 16 for the full behaviour table.

If your protocol cannot tolerate a reverting oracle for the duration of a corporate-action window, do not integrate against this oracle directly -- instead consume the wrapped vault's price through `convertToAssets` on the ERC-4626 wrapper, which captures the rebase atomically.

The full design is in [SPEC.md § 16](./SPEC.md#16-corporate-action-aware-auto-pause).

## Setup

This project uses Nix flakes for reproducible toolchain management.

```bash
nix develop
```

## Build & Test

```bash
forge build
forge test
forge test -vvv          # verbose
forge fmt --check        # check formatting
```

Fork tests require a Base RPC URL:

```bash
export RPC_URL_BASE_FORK=<your-base-rpc-url>
forge test
```

## Repository Structure

```
src/
├── abstract/
│   └── BasePythOracleAdapter.sol         # shared base for both oracle adapters
├── concrete/
│   ├── oracle/
│   │   ├── PythOracleAdapter.sol
│   │   └── MultiPythOracleAdapter.sol    # multi-feed cascading variant
│   ├── registry/
│   │   └── OracleRegistry.sol
│   ├── protocol/
│   │   ├── MorphoProtocolAdapter.sol
│   │   └── PassthroughProtocolAdapter.sol
│   └── deploy/
│       ├── PythOracleAdapterBeaconSetDeployer.sol
│       ├── MultiPythOracleAdapterBeaconSetDeployer.sol
│       ├── OracleRegistryBeaconSetDeployer.sol
│       ├── MorphoProtocolAdapterBeaconSetDeployer.sol
│       ├── PassthroughProtocolAdapterBeaconSetDeployer.sol
│       ├── OracleUnifiedDeployer.sol
│       └── MultiOracleUnifiedDeployer.sol
├── interface/
│   └── IAggregatorV3.sol
└── lib/
    ├── LibCorporateActionsPause.sol      # auto-pause reader (consults ICorporateActionsV1)
    └── LibProdDeploy.sol
test/
├── abstract/
│   ├── PythOracleAdapterTest.sol
│   └── OracleRegistryTest.sol
├── lib/
│   └── LibFork.sol
└── src/
    └── concrete/
        ├── deploy/
        ├── oracle/
        ├── registry/
        └── protocol/
```

## Dependencies

- [rain.pyth](https://github.com/rainlanguage/rain.pyth) -- `LibPyth.getPriceFeedContract()` and price feed ID constants
- [pyth-sdk-solidity](https://github.com/pyth-network/pyth-sdk-solidity) -- `IPyth`, `PythStructs`
- [st0x.deploy](https://github.com/S01-Issuer/st0x.deploy) -- `BeaconSetDeployer` pattern, `ICloneableV2`
- [openzeppelin-contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) -- `UpgradeableBeacon`, `BeaconProxy`, `Initializable`

## License

DCL-1.0
