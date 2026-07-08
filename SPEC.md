# ST0x Oracle Stack Specification

**Repository:** `st0x.oracle` **Version:** 3.0 **Status:** Draft **Date:**
2026-06-30

---

## 1. Problem Statement

ST0x issues wrapped tokenized equities — `wtStock` ERC-4626 vaults wrapping
`tStock` rebasing-receipt vaults — that need to be priced inside DeFi lending
protocols (Euler, Aave V3, Compound V3, future Chainlink-compatible markets).
Consumers already speak Chainlink's `AggregatorV2V3Interface`; the oracle
stack's job is to expose a single proxy address per vault that:

1. Returns an 8-decimal `int256` price for one share of the vault, denominated
   in USD, drawn from a market-grade off-chain feed for the underlying equity.
2. Tracks the vault's `totalAssets / totalSupply` ratio so the share price moves
   with any NAV change — most importantly the post-stock-split rebalance inside
   the underlying `tStock` vault.
3. Refuses to serve a price during scheduled corporate actions (splits, dividend
   distributions), so downstream lending markets can't liquidate or borrow
   against a stale-by-construction share price while the vault NAV is
   mid-rebalance.
4. Gives ST0x governance a manual emergency pause independent of the
   corporate-action machinery.

The previous architecture (Pyth + per-protocol adapters + a registry indirection
layer) has been replaced. DIA Data Association now supplies the underlying
price, all protocol-specific adapter shims are gone (consumers target
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
                 │           DIAVaultOracle             │
                 │                                      │
                 │   AggregatorV2V3Interface (8 dec)    │
                 │                                      │
                 │   price = diaOracle.getValue(symbol) │
                 │         × vault.totalAssets()        │
                 │         / vault.totalSupply()        │
                 └────────────────┬─────────────────────┘
                                  │
             ┌────────────────────┴────────────────────┐
             ▼                                         ▼
    ┌─────────────────┐                    ┌──────────────────┐
    │  IDIAOracleV2   │                    │  ERC-4626 vault  │
    │  (off-chain     │                    │   (wtStock)      │
    │   pushed price) │                    │                  │
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

The repo also ships a second, independent stack — the publisher-signed price
store for Morpho Blue markets — specified in §11. The rest of this overview and
§§3–10 describe the DIA stack.

**Two layers, separated by intent:**

- **Adapter layer** — `DIAVaultOracle`. Pure price math. Reads DIA for the
  underlying, multiplies by the vault's assets-per-share ratio, scales to 8
  decimals. No admin, no pause flag, nothing operational. Replaceable by a
  different price-source adapter without touching the wrapper.
- **Wrapper layer** — `PausableOracleWrapper`. Pure decorator. Adds pause
  semantics (manual + corporate-action-aware) on top of any
  `AggregatorV2V3Interface`. Shape-preserving — `decimals`, `description`,
  `version` are delegated. The same wrapper implementation will decorate a
  Chainlink-direct adapter, a different vendor adapter, or anything else
  satisfying the interface, with zero changes.

The wrapper proxy is the canonical consumer-facing address. The adapter proxy's
address is an internal implementation detail of the wrapper and need not be
exposed to integrators after deploy time.

---

## 3. `DIAVaultOracle`

**Location:** `src/concrete/oracle/DIAVaultOracle.sol`

Prices ERC-4626 vault shares by combining the DIA Data Association price of the
underlying asset with the vault's `totalAssets / totalSupply` ratio.
Beacon-proxy clone via `ICloneableV2`. 8-decimal `AggregatorV2V3Interface`
output.

### 3.1 Storage

```solidity
IDIAOracleV2 public diaOracle;   // DIA oracle contract
string       public symbol;      // Bare feed symbol e.g. "COIN", "AMZN", "TSLA"
address      public vault;       // ERC-4626 vault whose shares are priced
uint256      public maxAge;      // Max acceptable DIA reading age (seconds)
```

All four are set once by `initialize(bytes calldata)` and never written again.
There is no admin, no pause flag, no setter. To change any of them, deploy a
fresh proxy and migrate consumers.

The DIA feed key is the **bare symbol** (`"COIN"`, `"AMZN"`, `"TSLA"`), not a
pair string like `"COIN/USD"`. The DIA oracle contract is queried with this
string as the key argument to `getValue`.

### 3.2 Price Formula

```
                    diaPrice × vault.totalAssets()
vaultSharePrice  =  ─────────────────────────────────     (then 8dp)
                           vault.totalSupply()
```

- `diaPrice` is the 18-decimal `uint128` value returned by
  `IDIAOracleV2.getValue(symbol)`.
- The full computation is performed in Rain decimal-float space
  (`rain-math-float`), so neither operand can overflow `uint256` and decimal
  scaling is exact until the final reduction. The conversion to fixed-point 8
  decimals happens only at the return boundary.
- The vault ratio `totalAssets / totalSupply` is exactly what an ERC-4626
  `convertToAssets(1 share)` would compute, so the price tracks any NAV change
  inside the vault — most importantly the post-split balance bump applied to the
  underlying `tStock` vault. See §6.2.

### 3.3 Surface

`DIAVaultOracle implements AggregatorV2V3Interface, ICloneableV2,
Initializable`:

| Function                 | Behaviour                                                                                                                                                                                         |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `decimals()`             | Returns `8`. Chainlink convention for USD-denominated price feeds.                                                                                                                                |
| `description()`          | Returns the configured `symbol` (e.g. `"COIN"`). Lets consumers introspect what symbol the oracle wraps without an off-chain lookup.                                                              |
| `version()`              | Returns `1`.                                                                                                                                                                                      |
| `latestAnswer()`         | Reads DIA via `getValue(symbol)` (checks `maxAge` and not-set), computes share price, returns `int256`.                                                                                           |
| `latestRoundData()`      | As above, with `roundId == answeredInRound == uint80(timestamp)` and `startedAt == updatedAt == timestamp`. Integrators that diff `roundId` see a new value whenever DIA has produced a new push. |
| `getRoundData(_roundId)` | Always reverts `HistoricalRoundDataUnsupported(_roundId)`. DIA exposes only its latest push through this interface.                                                                               |

### 3.4 Errors

- `ZeroDIAOracle()` / `EmptySymbol()` / `ZeroVault()` / `ZeroMaxAge()` —
  `initialize` rejects zero values. An empty symbol would key into an unset DIA
  feed; `maxAge = 0` would make every read instantly stale; failing loud at init
  is preferable to minting a broken oracle.
- `DIAPriceNotSet()` — DIA's `getValue(symbol)` returned `(0, 0)`. DIA does
  **not** revert for unset feeds — it silently returns zeros. The adapter checks
  this explicitly and raises `DIAPriceNotSet()` rather than producing a
  zero-value Chainlink answer, which would be silently catastrophic for
  consumers that don't check for zero.
- `DIAPriceStale(uint256 timestamp)` — `block.timestamp - timestamp > maxAge`.
- `ZeroVaultSupply()` — `vault.totalSupply() == 0`. Pricing one share of a
  zero-supply vault is undefined.
- `ZeroVaultSharePrice()` — computed price rounds to zero. A zero price is never
  a valid Chainlink-compatible answer.
- `VaultSharePriceOverflow(uint256 price8)` — result wouldn't fit in `int256`.
- `HistoricalRoundDataUnsupported(uint80 roundId)` — `getRoundData` is not
  supported.

### 3.5 Events

- `DIAVaultOracleInitialized(address indexed sender,
  DIAVaultOracleConfig config)`
  — emitted exactly once. Single source of truth for off-chain indexers; all
  immutable config lives in this event.

### 3.6 DIA Freshness Policy

DIA pushes a new value whenever **either** of two triggers fires, whichever
happens first:

- **Deviation trigger:** the off-chain price has moved by ≥ 0.1% since the last
  on-chain push.
- **Heartbeat trigger:** 1 hour has elapsed since the last push.

So during volatile periods, pushes happen every few minutes; the 1-hour
heartbeat is the dead-market floor. **Recommended `maxAge = 2 hours`** — one
missed heartbeat tolerance, enough slack to absorb a single skipped push without
false staleness reverts, but tight enough to surface a genuinely stalled feed
quickly.

### 3.7 Live DIA Contract on Base

The canonical DIA oracle contract on Base mainnet is
`0xCE521b52513242c5094bc56f57887BB2A05B8129`. Per-symbol price feeds are all
served by this single contract via `getValue(string key)`.

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
admin upgrade path that could swap the priced source. Swapping the priced source
means redeploying the wrapper and migrating consumers, which is by design (see
§7).

### 4.2 Pause Semantics

Reads (`latestAnswer`, `latestRoundData`, `getRoundData`) revert if **either**
of two independent conditions is true:

1. **Manual pause.** `paused == true`, set by `admin` via `setPaused(bool)`.
   Reverts `OraclePausedManual()`. Persists until `setPaused(false)`.
2. **Corporate-action auto-pause.**
   `LibCorporateActionsPause.inPauseWindow(...)` returns `true` for the
   configured vault, mask, and pre/post windows. Reverts
   `OraclePausedCorporateAction(uint64 effectiveTime)`. The `effectiveTime`
   payload disambiguates which scheduled or completed action triggered the
   pause. See §5 for the windowing semantics.

The two conditions are OR'd. The manual check runs first (cheaper — single
`SLOAD`) so that when an admin has explicitly set the manual flag, integrators
see `OraclePausedManual()` rather than a coincidental
`OraclePausedCorporateAction(t)`.

