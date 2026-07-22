# st0x.oracle

DIA-backed oracle stack for pricing ST0x `wtStock` ERC-4626 vault shares inside
DeFi lending protocols (Euler, Aave V3, Compound V3, any Chainlink-compatible
market). Exposes a single proxy address per vault behind
`AggregatorV2V3Interface`.

## Architecture

A single consumer-facing contract per vault. **`DIAVaultOracle`** reads the
underlying-equity price from a DIA Data Association feed (keyed by bare symbol —
`"COIN"`, `"AMZN"`, `"TSLA"`, not a pair string), multiplies by the vault's
`totalAssets / totalSupply` ratio, returns an 8-decimal `int256` — and
auto-pauses reads around scheduled corporate actions by consulting
`ICorporateActionsV1` on every read (via `LibCorporateActionsPause`). Every ST0x
token implements corporate actions, so the auto-pause is mandatory; there is no
manual pause and no admin.

```
             ┌───────────────────────────────────┐
consumers ──▶│           DIAVaultOracle          │   ← canonical address
             │        AggregatorV2V3Interface     │
             │   diaOracle.getValue(symbol)       │
             │     × totalAssets / totalSupply    │
             │   + corporate-action auto-pause    │
             └─────────┬──────────────────┬───────┘
                       ▼                  ▼
              ┌────────────────┐  ┌──────────────────┐
              │  IDIAOracleV2  │  │ ICorporateActionsV1│
              └────────────────┘  └──────────────────┘
```

**Flagship features:**

- **Corporate-action auto-pause.** The oracle consults `ICorporateActionsV1` on
  every read. Inside a configured pre/post window of any matching scheduled or
  completed action (stock splits, dividends, ...), reads revert
  `OraclePausedCorporateAction(effectiveTime)`. Lending markets that catch the
  revert treat the price as unavailable for the window — no borrows, no
  liquidations across a NAV-rebalance boundary. The corporate-actions vault
  (`ICorporateActionsV1`) is **derived** as the priced vault's `asset()` — the
  tStock the wtStock wraps — not a separate config field, and the auto-pause is
  mandatory.
- **`wtStock` NAV tracking via `convertToAssets`.** The
  `totalAssets /
  totalSupply` factor is exactly ERC-4626
  `convertToAssets(1 share)`. Post-split rebalances inside the underlying
  `tStock` vault flow through to the share price automatically on the first read
  after the pause window closes — no oracle-side intervention.

**DIA freshness model:** DIA pushes a new value whenever **either** 0.1%
deviation OR 1 hour elapsed (whichever first). Volatile periods get pushes every
few minutes; the 1-hour heartbeat is the dead-market floor. Recommended
`maxAge = 2 hours` (one missed heartbeat tolerance).

**DIA on Base mainnet:** the canonical oracle contract is
`0xCE521b52513242c5094bc56f57887BB2A05B8129`. Per-symbol feeds are all served
from this single contract via `getValue(string key)` and the key is the bare
symbol (e.g. `"COIN"`).

See `SPEC.md` for the full specification.

## Integrator Quickstart

Mint a `DIAVaultOracle` for a new vault through its beacon-set deployer:

```solidity
DIAVaultOracle oracle = diaVaultOracleBeaconSetDeployer.newDIAVaultOracle(
    DIAVaultOracleConfig({
        diaOracle:       IDIAOracleV2(0xCE521b52513242c5094bc56f57887BB2A05B8129),
        symbol:          "COIN",
        vault:           wtStockVault,  // ICorporateActionsV1 derived from vault.asset()
        maxAge:          2 hours,
        actionTypeMask:  type(uint256).max,
        pauseTimeBefore: 1 hours,
        pauseTimeAfter:  2 hours
    })
);
```

Hand `address(oracle)` to consumers as the `AggregatorV2V3Interface` source they
already plug Chainlink feeds into.

## Operational Preconditions for Consumers

Anything that wraps reads in `try / catch` (Aave-style consumers) must respect
two constraints, or the pause feature is silently defeated:

