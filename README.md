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

**Oracle layer** -- one `PythOracleAdapter` per vault, implements `AggregatorV3Interface` at 8 decimals. Prices vault shares as `pythPrice * totalAssets / totalSupply`. Governance controls (pause for corporate actions) live here.

**Registry layer** -- `OracleRegistry` maintains centralized `vault → oracle` mapping. Single `setOracle()` call updates the oracle for all protocol adapters serving that vault. Supports bulk updates via `setOracleBulk()`.

**Protocol layer** -- `PassthroughProtocolAdapter` (Aave/Compound/any Chainlink-compatible) and `MorphoProtocolAdapter` (scales 8 to 36 decimals). Each stores `registry + vault` and looks up oracle at runtime. Can opt-out via `setRegistry()` to point to an alternative registry.

**Deployers** -- beacon proxy pattern via `st0x.deploy`. `OracleUnifiedDeployer` deploys an oracle adapter + all protocol adapters for a new vault. Admin must call `registry.setOracle()` separately to register the oracle.

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
├── concrete/
│   ├── oracle/
│   │   └── PythOracleAdapter.sol
│   ├── registry/
│   │   └── OracleRegistry.sol
│   ├── protocol/
│   │   ├── MorphoProtocolAdapter.sol
│   │   └── PassthroughProtocolAdapter.sol
│   └── deploy/
│       ├── PythOracleAdapterBeaconSetDeployer.sol
│       ├── OracleRegistryBeaconSetDeployer.sol
│       ├── MorphoProtocolAdapterBeaconSetDeployer.sol
│       ├── PassthroughProtocolAdapterBeaconSetDeployer.sol
│       └── OracleUnifiedDeployer.sol
├── interface/
│   └── IAggregatorV3.sol
└── lib/
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

## Production Deployment (Base)

All production addresses are hardcoded in `src/lib/LibProdDeploy.sol`.

### Update Runbook

There are two paths depending on whether existing proxies are live in production.

#### Path A: Fresh deploy (pre-production / no live consumers)

When there are no live integrations depending on existing proxy addresses, it's simpler to redeploy everything from scratch.

1. **Redeploy required suites** — run `script/Deploy.sol` once per suite via the `DEPLOYMENT_SUITE` env var:
   ```bash
   export DEPLOYMENT_KEY=<key>
   export DEPLOYMENT_SUITE=pyth-oracle-adapter-beacon-set
   nix develop -c forge script script/Deploy.sol \
     --rpc-url <base-rpc> --broadcast --verify
   ```
   Repeat for each suite as needed:
   - `morpho-protocol-adapter-beacon-set`
   - `passthrough-protocol-adapter-beacon-set`
   - `oracle-unified-deployer`
   - `oracle-registry-beacon-set`
   - `multi-pyth-oracle-adapter-beacon-set`
   - `multi-oracle-unified-deployer`
2. **Deploy a new OracleRegistry** — if the registry ABI changed, or to start clean
3. **Update `LibProdDeploy.sol`** — replace all address constants with the new deployments, with date + run ID comments
4. **Re-register vault oracles** — call `registry.setOracle()` (or `setOracleBulk()`) for each vault
5. **Update the front end** — update the subgraph URL in [sft-tokenisation](https://github.com/h20liquidity/sft-tokenisation) to point to the new subgraph deployment
6. **Redeploy the subgraph** — trigger the "Deploy subgraph" workflow (GitHub Actions, network: `base`). Update `subgraph.yaml` with new contract addresses if they changed
7. **Verify** — check `latestRoundData()` on a proxy and confirm the subgraph is indexing

#### Path B: Production upgrade (live proxies serving consumers)

When existing proxies are live and their addresses are referenced by external protocols (Morpho, Aave, etc.), use the beacon upgrade path to avoid changing addresses.

1. **Deploy new implementation** — run the matching suite:
   ```bash
   export DEPLOYMENT_KEY=<key>
   export DEPLOYMENT_SUITE=pyth-oracle-adapter-beacon-set
   nix develop -c forge script script/Deploy.sol \
     --rpc-url <base-rpc> --broadcast --verify
   ```
   Use `multi-pyth-oracle-adapter-beacon-set` for multi-feed adapters.
2. **Upgrade the beacon** — call `upgradeTo(newImplementation)` on the existing beacon from the current beacon owner (see `BEACON_INITIAL_OWNER` in `LibProdDeploy.sol`). All existing proxy instances upgrade in-place — no per-vault redeployment needed
3. **Update `LibProdDeploy.sol`** — update the relevant deployer address constant with date + run ID
4. **Verify on-chain** — confirm the upgrade took effect:
   ```bash
   cast call <any-existing-proxy> "latestRoundData()(uint80,int256,uint256,uint256,uint80)" --rpc-url <base-rpc>
   ```
5. **Update the front end** — update the subgraph URL in [sft-tokenisation](https://github.com/h20liquidity/sft-tokenisation) to point to the new subgraph deployment
6. **Redeploy the subgraph** — trigger the "Deploy subgraph" workflow to pick up ABI changes
7. **Verify the subgraph** — check Goldsky dashboard or query the endpoint to confirm data is flowing

### Adding a new vault oracle

To deploy oracle + protocol adapters for a new vault:

1. Call `OracleUnifiedDeployer.deploy(...)` (or `MultiOracleUnifiedDeployer` for multi-feed) with the vault address, Pyth feed ID(s), and protocol adapter config
2. Call `OracleRegistry.setOracle(vault, oracleAdapter)` from the registry admin to register the new oracle
3. Redeploy the subgraph to index the new contracts

## Dependencies

- [rain.pyth](https://github.com/rainlanguage/rain.pyth) -- `LibPyth.getPriceFeedContract()` and price feed ID constants
- [pyth-sdk-solidity](https://github.com/pyth-network/pyth-sdk-solidity) -- `IPyth`, `PythStructs`
- [st0x.deploy](https://github.com/S01-Issuer/st0x.deploy) -- `BeaconSetDeployer` pattern, `ICloneableV2`
- [openzeppelin-contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) -- `UpgradeableBeacon`, `BeaconProxy`, `Initializable`

## License

DCL-1.0
