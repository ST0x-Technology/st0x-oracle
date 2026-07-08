# ST0x Oracle Stack Specification

**Repository:** `st0x.oracle`
**Version:** 3.0
**Status:** Draft
**Date:** 2026-06-26

---

## 1. Problem Statement

ST0x issues wrapped tokenized equities — `wtStock` ERC-4626 vaults wrapping
`tStock` rebasing-receipt vaults — that need to be priced inside DeFi lending
protocols (Euler, Aave V3, Compound V3, future Chainlink-compatible
markets). Consumers already speak Chainlink's `AggregatorV2V3Interface`; the
oracle stack's job is to expose a single proxy address per vault that:

1. Returns an 8-decimal `int256` price for one share of the vault, denominated
   in USD, drawn from a market-grade off-chain feed for the underlying equity.
2. Tracks the vault's `totalAssets / totalSupply` ratio so the share price
   moves with any NAV change — most importantly the post-stock-split rebalance
   inside the underlying `tStock` vault.
3. Refuses to serve a price during scheduled corporate actions (splits,
   dividend distributions), so downstream lending markets can't liquidate or
   borrow against a stale-by-construction share price while the vault NAV is
   mid-rebalance.
4. Gives ST0x governance a manual emergency pause independent of the
   corporate-action machinery.

The previous architecture (Pyth + per-protocol adapters + a registry indirection
layer) has been replaced. Chronicle Protocol now supplies the underlying price,
all protocol-specific adapter shims are gone (consumers target
`AggregatorV2V3Interface` directly), and the registry indirection has been
removed in favour of a simple `(adapter, wrapper)` proxy pair per vault.

---

## 2. Architecture Overview

```
                    ┌──────────────────────────────────────┐
   consumers ──────▶│        PausableOracleWrapper         │   ← canonical
   (Euler, Aave,    │                                      │     consumer-facing
    Compound,       │   AggregatorV2V3Interface            │     address
    other lending)  │                                      │
                    │   + OraclePausedManual()             │
                    │   + OraclePausedCorporateAction(t)   │
                    └────────────────┬─────────────────────┘
                                     │ upstream (immutable)
                                     ▼
                    ┌──────────────────────────────────────┐
                    │         ChronicleVaultOracle         │
                    │                                      │
                    │   AggregatorV2V3Interface (8 dec)    │
                    │                                      │
                    │   price = chronicle.read()           │
                    │         × vault.totalAssets()        │
                    │         / vault.totalSupply()        │
                    └────────────────┬─────────────────────┘
                                     │
                ┌────────────────────┴────────────────────┐
                ▼                                         ▼
       ┌─────────────────┐                    ┌──────────────────┐
       │   IChronicle    │                    │  ERC-4626 vault  │
       │  (off-chain     │                    │   (wtStock)      │
       │   poked price)  │                    │                  │
       └─────────────────┘                    └──────────────────┘
                                                       ▲
                                                       │ ICorporateActionsV1
                                                       │ (consulted by wrapper
                                                       │  on every read)
                                                       │
                                              ┌──────────────────┐
                                              │  corporateActions│
                                              │      Vault       │
                                              └──────────────────┘
```

**Two layers, separated by intent:**

- **Adapter layer** — `ChronicleVaultOracle`. Pure price math. Reads Chronicle
  for the underlying, multiplies by the vault's assets-per-share ratio, scales
  to 8 decimals. No admin, no pause flag, nothing operational. Replaceable by
  a different price-source adapter without touching the wrapper.
- **Wrapper layer** — `PausableOracleWrapper`. Pure decorator. Adds pause
  semantics (manual + corporate-action-aware) on top of any
  `AggregatorV2V3Interface`. Shape-preserving — `decimals`, `description`,
  `version` are delegated. The same wrapper implementation will decorate a
  Chainlink-direct adapter, a different vendor adapter, or anything else
  satisfying the interface, with zero changes.