The error selectors are distinct so a consumer doing `try / catch` introspection
can disambiguate "ops paused us" from "scheduled event in window" if they wish.
For the simple case — a consumer that catches any revert and falls back to "no
price available" — no disambiguation is needed.

### 4.3 Shape Preservation

`decimals()`, `description()`, and `version()` are delegated straight to
`upstream`. The wrapper does not modify any value; it only adds revert
conditions. A consumer dropping in a `PausableOracleWrapper` proxy where it
would have used the underlying adapter sees identical shape and identical price
behaviour outside pause windows.

### 4.4 Admin Surface

| Function                     | Behaviour                                                                                                                                                                                      |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `setPaused(bool isPaused)`   | `onlyAdmin`. Toggles the manual flag. Emits `PauseSet(isPaused)`.                                                                                                                              |
| `setAdmin(address newAdmin)` | `onlyAdmin`. One-step transfer; new admin takes effect immediately. Rejects zero. A misaddressed transfer permanently locks governance — use a multisig. Emits `AdminSet(oldAdmin, newAdmin)`. |

### 4.5 Errors

- `ZeroUpstream()` / `ZeroAdmin()` — `initialize` and `setAdmin` reject zero
  values. A zero admin permanently locks `setPaused`; a zero upstream mints a
  wrapper that always reverts.