1. **No fallback oracle on the same priced asset.** A fallback that catches our
   pause revert and serves a raw DIA / raw Chainlink / raw anything price masks
   the exact failure mode the auto-pause exists to surface. The pause must reach
   the protocol as `OraclePriceNotFound` or equivalent, never get swallowed.
2. **Consumer's `maxPriceAge` ≥ the oracle's `maxAge`.** Otherwise the
   consumer's staleness check rejects the read before our internal
   `DIAPriceStale(timestamp)` revert can surface, and the deployment loses the
   layered staleness signal. Set the consumer's threshold to be at least the
   oracle's `maxAge`.

## Signed-Price Stack

Alongside the DIA stack, the repo ships a publisher-signed price stack for
Morpho Blue markets:

- **`ST0xPriceOracle`** — singleton multi-pair price store behind a beacon
  proxy. Pair ids are deterministic (`keccak256(abi.encodePacked(base, quote))`,
  no registration); values are opaque `uint256`s whose scaling belongs to the
  publisher. `updatePrice` is permissionless — a global publisher's EIP-712
  signature authorises each update, replay-protected by a strict per-pair
  timestamp inequality (stale payloads no-op, future-dated payloads revert). The
  EIP-712 domain deliberately binds name + version only, so one signed payload
  serves every chain the oracle is deployed on. Global `signer` / `timeout`
  rotate via `ORACLE_ADMIN_ROLE`-gated setters.
- **`MorphoPairOracle`** — beacon-proxied adapter exposing one pair on the
  central store through Morpho Blue's `IOracle.price()`. It owns the decimal
  conversion: the publisher signs an 18-decimal (`PUBLISHER_DECIMALS`)
  whole-token ratio and the adapter rescales it into Morpho's
  `1e36·10^loanDec/10^collDec` convention using the pair tokens' on-chain
  decimals. One shared beacon upgrade retargets every deployed adapter at once.

## Setup

This project uses Nix flakes for a reproducible toolchain.

```bash
nix develop
forge soldeer install   # first time only: dependencies/ is gitignored
```

## Build & Test

```bash
forge build
forge test
forge test -vvv          # verbose
forge fmt --check        # check formatting
```

## Repository Structure

```
script/
└── Deploy.sol                       (DEPLOYMENT_SUITE dispatch for CI deploys)
src/
├── concrete/
│   ├── oracle/
│   │   ├── DIAVaultOracle.sol       (prices wtStock + corporate-action auto-pause)
│   │   ├── ST0xPriceOracle.sol
│   │   └── MorphoPairOracle.sol
│   └── deploy/
│       ├── DIAVaultOracleBeaconSetDeployer.sol
│       ├── ST0xPriceOracleBeaconSetDeployer.sol
│       └── MorphoPairOracleBeaconSetDeployer.sol
├── interface/
│   ├── IDIAOracleV2.sol         (vendored DIA Data Association's published interface)
│   ├── IAggregatorV2V3.sol      (vendored Chainlink shape)
│   └── IOracle.sol              (vendored Morpho Blue oracle shape)
└── lib/
    └── LibCorporateActionsPause.sol
test/
├── mocks/
└── src/
    ├── concrete/{oracle,deploy}/
    ├── lib/
    ├── script/
    └── e2e/
```

## Dependencies

- DIA Data Association's published `IDIAOracleV2` interface — vendored locally
- [st0x.deploy](https://github.com/S01-Issuer/st0x.deploy) --
  `ICorporateActionsV1`, BeaconSetDeployer pattern, `ICloneableV2`
- [rain-math-float](https://github.com/rainlanguage/rain.math.float) --
  decimal-float arithmetic for the share-price computation
- [openzeppelin-contracts](https://github.com/OpenZeppelin/openzeppelin-contracts)
  -- `UpgradeableBeacon`, `BeaconProxy`, `Initializable`, `IERC4626`

## License

DCL-1.0