The wrapper proxy is the canonical consumer-facing address. The adapter
proxy's address is an internal implementation detail of the wrapper and need
not be exposed to integrators after deploy time.

---

## 3. `ChronicleVaultOracle`

**Location:** `src/concrete/oracle/ChronicleVaultOracle.sol`

Prices ERC-4626 vault shares by combining the Chronicle Protocol price of the
underlying asset with the vault's `totalAssets / totalSupply` ratio. Beacon-proxy
clone via `ICloneableV2`. 8-decimal `AggregatorV2V3Interface` output.

### 3.1 Storage

```solidity
IChronicle public chronicle;   // Chronicle feed for the underlying asset
address    public vault;       // ERC-4626 vault whose shares are priced
uint256    public maxAge;      // Max acceptable Chronicle reading age (seconds)
```

All three are set once by `initialize(bytes calldata)` and never written again.
There is no admin, no pause flag, no setter. To change any of them, deploy a
fresh proxy and migrate consumers.

### 3.2 Price Formula

```
                       chroniclePrice × vault.totalAssets()
   vaultSharePrice  =  ─────────────────────────────────────     (then 8dp)
                              vault.totalSupply()
```

- `chroniclePrice` is the 18-decimal `uint256` returned by
  `IChronicle.readWithAge()`.
- The full computation is performed in Rain decimal-float space
  (`rain-math-float`), so neither operand can overflow `uint256` and decimal
  scaling is exact until the final reduction. The conversion to fixed-point
  8 decimals happens only at the return boundary.
- The vault ratio `totalAssets / totalSupply` is exactly what an ERC-4626
  `convertToAssets(1 share)` would compute, so the price tracks any NAV
  change inside the vault — most importantly the post-split balance bump
  applied to the underlying `tStock` vault. See §6.2.

### 3.3 Surface

`ChronicleVaultOracle implements AggregatorV2V3Interface, ICloneableV2,
Initializable`:

| Function | Behaviour |
|----------|-----------|
| `decimals()` | Returns `8`. Chainlink convention for USD-denominated price feeds. |
| `description()` | Returns `""`. ST0x deployments do not rely on this string; consumers route by proxy address. |
| `version()` | Returns `1`. |
| `latestAnswer()` | Reads Chronicle (checks `maxAge`), computes share price, returns `int256`. |
| `latestRoundData()` | As above, with `roundId == answeredInRound == uint80(age)` and `startedAt == updatedAt == age`. Integrators that diff `roundId` see a new value whenever Chronicle has produced a new poke. |
| `getRoundData(_roundId)` | Always reverts `HistoricalRoundDataUnsupported(_roundId)`. Chronicle exposes only its latest poke through this interface. |

### 3.4 Errors

- `ZeroChronicle()` / `ZeroVault()` / `ZeroMaxAge()` — `initialize` rejects
  zero values. `maxAge = 0` would make every read instantly stale; failing
  loud at init is preferable to minting a broken oracle.
- `ChroniclePriceStale(uint256 age)` — `block.timestamp - age > maxAge`. The
  oracle uses `readWithAge` (which itself reverts on no value), not
  `tryReadWithAge` — a missing Chronicle value is always an oracle failure
  that must surface, never be silently masked.
- `ZeroVaultSupply()` — `vault.totalSupply() == 0`. Pricing one share of a
  zero-supply vault is undefined.
- `ZeroVaultSharePrice()` — computed price rounds to zero. A zero price is
  never a valid Chainlink-compatible answer.
- `VaultSharePriceOverflow(uint256 price8)` — result wouldn't fit in `int256`.
- `HistoricalRoundDataUnsupported(uint80 roundId)` — `getRoundData` is not
  supported.

### 3.5 Events

- `ChronicleVaultOracleInitialized(address indexed sender,
  ChronicleVaultOracleConfig config)` — emitted exactly once. Single source
  of truth for off-chain indexers; all immutable config lives in this event.