- `OnlyAdmin()` — caller is not `admin`.
- `OraclePausedManual()` — manual pause is set.
- `OraclePausedCorporateAction(uint64 effectiveTime)` — auto-pause window is
  open. `effectiveTime` is the action whose window contains `now`.

### 4.6 Events

- `PausableOracleWrapperInitialized(address indexed sender,
  PausableOracleWrapperConfig config)`
  — once on init.
- `PauseSet(bool isPaused)`
- `AdminSet(address indexed oldAdmin, address indexed newAdmin)`

---

## 5. `LibCorporateActionsPause`

**Location:** `src/lib/LibCorporateActionsPause.sol`

Stateless, view-only helper. Consults an `ICorporateActionsV1` vault and decides
whether the current block falls inside a configured pause window around any
matching scheduled or completed action.

### 5.1 Window Semantics

The library checks two windows independently and pauses if either is open.

**Pre-window** (earliest pending action `A` matching the mask):

```
effectiveTime(A) - pauseTimeBefore  ≤  block.timestamp  <  effectiveTime(A)
```

Querying the earliest pending action is sufficient: pending effective-times are
strictly increasing in their list traversal, so if the closest one's pre-window
has not yet opened, no later one's has either.

**Post-window** (latest completed action `A` matching the mask):

```
effectiveTime(A)  ≤  block.timestamp  ≤  effectiveTime(A) + pauseTimeAfter
```

