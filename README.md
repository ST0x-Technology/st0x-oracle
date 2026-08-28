# st0x.oracle

Oracle contracts for pricing ST0x tokenized equities on-chain.

The repo houses one oracle-adapter stack — the **DIA stack** — which prices
`wtStock` ERC-4626 vault shares for Chainlink-compatible lending markets (Euler,
Aave V3, Compound V3), one proxy address per vault behind
`AggregatorV2V3Interface`. Additional oracle adapters (other price sources,
other consumer conventions) may be added over time; each follows this same
pattern — a self-contained consumer-facing contract per vault, minted through
its own beacon-set deployer.

## DIA stack

A single consumer-facing contract per vault. **`DIAVaultOracle`** reads the
underlying-equity price from a DIA Data Association feed (keyed by bare symbol —
`"COIN"`, `"AMZN"`, `"TSLA"`, not a pair string), multiplies by the vault's
`totalAssets / totalSupply` ratio, returns an 8-decimal `int256` — and
auto-pauses reads around scheduled corporate actions by consulting
`ICorporateActionsV1` on every read (via `LibCorporateActionsPause`). Every ST0x
token implements corporate actions, so the auto-pause is mandatory; there is no
manual pause and no admin.

```text
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
- **`wtStock` NAV tracking.** The `totalAssets /
  totalSupply` factor is the
  vault's raw ERC-4626 assets-per-share ratio (equal to
  `convertToAssets(1 share)` up to OpenZeppelin's virtual-offset rounding).
  Post-split rebalances inside the underlying `tStock` vault flow through to the
  share price automatically on the first read after the pause window closes — no
  oracle-side intervention.

**DIA freshness model:** DIA pushes a new value whenever **either** 0.1%
deviation OR 1 hour elapsed (whichever first). Volatile periods get pushes every
few minutes; the 1-hour heartbeat is the dead-market floor. Recommended
`maxAge = 2 hours` (one missed heartbeat tolerance).

> **⚠️ Required config invariant: `pauseTimeAfter > maxAge` (STRICTLY)**
> (enforced at `initialize` — a violating config, including the equal boundary,
> reverts `PauseTimeAfterBelowMaxAge`). The share price multiplies the DIA
> equity price by the vault's _live_ NAV ratio, and both must belong to the same
> corporate-action epoch. When an action completes the ratio rebalances
> instantly, but DIA can keep serving the pre-action price for up to `maxAge`.
> Only the post-window pause separates the two; if it lifts while a pre-action
> price is still fresh, that price pairs with the post-action ratio — on a 2:1
> split the share reads ~2× its true value, enabling over-borrow (bad debt).
>
> The margin `pauseTimeAfter - maxAge` is the maximum forward DIA feed clock
> skew the config tolerates. Staleness is aged from the push's own _source_
> timestamp, so a feed running `skew` seconds fast can stamp a pre-action
> observation up to `skew` after `effectiveTime`; only a margin exceeding that
> skew guarantees every still-acceptable push at pause-lift was observed at or
> after the action. Equality (`pauseTimeAfter == maxAge`) tolerates **zero**
> skew — a feed even one second fast reopens the 2× window — so it is rejected.
> Size the margin above your feed's worst-case forward skew; the recommended
> `maxAge = 2 hours` with `pauseTimeAfter = 3 hours` (a 1h margin) is the
> reference.

> **⚠️ `pauseTimeBefore` is also mandatory (non-zero, enforced at `initialize` —
> `ZeroPauseTimeBefore`).** The market revalues at the ex-date, which precedes
> the on-chain `effectiveTime`, so DIA can publish the post-action equity price
> against the still-pre-action vault ratio. Only the pre-window pauses reads
> across that interval. Size it above the worst-case ex-date → `effectiveTime`
> lead, and schedule actions with more notice than `pauseTimeBefore` — the
> oracle cannot enforce scheduling lead time (see `ZeroPauseTimeBefore`
> NatSpec).

**DIA on Base mainnet:** the canonical oracle contract address is the
`DIA_FEED_BASE` constant in [`src/lib/LibDIAFeed.sol`](src/lib/LibDIAFeed.sol) —
the single source of truth; import it rather than pasting the literal.
Per-symbol feeds are all served from this single contract via
`getValue(string key)` and the key is the bare symbol (e.g. `"COIN"`).

### Integrator Quickstart

Mint a `DIAVaultOracle` for a new vault through its beacon-set deployer:

```solidity
// DIA_FEED_BASE is the canonical Base feed address, from src/lib/LibDIAFeed.sol.
DIAVaultOracle oracle = diaVaultOracleBeaconSetDeployer.newDIAVaultOracle(
    DIAVaultOracleConfig({
        diaOracle:       IDIAOracleV2(DIA_FEED_BASE),
        symbol:          "COIN",
        vault:           wtStockVault,  // ICorporateActionsV1 derived from vault.asset()
        maxAge:          2 hours,
        actionTypeMask:  type(uint256).max,
        pauseTimeBefore: 1 hours,  // non-zero required; size above the ex-date → effectiveTime lead
        pauseTimeAfter:  3 hours  // > maxAge, with a skew margin (see invariant above)
    })
);
```

Hand `address(oracle)` to consumers as the `AggregatorV2V3Interface` source they
already plug Chainlink feeds into.

> **⚠️ Instance authenticity:** minting through the beacon-set deployers is
> **permissionless**, and the CREATE2 salt commits to the config alone — so an
> attacker can mint a proxy with an arbitrary config that sits behind the same
> governance-owned beacon and emits the same `Deployment` event as an official
> instance. Neither beacon membership nor a `Deployment` event authenticates
> anything: the **only** authenticity signal is, in theory, a published
> deployment address list — wire consumers from it, never from event or beacon
> scans. Nothing is deployed to production yet, so the concrete home of that
> list (deploy artifacts, `.sol` constants, or a docs page) is TBC along with
> the rest of the ops process; until it exists, treat no instance as canonical.

### Operational Preconditions for Consumers

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
3. **Size liquidation parameters against downward jump risk.** The priced
   vault's `totalAssets()` is a raw token balance, and the upstream
   receipt-vault confiscation role (an RWA regulatory capability) can move it
   DOWN discontinuously — a plain transfer that creates no corporate-action
   node, so the auto-pause does not bracket it and the share price steps down
   inside a single block. The lower price is arithmetically correct; what a
   confiscation removes is the warning window borrowers would otherwise have to
   top up. This is an accepted risk: choose LLTV margins and liquidation bonuses
   as you would for any asset with jump risk, and see the contract NatSpec
   ("Vault trust model") for the operational rule that a wrapper-vault
   confiscation must be preceded by a scheduled corporate action so the pause
   brackets the discontinuity.

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

```text
script/
└── Deploy.sol                       (DEPLOYMENT_SUITE dispatch for CI deploys)
src/
├── concrete/
│   ├── oracle/
│   │   └── DIAVaultOracle.sol       (prices wtStock + corporate-action auto-pause)
│   └── deploy/
│       └── DIAVaultOracleBeaconSetDeployer.sol
├── interface/
│   ├── IDIAOracleV2.sol         (vendored DIA Data Association's published interface)
│   └── IAggregatorV2V3.sol      (vendored Chainlink shape)
└── lib/
    ├── LibCorporateActionsPause.sol
    └── LibDIAFeed.sol           (single source of truth: DIA Base feed address)
test/
├── mocks/
└── src/
    ├── concrete/{oracle,deploy}/
    ├── lib/
    ├── fork/
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