---

## 4. `PausableOracleWrapper`

**Location:** `src/concrete/wrapper/PausableOracleWrapper.sol`

A pure-decorator wrapper that adds operational pause semantics on top of any
`AggregatorV2V3Interface` upstream. Beacon-proxy clone via `ICloneableV2`.

### 4.1 Storage

```solidity
address                 public admin;                  // governance
bool                    public paused;                 // manual emergency flag
AggregatorV2V3Interface public upstream;               // wrapped oracle (immutable)
address                 public corporateActionsVault;  // ICorporateActionsV1, immutable
uint256                 public actionTypeMask;         // bitmap, immutable
uint64                  public pauseTimeBefore;        // pre-window (s), immutable
uint64                  public pauseTimeAfter;         // post-window (s), immutable
```

`admin` and `paused` are the only mutable slots after `initialize`. `upstream`
and the entire `CorporateActionPauseConfig` block are immutable — there is no
admin upgrade path that could swap the priced source. Swapping the priced
source means redeploying the wrapper and migrating consumers, which is by
design (see §7).

### 4.2 Pause Semantics

Reads (`latestAnswer`, `latestRoundData`, `getRoundData`) revert if **either**
of two independent conditions is true:

1. **Manual pause.** `paused == true`, set by `admin` via `setPaused(bool)`.
   Reverts `OraclePausedManual()`. Persists until `setPaused(false)`.
2. **Corporate-action auto-pause.** `LibCorporateActionsPause.inPauseWindow(...)`
   returns `true` for the configured vault, mask, and pre/post windows.
   Reverts `OraclePausedCorporateAction(uint64 effectiveTime)`. The
   `effectiveTime` payload disambiguates which scheduled or completed action
   triggered the pause. See §5 for the windowing semantics.

The two conditions are OR'd. The manual check runs first (cheaper — single
`SLOAD`) so that when an admin has explicitly set the manual flag, integrators
see `OraclePausedManual()` rather than a coincidental
`OraclePausedCorporateAction(t)`.

The error selectors are distinct so a consumer doing `try / catch` introspection
can disambiguate "ops paused us" from "scheduled event in window" if they wish.
For the simple case — a consumer that catches any revert and falls back to
"no price available" — no disambiguation is needed.

### 4.3 Shape Preservation

`decimals()`, `description()`, and `version()` are delegated straight to
`upstream`. The wrapper does not modify any value; it only adds revert
conditions. A consumer dropping in a `PausableOracleWrapper` proxy where it
would have used the underlying adapter sees identical shape and identical
price behaviour outside pause windows.

### 4.4 Admin Surface

| Function | Behaviour |
|----------|-----------|
| `setPaused(bool isPaused)` | `onlyAdmin`. Toggles the manual flag. Emits `PauseSet(isPaused)`. |
| `setAdmin(address newAdmin)` | `onlyAdmin`. One-step transfer; new admin takes effect immediately. Rejects zero. A misaddressed transfer permanently locks governance — use a multisig. Emits `AdminSet(oldAdmin, newAdmin)`. |

### 4.5 Errors

- `ZeroUpstream()` / `ZeroAdmin()` — `initialize` and `setAdmin` reject zero
  values. A zero admin permanently locks `setPaused`; a zero upstream mints
  a wrapper that always reverts.
- `OnlyAdmin()` — caller is not `admin`.
- `OraclePausedManual()` — manual pause is set.
- `OraclePausedCorporateAction(uint64 effectiveTime)` — auto-pause window is
  open. `effectiveTime` is the action whose window contains `now`.

### 4.6 Events

- `PausableOracleWrapperInitialized(address indexed sender,
  PausableOracleWrapperConfig config)` — once on init.
- `PauseSet(bool isPaused)`
- `AdminSet(address indexed oldAdmin, address indexed newAdmin)`

---