Querying the latest completed action is sufficient: completed effective-times
are strictly decreasing in their list traversal, so if the most recent one's
post-window has closed, no earlier one's is open.

Cancelled action nodes are unlinked from `ICorporateActionsV1`'s traversal API
and so are excluded automatically — no explicit filter required here.

Each call is at most two view calls into the vault.

### 5.2 Mask

`actionTypeMask` is a bitmap matching `ICorporateActionsV1`'s action-type
encoding:

- `ACTION_TYPE_STOCK_SPLIT_V1 = 1 << 1`
- `ACTION_TYPE_STABLES_DIVIDEND_V1 = 1 << 2`
- `type(uint256).max` matches every present and future action type.

A `mask == 0` short-circuits to "not paused" — no action types match anything. A
zero `corporateActionsVault` also short-circuits to "not paused" and disables
auto-pause for the life of the wrapper proxy.

### 5.3 Overlap Resolution: Pending Wins

When both a pending pre-window and a completed post-window contain `now` (e.g. a
back-to-back schedule where one action just completed and the next is about to
fire), the **pending** action's `effectiveTime` is the one returned in
`OraclePausedCorporateAction(effectiveTime)`. Rationale: integrators reading the
revert payload care more about the next event coming than the last one done —
the upcoming `effectiveTime` is what tells them when to expect the pause window
to slide.

This is implemented by checking the pending window first and short-circuiting
the return.

### 5.4 Audit Note: `NODE_NONE` Sentinel

`ICorporateActionsV1` uses linked-list traversal with node ids; `cursor == 0` is
a real bootstrap node (the `ACTION_TYPE_INIT_V1` entry). The no-match sentinel
is `NODE_NONE = type(uint256).max`. An earlier draft of this library used
`cursor != 0` as the "match found" check, which would have silently treated the
bootstrap node as a real corporate action. The current implementation uses
`cursor != NODE_NONE`. This is load-bearing — do not weaken it during future
refactors.

---

## 6. Flagship Features

The wrapper/adapter split surfaces two core ST0x security properties that
downstream lending markets get for free.

### 6.1 Corporate-Action Auto-Pause

Lending markets must not service borrows, repayments, or liquidations against a
vault whose NAV is about to discontinuously change. A stock split inside the
underlying `tStock` vault rebalances every receipt holder's balance at the
split's `effectiveTime`; until that rebalance is reflected in
`vault.totalAssets()`, the oracle's share price is correct-as-of-old-shares but
the market sees new shares. Anyone trading across that boundary captures free
value at the expense of slower participants.

The wrapper's corporate-action auto-pause closes the boundary: from
`effectiveTime - pauseTimeBefore` through `effectiveTime + pauseTimeAfter`,
every price read reverts `OraclePausedCorporateAction(effectiveTime)`. Lending
markets that catch the revert (Aave-style `try/catch` consumers) treat the price
as unavailable for the window — no new borrows, no liquidations.

The auto-pause is consulted on every price read against the live
`ICorporateActionsV1` state. There is no off-chain process to nudge, no
scheduled job, no admin action required around the event. ST0x governance
remains the keeper-of-record on the corporate-actions vault, but the oracle's
reaction to that schedule is fully on-chain and deterministic.

### 6.2 `wtStock` NAV Tracking via `convertToAssets`

The vault under price is an ERC-4626 `wtStock` wrapper. Its
`vault.totalAssets() / vault.totalSupply()` ratio is exactly what
`convertToAssets(1 share)` would return, and is the canonical handle on any NAV
bump the underlying `tStock` vault has applied. After a stock split, the
underlying receipt vault's balances rebalance, `wtStock.totalAssets()` rises
proportionally, and the next post-pause price read picks up the new ratio
without any oracle-side intervention.

This is intentional: the oracle does not encode split ratios, dividend amounts,
or any action-specific math. All accounting lives in the vault; the oracle just
multiplies. The auto-pause window covers the period where the rebalance is still
settling and the ratio is mid-transition. After the post-window closes, reads
resume against the updated ratio.

This is also why the wrapper does not allow swapping `upstream`: if a future
admin could redirect to a different priced source, the (paused-correctly)
share-price invariant would no longer be guaranteed by construction.

---

## 7. Beacon-Proxy & Upgrade Model

Both `DIAVaultOracle` and `PausableOracleWrapper` follow the standard
`st0x.deploy` BeaconSetDeployer pattern:

- Each contract has a `BeaconSetDeployer` constructor that takes an
  implementation address and an initial beacon owner, then constructs a fresh
  `UpgradeableBeacon` internally and holds it as an `immutable`.
- Proxies (`BeaconProxy`) are minted via the deployer's `new...()` method and
  initialized through `ICloneableV2.initialize(bytes)`. Init returning anything
  other than `ICLONEABLE_V2_SUCCESS` reverts the deploy.
- After construction, the deployer retains no authority over the beacon.
  Implementation upgrades and beacon-owner rotations are handled externally by
  whoever the beacon's `Ownable` owner is (ST0x governance multisig).

**What the beacon owner can do:**

- Swap the implementation behind the beacon (bug fixes, gas optimisations).

**What the beacon owner cannot do:**

- Change a proxy's `upstream` (it's immutable in the proxy's storage).
- Change a proxy's `corporateActionsVault`, `actionTypeMask`, `pauseTimeBefore`,
  or `pauseTimeAfter`.
- Change a `DIAVaultOracle` proxy's `diaOracle`, `symbol`, `vault`, or `maxAge`.

These are immutable after init by design. A beacon upgrade can change behaviour
but cannot redirect the priced source or weaken the pause windows. The only way
to change a vault's priced source is to redeploy a fresh adapter and a fresh
wrapper, then migrate consumers — which is, again, an intentional friction
surface.

---

## 8. Deployers

**Location:** `src/concrete/deploy/`

| Contract                                 | Purpose                                                                                                                    |
| ---------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `DIAVaultOracleBeaconSetDeployer`        | Owns the `DIAVaultOracle` beacon. Exposes `newDIAVaultOracle(config)` to mint a proxy.                                     |
| `PausableOracleWrapperBeaconSetDeployer` | Owns the `PausableOracleWrapper` beacon. Exposes `newPausableOracleWrapper(config)` to mint a proxy.                       |
| `DIAOracleUnifiedDeployer`               | One-shot. `newOracleWithWrapper(config)` mints both proxies in a single transaction and wires `wrapper.upstream = oracle`. |

### 8.1 Unified Deploy

```solidity
DIAOracleUnifiedDeployConfig memory config = DIAOracleUnifiedDeployConfig({
    admin: governanceMultisig,
    oracleConfig: DIAVaultOracleConfig({
        diaOracle: IDIAOracleV2(0xCE521b52513242c5094bc56f57887BB2A05B8129),
        symbol:    "COIN",
        vault:     wtStockVault,
        maxAge:    2 hours
    }),
    pauseConfig: CorporateActionPauseConfig({
        corporateActionsVault: corporateActionsVault,
        actionTypeMask:        type(uint256).max,
        pauseTimeBefore:       1 hours,
        pauseTimeAfter:        2 hours
    })
});

(DIAVaultOracle oracle, PausableOracleWrapper wrapper) =
    unifiedDeployer.newOracleWithWrapper(config);

// Hand `address(wrapper)` to consumers. Forget `address(oracle)`.
```