## 5. `LibCorporateActionsPause`

**Location:** `src/lib/LibCorporateActionsPause.sol`

Stateless, view-only helper. Consults an `ICorporateActionsV1` vault and
decides whether the current block falls inside a configured pause window
around any matching scheduled or completed action.

### 5.1 Window Semantics

The library checks two windows independently and pauses if either is open.

**Pre-window** (earliest pending action `A` matching the mask):

```
   effectiveTime(A) - pauseTimeBefore  ≤  block.timestamp  <  effectiveTime(A)
```

Querying the earliest pending action is sufficient: pending effective-times
are strictly increasing in their list traversal, so if the closest one's
pre-window has not yet opened, no later one's has either.

**Post-window** (latest completed action `A` matching the mask):

```
   effectiveTime(A)  ≤  block.timestamp  ≤  effectiveTime(A) + pauseTimeAfter
```

Querying the latest completed action is sufficient: completed effective-times
are strictly decreasing in their list traversal, so if the most recent one's
post-window has closed, no earlier one's is open.

Cancelled action nodes are unlinked from `ICorporateActionsV1`'s traversal
API and so are excluded automatically — no explicit filter required here.

Each call is at most two view calls into the vault.

### 5.2 Mask

`actionTypeMask` is a bitmap matching `ICorporateActionsV1`'s action-type
encoding:

- `ACTION_TYPE_STOCK_SPLIT_V1 = 1 << 1`
- `ACTION_TYPE_STABLES_DIVIDEND_V1 = 1 << 2`
- `type(uint256).max` matches every present and future action type.

A `mask == 0` short-circuits to "not paused" — no action types match anything.
A zero `corporateActionsVault` also short-circuits to "not paused" and
disables auto-pause for the life of the wrapper proxy.

### 5.3 Overlap Resolution: Pending Wins

When both a pending pre-window and a completed post-window contain `now`
(e.g. a back-to-back schedule where one action just completed and the next
is about to fire), the **pending** action's `effectiveTime` is the one
returned in `OraclePausedCorporateAction(effectiveTime)`. Rationale:
integrators reading the revert payload care more about the next event coming
than the last one done — the upcoming `effectiveTime` is what tells them when
to expect the pause window to slide.

This is implemented by checking the pending window first and short-circuiting
the return.

### 5.4 Audit Note: `NODE_NONE` Sentinel

`ICorporateActionsV1` uses linked-list traversal with node ids; `cursor == 0`
is a real bootstrap node (the `ACTION_TYPE_INIT_V1` entry). The no-match
sentinel is `NODE_NONE = type(uint256).max`. An earlier draft of this
library used `cursor != 0` as the "match found" check, which would have
silently treated the bootstrap node as a real corporate action. The current
implementation uses `cursor != NODE_NONE`. This is load-bearing — do not
weaken it during future refactors.

---

## 6. Flagship Features

The wrapper/adapter split surfaces two core ST0x security properties that
downstream lending markets get for free.

### 6.1 Corporate-Action Auto-Pause

Lending markets must not service borrows, repayments, or liquidations against
a vault whose NAV is about to discontinuously change. A stock split inside
the underlying `tStock` vault rebalances every receipt holder's balance at
the split's `effectiveTime`; until that rebalance is reflected in
`vault.totalAssets()`, the oracle's share price is correct-as-of-old-shares
but the market sees new shares. Anyone trading across that boundary captures
free value at the expense of slower participants.

The wrapper's corporate-action auto-pause closes the boundary: from
`effectiveTime - pauseTimeBefore` through `effectiveTime + pauseTimeAfter`,
every price read reverts `OraclePausedCorporateAction(effectiveTime)`.
Lending markets that catch the revert (Aave-style `try/catch` consumers)
treat the price as unavailable for the window — no new borrows, no liquidations.