Atomicity is the point: a two-step deploy-then-wire-up flow opens a window for
misaddressing the adapter, which would silently mint a wrapper around the wrong
priced source. The unified deployer closes that window — the wrapper's
`upstream` slot is set to the freshly-deployed adapter inside the same
transaction that created the adapter, and both addresses are emitted in the
deployer's `Deployment(caller, oracle, wrapper)` event.

### 8.2 Per-Chain Deploy Sequence

1. Deploy `DIAVaultOracle` implementation.
2. Deploy `DIAVaultOracleBeaconSetDeployer` (it constructs its beacon).
3. Deploy `PausableOracleWrapper` implementation.
4. Deploy `PausableOracleWrapperBeaconSetDeployer` (it constructs its beacon).
5. Deploy `DIAOracleUnifiedDeployer` wired to both BeaconSetDeployers.
6. (Per vault) Call `unifiedDeployer.newOracleWithWrapper(...)`.

Steps 1-5 happen once per chain. Step 6 is one transaction per vault.

---

## 9. Vendored Interfaces

**Location:** `src/interface/`

Two interfaces are vendored locally rather than pulled as soldeer or git
dependencies:

- **`IDIAOracleV2.sol`** — DIA Data Association's published oracle interface.
  Single function:
  `getValue(string memory key) returns (uint128 value,
  uint128 timestamp)`.
  `value` is the 18-decimal price for the symbol; `timestamp` is the
  `block.timestamp` of the last on-chain push. **DIA does not revert for unset
  feeds** — it returns `(0, 0)`. The adapter checks this explicitly (see §3.4
  `DIAPriceNotSet`). Vendored because the interface is one function and stable;
  hand-typed against DIA Data Association's published interface, last synced
  2026-06-30. No drift-detection test exists — re-sync on any upstream bump.

- **`IAggregatorV2V3.sol`** — Hybrid of Chainlink's `AggregatorInterface` (v2 —
  `latestAnswer`) and `AggregatorV3Interface` (v3 — `latestRoundData`,
  `getRoundData`). Vendored to avoid taking a Chainlink dependency for an
  interface this small. The deprecated `latestAnswer()` is intentionally
  retained because Aave V3 and Compound V3 still call it; new consumers should
  prefer `latestRoundData()` and honour `updatedAt`.

---

## 10. Integrator Model

Consumers (Euler, Aave V3, Compound V3, future Chainlink-compatible markets)
target the `PausableOracleWrapper` proxy address at the
`AggregatorV2V3Interface` they already use for Chainlink feeds. No
protocol-specific shim is involved. The wrapper looks indistinguishable from a
Chainlink feed except that:

- `latestAnswer` / `latestRoundData` revert during pause windows. Consumers must
  treat these reverts as "price unavailable", not "price is the last successful
  read".
- `getRoundData(_roundId)` always reverts when the upstream is `DIAVaultOracle`.
  Consumers should not rely on historical round lookups against this stack.

### 10.1 Operational Preconditions

For any consumer that wraps reads in `try / catch`:

1. **Do not configure a fallback oracle on the same bToken that points at a raw
   DIA / raw Chainlink / raw anything feed.** A fallback would silently mask the
   pause errors — exactly the failure mode the auto-pause is supposed to make
   loud. A pause must surface to the protocol as `OraclePriceNotFound` (or its
   equivalent), not get swallowed by a fallback that wasn't aware the price was
   deliberately withheld.

2. **The consumer's own `maxPriceAge` (or equivalent staleness threshold) must
   be greater than or equal to the adapter's `maxAge`.** Otherwise the
   consumer's check rejects the read before the adapter's internal
   `DIAPriceStale(timestamp)` revert can fire, and the deployment loses the
   layered staleness signal. Configure consumer staleness as a strict upper
   bound on adapter staleness.

---

## 11. Signed-Price Stack (`ST0xPriceOracle` + `MorphoPairOracle`)

Alongside the DIA stack, the repo ships a publisher-signed price stack for
Morpho Blue markets. It shares the beacon-proxy upgrade model (§7) but is
otherwise independent: no DIA feed, no vault ratio, no pause wrapper.

### 11.1 `ST0xPriceOracle`

Singleton multi-pair price store behind a beacon proxy (Initializable +
AccessControl, ERC-7201 namespaced storage).

- **No pair registration.** Pair ids are deterministic —
  `keccak256(abi.encodePacked(baseToken, quoteToken))`, exposed as the `pairId`
  pure helper — and the first `updatePrice` on a brand-new pair simply works.
- **Opaque values.** Prices are raw `uint256`s; scaling and semantics belong
  entirely to the publisher/consumer of each pair. The contract never interprets
  them.
- **Permissionless `updatePrice`.** The global publisher's EIP-712 signature
  over `(pairId, price, timestamp)` authorises an update, not the caller.
- **Replay defence is the strict per-pair timestamp inequality.** An update
  applies only if its timestamp is strictly newer than the stored one. A
  not-strictly-newer payload is a NO-OP returning `false` (never a revert, so a
  caller may push-then-consume in one transaction without risking a brick on a
  lost race). A strictly-newer payload timestamped in the future reverts
  `PriceFuture` — storing it would strand `price()` behind an arithmetic
  underflow. An invalid signature on an otherwise-fresh payload reverts
  `PriceUpdateInvalidSignature`.
- **Cross-chain replay is deliberate.** The EIP-712 domain binds name + version
  only — no chainId, no verifyingContract, no nonce — so one signed payload is
  valid on every deployment sharing the global signer. This fans a single
  publisher signature out to every chain by design.
- **Global config.** `signer` and `timeout` are global across all pairs, rotated
  via `ORACLE_ADMIN_ROLE`-gated `setSigner` / `setTimeout` — deliberately
  separate functions so the two config axes can never race each other inside one
  calldata blob. `DEFAULT_ADMIN_ROLE` (granted at `initialize`) does role
  administration only.
- **Reads.** `price(id)` reverts `PriceUnset` when no update has ever landed and
  `PriceStale` once the stored timestamp ages past `timeout`. `pairPrice(id)`
  exposes the raw stored state (no staleness check) for publishers sizing their
  next timestamp and for monitoring.

### 11.2 `MorphoPairOracle`

Thin adapter binding one Morpho Blue market to one pair on the central store. It
is literally the interface: `price()` forwards `iCentral.price(sPairId)`
verbatim — scaling, staleness policy, signer rotation and update mechanics all
live on the central oracle.

Every market's adapter is a `BeaconProxy` over one shared `UpgradeableBeacon`,
so a single beacon upgrade retargets all deployed adapters at once. The central
oracle address is an implementation immutable (chain-constant, shared by every
proxy); only the per-market `sPairId` is proxy storage, set once in
`initialize`.

---

## 12. Repository Structure