The auto-pause is consulted on every price read against the live
`ICorporateActionsV1` state. There is no off-chain process to nudge, no
scheduled job, no admin action required around the event. ST0x governance
remains the keeper-of-record on the corporate-actions vault, but the
oracle's reaction to that schedule is fully on-chain and deterministic.

### 6.2 `wtStock` NAV Tracking via `convertToAssets`

The vault under price is an ERC-4626 `wtStock` wrapper. Its
`vault.totalAssets() / vault.totalSupply()` ratio is exactly what
`convertToAssets(1 share)` would return, and is the canonical handle on any
NAV bump the underlying `tStock` vault has applied. After a stock split, the
underlying receipt vault's balances rebalance, `wtStock.totalAssets()` rises
proportionally, and the next post-pause price read picks up the new ratio
without any oracle-side intervention.

This is intentional: the oracle does not encode split ratios, dividend
amounts, or any action-specific math. All accounting lives in the vault;
the oracle just multiplies. The auto-pause window covers the period where
the rebalance is still settling and the ratio is mid-transition. After the
post-window closes, reads resume against the updated ratio.

This is also why the wrapper does not allow swapping `upstream`: if a future
admin could redirect to a different priced source, the (paused-correctly)
share-price invariant would no longer be guaranteed by construction.

---

## 7. Beacon-Proxy & Upgrade Model

Both `ChronicleVaultOracle` and `PausableOracleWrapper` follow the standard
`st0x.deploy` BeaconSetDeployer pattern:

- Each contract has a `BeaconSetDeployer` constructor that takes an
  implementation address and an initial beacon owner, then constructs a
  fresh `UpgradeableBeacon` internally and holds it as an `immutable`.
- Proxies (`BeaconProxy`) are minted via the deployer's `new...()` method
  and initialized through `ICloneableV2.initialize(bytes)`. Init returning
  anything other than `ICLONEABLE_V2_SUCCESS` reverts the deploy.
- After construction, the deployer retains no authority over the beacon.
  Implementation upgrades and beacon-owner rotations are handled externally
  by whoever the beacon's `Ownable` owner is (ST0x governance multisig).

**What the beacon owner can do:**

- Swap the implementation behind the beacon (bug fixes, gas optimisations).

**What the beacon owner cannot do:**

- Change a proxy's `upstream` (it's immutable in the proxy's storage).
- Change a proxy's `corporateActionsVault`, `actionTypeMask`,
  `pauseTimeBefore`, or `pauseTimeAfter`.
- Change a `ChronicleVaultOracle` proxy's `chronicle`, `vault`, or `maxAge`.

These are immutable after init by design. A beacon upgrade can change
behaviour but cannot redirect the priced source or weaken the pause windows.
The only way to change a vault's priced source is to redeploy a fresh
adapter and a fresh wrapper, then migrate consumers — which is, again, an
intentional friction surface.

---

## 8. Deployers

**Location:** `src/concrete/deploy/`

| Contract | Purpose |
|----------|---------|
| `ChronicleVaultOracleBeaconSetDeployer` | Owns the `ChronicleVaultOracle` beacon. Exposes `newChronicleVaultOracle(config)` to mint a proxy. |
| `PausableOracleWrapperBeaconSetDeployer` | Owns the `PausableOracleWrapper` beacon. Exposes `newPausableOracleWrapper(config)` to mint a proxy. |
| `ChronicleOracleUnifiedDeployer` | One-shot. `newOracleWithWrapper(config)` mints both proxies in a single transaction and wires `wrapper.upstream = oracle`. |

### 8.1 Unified Deploy