```
st0x.oracle/
├── script/
│   └── Deploy.sol                   ← DEPLOYMENT_SUITE dispatch (CI deploys)
├── src/
│   ├── concrete/
│   │   ├── oracle/
│   │   │   ├── DIAVaultOracle.sol
│   │   │   ├── ST0xPriceOracle.sol
│   │   │   └── MorphoPairOracle.sol
│   │   ├── wrapper/
│   │   │   └── PausableOracleWrapper.sol
│   │   └── deploy/
│   │       ├── DIAVaultOracleBeaconSetDeployer.sol
│   │       ├── PausableOracleWrapperBeaconSetDeployer.sol
│   │       └── DIAOracleUnifiedDeployer.sol
│   ├── interface/
│   │   ├── IDIAOracleV2.sol         ← vendored DIA interface
│   │   ├── IAggregatorV2V3.sol      ← vendored Chainlink shape
│   │   └── IOracle.sol              ← vendored Morpho Blue oracle shape
│   └── lib/
│       └── LibCorporateActionsPause.sol
└── test/
    ├── mocks/
    │   ├── MockAggregatorV2V3.sol
    │   ├── MockDIAOracle.sol
    │   ├── MockCorporateActions.sol
    │   ├── MockERC4626.sol
    │   ├── MorphoPairOracleV2.sol
    │   └── TestERC1967Proxy.sol
    └── src/
        ├── concrete/
        │   ├── oracle/
        │   ├── wrapper/
        │   └── deploy/
        ├── lib/
        └── e2e/
            └── DIAStackE2E.t.sol
```

---

## 13. Security Considerations

1. **DIA "not set" must surface, not mask.** DIA's `getValue` returns `(0, 0)`
   for unset feeds rather than reverting. The adapter checks this explicitly and
   raises `DIAPriceNotSet()`. A zero-value Chainlink answer passed through to a
   consumer that does not check for zero would be silently catastrophic.
2. **DIA staleness must surface, not mask.** `block.timestamp - timestamp
   > maxAge`reverts`DIAPriceStale(timestamp)`. A stalled feed is always an
   > oracle failure that must reach the consumer.
3. **`maxAge == 0` is rejected at init.** A zero `maxAge` would make every read
   instantly stale; failing loud at init is preferable to minting an
   always-reverting oracle. Recommended value: `2 hours` (see §3.6).
4. **Vault ratio is trusted.** `totalAssets / totalSupply` is taken at face
   value. The vault must be a known ST0x deployment; pricing a hostile ERC-4626
   implementation is out of scope.
5. **Zero vault supply reverts.** Pricing a share of a zero-supply vault is
   undefined; the adapter reverts `ZeroVaultSupply()`.
6. **`NODE_NONE` is the no-match sentinel, not `0`.** See §5.4. Misreading this
   would treat the bootstrap node as a real corporate action.
7. **Pending-wins overlap rule.** See §5.3. If a future change reverses this,
   integrators reading the `effectiveTime` payload would see the wrong "next
   event" timestamp.
8. **Wrapper `admin` is single-step and zero-rejected on transfer.** A
   misaddressed transfer permanently locks `setPaused`; use a multisig.
9. **Upstream and pause config are immutable.** No admin path can redirect the
   priced source or weaken pause windows; only redeploy + migration.
10. **`getRoundData` reverts on DIA-backed deployments.** Consumers that depend
    on historical round lookups will fail loudly, not get wrong-but-plausible
    data.
11. **Fallback oracles on the consumer side undermine the pause feature.** See
    §10.1. The pause must reach the consumer; a fallback that hides it defeats
    the security property.
12. **Bare-symbol key requirement.** DIA feeds are keyed by the bare ticker
    (`"COIN"`, `"AMZN"`, `"TSLA"`), not a pair string. A wrong key returns
    `(0, 0)` from DIA and is caught at the `DIAPriceNotSet()` boundary, but
    deployers should still confirm the symbol matches the DIA registry on the
    target chain before minting a proxy.

---

## 14. References

- **DIA Data Association** — https://www.diadata.org/
- **DIA oracle on Base mainnet** — `0xCE521b52513242c5094bc56f57887BB2A05B8129`
- **`st0x.deploy` (corporate actions, BeaconSetDeployer pattern,
  `ICloneableV2`)** — https://github.com/S01-Issuer/st0x.deploy
- **`rain-math-float`** — https://github.com/rainlanguage/rain.math.float
- **Chainlink `AggregatorV2V3Interface`** —
  https://github.com/smartcontractkit/chainlink
- **ERC-4626 Tokenized Vault Standard** —
  https://eips.ethereum.org/EIPS/eip-4626