```solidity
ChronicleOracleUnifiedDeployConfig memory config = ChronicleOracleUnifiedDeployConfig({
    admin: governanceMultisig,
    oracleConfig: ChronicleVaultOracleConfig({
        chronicle: IChronicle(chronicleFeed),
        vault:     wtStockVault,
        maxAge:    60
    }),
    pauseConfig: CorporateActionPauseConfig({
        corporateActionsVault: corporateActionsVault,
        actionTypeMask:        type(uint256).max,
        pauseTimeBefore:       1 hours,
        pauseTimeAfter:        2 hours
    })
});

(ChronicleVaultOracle oracle, PausableOracleWrapper wrapper) =
    unifiedDeployer.newOracleWithWrapper(config);

// Hand `address(wrapper)` to consumers. Forget `address(oracle)`.
```

Atomicity is the point: a two-step deploy-then-wire-up flow opens a window
for misaddressing the adapter, which would silently mint a wrapper around
the wrong priced source. The unified deployer closes that window — the
wrapper's `upstream` slot is set to the freshly-deployed adapter inside the
same transaction that created the adapter, and both addresses are emitted
in the deployer's `Deployment(caller, oracle, wrapper)` event.

### 8.2 Per-Chain Deploy Sequence

1. Deploy `ChronicleVaultOracle` implementation.
2. Deploy `ChronicleVaultOracleBeaconSetDeployer` (it constructs its beacon).
3. Deploy `PausableOracleWrapper` implementation.
4. Deploy `PausableOracleWrapperBeaconSetDeployer` (it constructs its beacon).
5. Deploy `ChronicleOracleUnifiedDeployer` wired to both BeaconSetDeployers.
6. (Per vault) Call `unifiedDeployer.newOracleWithWrapper(...)`.

Steps 1-5 happen once per chain. Step 6 is one transaction per vault.

---

## 9. Vendored Interfaces

**Location:** `src/interface/`

Two interfaces are vendored locally rather than pulled as soldeer or git
dependencies:

- **`IChronicle.sol`** — Chronicle Protocol's oracle interface
  (`wat`, `read`, `readWithAge`, `tryRead`, `tryReadWithAge`). 18-decimal
  `uint256` values. Hand-typed copy of
  `chronicleprotocol/chronicle-std:src/IChronicle.sol` (MIT-licensed),
  last synced 2026-06-26 against `main`. Vendored because the interface is
  small, stable, and Chronicle does not currently publish `chronicle-std`
  to soldeer. **No drift-detection test exists.** Re-sync on any upstream
  bump.

- **`IAggregatorV2V3.sol`** — Hybrid of Chainlink's `AggregatorInterface`
  (v2 — `latestAnswer`) and `AggregatorV3Interface` (v3 — `latestRoundData`,
  `getRoundData`). Vendored to avoid taking a Chainlink dependency for an
  interface this small. The deprecated `latestAnswer()` is intentionally
  retained because Aave V3 and Compound V3 still call it; new consumers
  should prefer `latestRoundData()` and honour `updatedAt`.

---

## 10. Integrator Model

Consumers (Euler, Aave V3, Compound V3, future Chainlink-compatible
markets) target the `PausableOracleWrapper` proxy address at the
`AggregatorV2V3Interface` they already use for Chainlink feeds. No
protocol-specific shim is involved. The wrapper looks indistinguishable from
a Chainlink feed except that:

- `latestAnswer` / `latestRoundData` revert during pause windows. Consumers
  must treat these reverts as "price unavailable", not "price is the last
  successful read".
- `getRoundData(_roundId)` always reverts when the upstream is
  `ChronicleVaultOracle`. Consumers should not rely on historical round
  lookups against this stack.

### 10.1 Operational Preconditions

For any consumer that wraps reads in `try / catch`:

1. **Do not configure a fallback oracle on the same bToken that points at a
   raw Chronicle feed (or a raw Pyth feed, or anything else).** A fallback
   would silently mask the pause errors — exactly the failure mode the
   auto-pause is supposed to make loud. A pause must surface to the
   protocol as `OraclePriceNotFound` (or its equivalent), not get swallowed
   by a fallback that wasn't aware the price was deliberately withheld.

2. **The consumer's own `maxPriceAge` (or equivalent staleness threshold)
   must be greater than or equal to the adapter's `maxAge`.** Otherwise
   the consumer's check rejects the read before the adapter's internal
   `ChroniclePriceStale(age)` revert can fire, and the deployment loses
   the layered staleness signal. Configure consumer staleness as a strict
   upper bound on adapter staleness.

---

## 11. Repository Structure

```
st0x.oracle/
├── src/
│   ├── concrete/
│   │   ├── oracle/
│   │   │   └── ChronicleVaultOracle.sol
│   │   ├── wrapper/
│   │   │   └── PausableOracleWrapper.sol
│   │   └── deploy/
│   │       ├── ChronicleVaultOracleBeaconSetDeployer.sol
│   │       ├── PausableOracleWrapperBeaconSetDeployer.sol
│   │       └── ChronicleOracleUnifiedDeployer.sol
│   ├── interface/
│   │   ├── IChronicle.sol           ← vendored Chronicle (MIT)
│   │   └── IAggregatorV2V3.sol      ← vendored Chainlink shape
│   └── lib/
│       └── LibCorporateActionsPause.sol
└── test/
    ├── mocks/
    │   ├── MockAggregatorV2V3.sol
    │   ├── MockChronicle.sol
    │   ├── MockCorporateActions.sol
    │   └── MockERC4626.sol
    └── src/
        ├── concrete/
        │   ├── oracle/
        │   ├── wrapper/
        │   └── deploy/
        ├── lib/
        └── e2e/
            └── ChronicleStackE2E.t.sol
```

---

## 12. Security Considerations

1. **Chronicle staleness must surface, not mask.** The adapter uses
   `readWithAge` (reverts on no value), not `tryReadWithAge` (returns
   `isValid=false`). A missing Chronicle value is always an oracle failure
   that must reach the consumer.
2. **`maxAge == 0` is rejected at init.** A zero `maxAge` would make every
   read instantly stale; failing loud at init is preferable to minting an
   always-reverting oracle.
3. **Vault ratio is trusted.** `totalAssets / totalSupply` is taken at face
   value. The vault must be a known ST0x deployment; pricing a hostile
   ERC-4626 implementation is out of scope.
4. **Zero vault supply reverts.** Pricing a share of a zero-supply vault
   is undefined; the adapter reverts `ZeroVaultSupply()`.
5. **`NODE_NONE` is the no-match sentinel, not `0`.** See §5.4. Misreading
   this would treat the bootstrap node as a real corporate action.
6. **Pending-wins overlap rule.** See §5.3. If a future change reverses
   this, integrators reading the `effectiveTime` payload would see the
   wrong "next event" timestamp.
7. **Wrapper `admin` is single-step and zero-rejected on transfer.** A
   misaddressed transfer permanently locks `setPaused`; use a multisig.
8. **Upstream and pause config are immutable.** No admin path can redirect
   the priced source or weaken pause windows; only redeploy + migration.
9. **`getRoundData` reverts on Chronicle-backed deployments.** Consumers
   that depend on historical round lookups will fail loudly, not get
   wrong-but-plausible data.
10. **Fallback oracles on the consumer side undermine the pause feature.**
    See §10.1. The pause must reach the consumer; a fallback that hides it
    defeats the security property.

---

## 13. References

- **Chronicle Protocol** — https://chroniclelabs.org/
- **chronicle-std (`IChronicle` source of truth)** —
  https://github.com/chronicleprotocol/chronicle-std
- **`st0x.deploy` (corporate actions, BeaconSetDeployer pattern,
  `ICloneableV2`)** — https://github.com/S01-Issuer/st0x.deploy
- **`rain-math-float`** — https://github.com/rainlanguage/rain.math.float
- **Chainlink `AggregatorV2V3Interface`** — https://github.com/smartcontractkit/chainlink
- **ERC-4626 Tokenized Vault Standard** — https://eips.ethereum.org/EIPS/eip-4626
