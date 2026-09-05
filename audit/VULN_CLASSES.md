# AxiumPass — Vulnerability-Class Deep Dives (living corpus)

> **What this is.** A companion to [`AUDIT_METHODOLOGY.md`](./AUDIT_METHODOLOGY.md):
> the *per-vulnerability-class* half of the security corpus. Each class is
> captured as **mechanism → detection & neutralisation procedure → AxiumPass
> application** (evidence-anchored to real `file:line`). Integrated on a rolling
> basis as course modules arrive (see the [Intake log](#intake-log)).
>
> The point is not to restate theory — it is to *apply* each class to the
> AxiumPass contracts and record an honest verdict, so the corpus doubles as a
> standing self-audit that regresses only if the code regresses.

Scope of the on-chain surface (from `INTERNAL_AUDIT_2026-07.md` §1):

| Contract | File | Pragma | Status |
|----------|------|--------|--------|
| SubscriptionVault **v1** | `contracts/src/SubscriptionVault.sol` | `^0.8.20` | **LIVE** (Polygon/Base/Arbitrum/Optimism) |
| **AutoSwapRouter** | `contracts/src/AutoSwapRouter.sol` | `^0.8.24` | **LIVE** (Base/Polygon) |
| SubscriptionVault **v2 (4337)** | `contracts/src/SubscriptionVault4337.sol` | `^0.8.24` | not deployed (external review = gate) |

---

## 1. Arithmetic — overflow / underflow & phantom overflow

### 1.1 Mechanism

Integers on the EVM are fixed-width and **wrap around** on overflow/underflow
in unchecked arithmetic — a single incorrect calculation can turn an empty
balance into a fortune.

- **Wrap-around (uint8 example).** `255 + 1 → 0` (overflow, back to 0);
  `0 - 1 → 255` (underflow). The increment path and the decrement path are both
  exploitable attack surfaces.
- **EVM numeric ranges.**

  | Type | Range | Note |
  |------|-------|------|
  | `uint8` | 0 … 255 | wraps fast |
  | `uint16` | 0 … 65 535 | |
  | `uint256` | 0 … 2²⁵⁶−1 | the default width |

- **Danger zone.** *Even `uint256` can overflow* when manipulated with values
  near its limit in **multiplicative or exponential** operations.
- **Phantom overflow.** In multi-step expressions, an **intermediate** product
  can overflow **even if the final result would fit** the type. This is the
  subtle case: `a * b / c` can revert/wrap in `a * b` although `a * b / c` is
  small.

### 1.2 Detect & neutralise — procedure (course)

> A dedicated sub-procedure from the course. Steps captured verbatim as they
> arrive; more may follow (see intake log).

1. **Identify the Solidity version.** Contracts `< 0.8.0` are **high risk** and
   need manual checks or **SafeMath**. Migrating to `0.8+` is recommended (it
   makes arithmetic *checked* — overflow/underflow **revert** instead of
   wrapping) but then requires auditing every **`unchecked { … }`** block, which
   opts back out of those guarantees.
2. **Map the arithmetic operations.** Locate every `ADD`, `SUB`, `MUL`, `EXP`.
   Pay special attention to complex **multi-step** operations where
   **intermediate overflows (phantom overflows)** can occur even if the final
   result fits the type.
3. **Verify the checks in place.** For `< 0.8.0`: confirm the **systematic** use
   of SafeMath. For `≥ 0.8.0`: inspect **every `unchecked` block** with a formal
   proof or a detailed analysis justifying its safety.
4. **Test boundary values.** Apply **fuzzing** with extreme values — `0`, `1`,
   `type(uint).max`, `type(uint).max - 1`, and values that produce **intermediate
   overflows**. Unanticipated edge cases are often exploitable.
5. **Audit proxy architectures.** Verify **EIP-1967** conformance for the
   placement of proxy vs. implementation variables. Ensure implementation
   upgrades preserve the coherence of shared storage slots to avoid collisions
   (see §2).

### 1.3 AxiumPass application (evidence)

**Step 1 — versions.** All three contracts are `≥ 0.8.20` → arithmetic is
**checked by default**: any overflow/underflow **reverts**, it never silently
wraps. The whole "empty balance → fortune" wrap primitive is off the table at
the language level. Residual risk lives only in (a) `unchecked` blocks and
(b) phantom overflows that would *revert* (a DoS, not a theft).

**`unchecked` blocks:** **none** in any AxiumPass contract (`grep -rn unchecked
contracts/src` → 0 hits). No opt-out of the checked-arithmetic guarantee.

**Step 2 — arithmetic map & verdict.**

| Location | Operation | Analysis | Verdict |
|----------|-----------|----------|---------|
| `SubscriptionVault.sol:180` | `sub.nextPaymentTime += sub.periodSeconds` (ADD) | Checked. Overflow needs `timestamp + period > 2²⁵⁶−1` — unreachable with real timestamps; would revert anyway. | ✅ safe |
| `SubscriptionVault.sol:181-182` | `if (remainingPayments > 0) remainingPayments -= 1` (SUB) | Decrement **guarded by an explicit `> 0` check** → cannot underflow; checked besides. Textbook-correct. | ✅ safe |
| `AutoSwapRouter.sol:251-252` | `amountIn * answer * 10**toDec / (10**fromDec * 10**feedDec)` (**MUL ×3**, the phantom-overflow shape) | **The exact multi-step multiplication the course flags.** Checked → **reverts, never wraps**. Bounds: `amountIn ≤ rule.maxAmountPerSwap` (merchant-set), `answer` = Chainlink feed (≈1e8 for USD feeds), `10**toDecimals ≤ 1e18` → realistic product ≲1e56 ≪ 2²⁵⁶ (≈1.16e77). Overflow **unreachable** for any real stablecoin swap; if ever hit it reverts (funds safe, at most a self-inflicted DoS on an absurd rule). | ⚪ Informational — **watch item** |
| `AutoSwapRouter.sol:253` | `expected * (BPS - maxSlippageBps) / BPS` (MUL) | `expected` already bounded (above), `BPS`/slippage small constants. Checked. | ✅ safe |
| `AutoSwapRouter.sol:244` | `block.timestamp - updatedAt` (SUB) | Underflows (→ reverts) only if the feed returns a **future** `updatedAt`; a revert here is a *safe* failure (never proceeds on bad data). | ⚪ Informational |
| `AutoSwapRouter.sol:286` | `r.lastExecuted + r.minIntervalSec` (ADD) | Checked; timestamps + small interval → unreachable overflow. | ✅ safe |

`SubscriptionVault4337.sol` (v2, not deployed) mirrors the v1 discipline:
`nextChargeTime += period` (checked ADD) and a `> 0`-guarded `remainingPayments`
decrement; no `unchecked`, no `MUL`/`EXP` in the money path.

**Class verdict.** Neutralised by construction: `≥0.8` checked arithmetic +
zero `unchecked` blocks + `>0`-guarded subtraction + realistic bounds on the one
multiplicative expression. The **single line to keep under watch** is the
`_oracleFloor` product (`AutoSwapRouter.sol:251`) — it is only Informational
**because** `maxAmountPerSwap` bounds it; if that cap is ever removed/loosened,
or a non-standard high-decimals feed is introduced, re-derive the bound (and
consider `Math.mulDiv` for full-precision intermediate handling). This aligns
with the internal audit's treatment of `_oracleFloor` as the optional price
floor (finding **F3**).

**Step 3 — checks in place.** All contracts are `≥ 0.8.0` and contain **zero
`unchecked` blocks**, so there is nothing to justify: every arithmetic op runs
under the compiler's checked semantics. (Were an `unchecked` block ever added,
this corpus requires a written safety argument beside it before merge.)

**Step 4 — boundary values.** Beyond the stateful custody-invariant campaigns
(`SubscriptionVaultInvariant.t.sol`, `SubscriptionVault4337Invariant.t.sol`),
the arithmetic edges are now pinned by a dedicated boundary/fuzz suite,
**`contracts/test/SubscriptionVaultArithmetic.t.sol`** (shipped — runs in the
CI `foundry` job, which is the verifier here since `forge` isn't installable in
the agent sandbox; see the note below):
  - `test_PeriodOverflow_ChargeReverts_NoWrap` — a `type(uint256).max` period
    makes `nextPaymentTime += period` **revert** (no wrap), atomically rolling
    back the charge;
  - `testFuzz_ChargeAdvancesOrReverts_NeverWraps(uint256 period)` — the full
    property over every period value: a charge either advances correctly or
    reverts on overflow; there is **no** wrap-around third outcome;
  - `test_RemainingPayments_DeactivatesAtBoundary` +
    `testFuzz_RemainingPaymentsExhaustCleanly(uint8 n)` — the `> 0`-guarded
    decrement holds across the `{0,1}` boundary and the `[1,12]` range, so
    `remainingPayments` never underflows.

  These pin behaviour that is already correct (checked arithmetic makes it
  revert), so they guard against a *future* regression (e.g. an added `unchecked`
  block) rather than fixing a live bug. **Still recommended (not shipped):** the
  `AutoSwapRouter._oracleFloor` product boundary — it needs a mock Chainlink
  feed + decimals harness, so it is deferred to a router-test change rather than
  shipped blind; the exact case is recorded in §1.3 Step 2's watch item.

  > **On the `forge` constraint.** The agent sandbox's network policy blocks the
  > Foundry binary hosts (`foundry.paradigm.xyz` and the GitHub release assets),
  > so `forge` cannot be installed to run tests locally. The resolution is not to
  > avoid Foundry tests — it is to **author them against the already-passing test
  > patterns and let the CI `foundry` job be the verifier** (it installs Foundry
  > and runs `forge test` on every PR). CI failures surface as webhooks and are
  > fixed automatically, so nothing is required of the founder either way.

**Step 5 — proxy architectures.** N/A — no proxy anywhere (see §2).

---

## 2. Storage collision (proxy / `delegatecall`)

### 2.1 Mechanism

When a **proxy** `delegatecall`s an implementation, both share the **proxy's**
storage. If the proxy keeps governance in `slot0` (e.g. `address admin`) and an
implementation writes a business variable (e.g. a `uint256 balance`) to the same
`slot0`, the write **overwrites `admin`** — an attacker who can move a business
value can seize governance. **EIP-1967** fixes this by standardising specific,
collision-resistant slots (a `keccak256` hash) so governance variables never
share a slot with business variables.

### 2.2 AxiumPass application

**N/A — positive assurance.** There is **no proxy anywhere** in the AxiumPass
contracts: `grep -rn 'delegatecall\|proxy\|UUPS\|_authorizeUpgrade\|initializer'
contracts/src` returns **0 hits**. The vaults are **non-upgradeable** — the v1
owner is *immutable* (no `transferOwnership`; only the keeper is rotatable, per
`SECURITY_HARDENING.md` §1) and there is no implementation/proxy split. There is
no shared-storage `delegatecall` surface, so a storage-collision cannot arise.

**Forward guard.** The moment a *future* vault becomes upgradeable (the only way
to gain owner-multisig control on v1 — see F5/F18), adopt **EIP-1967** slots and
**ERC-7201 namespaced storage** for all governance state, and keep the upgrade
authority behind the Safe multisig + timelock from the hardening runbook.

---

## 3. Reentrancy

### 3.1 Mechanism — "the vicious cycle"

A contract that makes an **external call before updating its own state** can be
re-entered mid-execution and made to repeat the not-yet-finalised action:

1. Attacker contract calls `withdraw()`.
2. Victim checks the balance — **OK**.
3. Victim sends Ether (an **external call**) → triggers the attacker's
   `fallback()`.
4. `fallback()` calls `withdraw()` **again**; the victim re-checks the balance —
   **still OK!** (it hasn't been zeroed yet) → sends Ether again.
5. Loop → **infinite recursion**, draining the victim.
6. The victim finally sets the balance to `0` — **too late**.

The root cause is ordering: **interactions before effects**. The fix is the
**Checks-Effects-Interactions (CEI)** pattern (update state *before* the external
call) and/or a **`ReentrancyGuard`** (`nonReentrant`).

### 3.2 Taxonomy (course — 4 types)

| Type | Name | Shape | Standard defence |
|------|------|-------|------------------|
| **1** *(most common)* | **Single-function** | `withdraw()` re-enters `withdraw()` via the attacker's `fallback` — same function targeted. | ✅ `ReentrancyGuard` |
| **2** *(hidden)* | **Cross-function** | Function A makes an external call; the `fallback` calls function **B** that shares the **same state**. | ✅ `ReentrancyGuard` (a shared per-contract lock covers A and B) |
| **3** *(silent)* | **Cross-contract / read-only** | Contract X reads contract Y's state **before Y finishes updating it** — a "read-only" attack on stale-but-consistent-looking values. | ⛔ **`ReentrancyGuard` does NOT help** — the re-entrant path is a *view* on another contract; needs architectural care (never expose mid-update state; CEI so views are always consistent). |
| **4** *(emergent)* | **Cross-chain** | Vulnerabilities via cross-chain liquidity bridges / messaging. | 💡 Complex — advanced defensive architecture (no single modifier). |

> Types 3 and 4 **escape standard protections** and require advanced defensive
> architecture. Cross-contract read-only reentrancy (Type 3) is especially
> dangerous because it is **invisible to the classic `nonReentrant` modifier**.

### 3.3 AxiumPass application (evidence)

The deep structural defence is the **non-custodial invariant**: the vaults
**never hold funds** — every charge is a direct `transferFrom(subscriber →
recipient)`. There is no pooled balance to drain; a re-entrant call could at most
move the subscriber's own already-approved allowance to the *fixed* recipient. An
invariant fuzz campaign pins "the vault holds zero tokens" in CI
(`SubscriptionVaultInvariant.t.sol`). And the tokens are **stablecoins**
(USDT/USDC/EURC) with **no transfer callback** (unlike ERC-777), so a plain
`transferFrom` hands control to no attacker fallback in the first place.

Per-contract posture:

| Contract | Guard | Pattern | Verdict |
|----------|-------|---------|---------|
| **SubscriptionVault v1** (LIVE) | ❌ no `ReentrancyGuard` | ⚠ **CEI violated** — `transferFrom` at `L177` runs **before** the state updates at `L180-186` | 🟢 **Low — this is documented finding F8.** Latent, **not exploitable on the current token set** (callback-free stablecoins) and non-custodial (nothing extra to drain). Mitigation is operational: the backend `TOKEN_REGISTRY` only ever points v1 at USDT/USDC/EURC. |
| **SubscriptionVault4337 v2** (not deployed) | ✅ `ReentrancyGuard` (`nonReentrant` on `subscribeWithPermit` L277 + the charge path L325) | ✅ `SafeERC20`; M-1 **token allowlist** (owner-approved stablecoins only) | ✅ Closed by construction — guard **and** allowlist **and** custody-free. |
| **AutoSwapRouter** (LIVE) | ✅ `ReentrancyGuard` (`nonReentrant` on `executeSwap` L279) | ✅ `SafeERC20`; `whenNotPaused`; post-swap `received ≥ minOut` check | ✅ Guarded; the untrusted external call (1inch) is bounded by the guard + `minOut` (see also F1's *receiver*-binding fix, a separate axis). |

**By taxonomy type (AxiumPass):**

- **Type 1 — single-function.** v2 + router: `nonReentrant`. v1: F8 (below).
- **Type 2 — cross-function.** The re-entrant fallback would call a *different*
  state-sharing function. On v2/router the `nonReentrant` lock is **per-contract**,
  so it covers A **and** B — Type 2 is closed wherever Type 1 is. On v1 (no guard),
  the same token-callback argument applies: the stablecoins can't hand control to
  a fallback, and the only state-mutating entrypoints (`processSubscription`,
  `cancelSubscription`) are `msg.sender`-scoped and custody-free.
- **Type 3 — cross-contract / read-only.** ⛔ the one `nonReentrant` cannot catch.
  **AxiumPass exposure: none material.** Read-only reentrancy requires (a) an
  external call that yields control mid-update, and (b) some *other* protocol
  reading our view during that window and trusting it. AxiumPass has neither: our
  charge path makes no attacker-controlled external call (callback-free
  stablecoins), and **no external protocol consumes our subscription state as an
  oracle** — the vault views (`subscriptions[id]`) are informational, not a price
  or collateral feed anyone settles against. The inverse direction — *we* read an
  external contract — happens once, at `AutoSwapRouter._oracleFloor` reading a
  **Chainlink** feed; we treat it as trusted, check staleness/`answer>0`, and
  never re-enter it. No read-only surface.
- **Type 4 — cross-chain.** AxiumPass is multi-chain, but **each chain's vault is
  fully independent** — there is **no bridge, no cross-chain message, no shared
  liquidity** in the contracts; the keeper operates per-chain and settlement is
  local. There is no cross-chain reentrancy surface. (If a cross-chain feature is
  ever added, this is where a bridge-message replay/reentrancy review attaches.)

**Class verdict.** Types 1–2 are defended (v2/router `nonReentrant`; v1 latent
**F8**, Low, closed by construction in v2, held operationally by the
callback-free-stablecoin `TOKEN_REGISTRY`). Types 3–4 have **no material
AxiumPass surface** today — the non-custodial design and the absence of any
oracle-exposed view or cross-chain bridge remove the pre-conditions the classic
`nonReentrant` cannot cover. Re-audit Type 3 the moment any external protocol
starts reading vault state, and Type 4 the moment any cross-chain settlement is
introduced.

---

## 4. `tx.origin` authentication (phishing)

### 4.1 Mechanism

`tx.origin` is the **original EOA** that started the transaction; `msg.sender` is
the **immediate caller**. Across a call chain `Alice → MaliciousContract →
Victim`, `msg.sender` at `Victim` is `MaliciousContract`, but `tx.origin` stays
`Alice` the whole way. So a victim that authorises with `require(tx.origin ==
owner)` can be **phished**: the owner is lured into calling the attacker's
`bait()`, which calls the victim's privileged function — `tx.origin` is still the
owner, the check passes, and the attacker drains the owner's funds. The wallet
"confuses the original sender with the authorised caller." **Rule: never use
`tx.origin` for authorisation — use `msg.sender`.**

### 4.2 AxiumPass application

**N/A — positive assurance.** `grep -rn 'tx.origin' contracts/src` → **0 hits**.
Every authorisation check uses **`msg.sender`**: `onlyOwner`
(`SubscriptionVault.sol:76`), `onlyKeeper` (`AutoSwapRouter.sol:135`), and
`onlyKeeperOrSubscriber` (both vaults) all compare against `msg.sender`, and the
v2 signature paths bind to a recovered signer, not `tx.origin`. No phishing
surface.

---

## 5. Native-ETH transfer functions (`transfer` / `send` / `call`)

### 5.1 Mechanism

Sending native ETH has three primitives with different failure and gas
behaviour:

| Function | Gas forwarded | On failure |
|----------|---------------|------------|
| `addr.transfer(x)` | 2300 (stipend) | **auto-revert** |
| `addr.send(x)` | 2300 (stipend) | **returns `false`** (must be checked) |
| `addr.call{value:x}("")` | all remaining gas | **returns `false`** (must be checked) |

The 2300-gas stipend (`transfer`/`send`) can **break** legitimate recipients
(a Safe/AA wallet whose `receive` costs more than 2300 gas), while `call`
forwards all gas and therefore **re-opens the reentrancy door** — so `call` for
value transfer must be paired with CEI + a reentrancy guard, and `send`/`call`
return values must always be checked.

### 5.2 AxiumPass application

**N/A — the contracts never send native ETH.** They move value exclusively as
**ERC-20** via OpenZeppelin **`SafeERC20`** (`safeTransferFrom`), never `.transfer`
/`.send`/`.call{value}`. `grep -rnE '\.transfer\(|\.send\(|call\{value|msg\.value'
contracts/src` finds only ERC-20 `transferFrom`/`safeTransfer*` and doc comments;
the AutoSwapRouter explicitly declares it holds no ETH — **no `receive()` nor
`payable fallback()`** (`AutoSwapRouter.sol:27-28`). So the gas-stipend and
value-`call` reentrancy pitfalls do not apply. (`SafeERC20` also handles the
non-standard-ERC20 "returns nothing / returns false" cases the `send`/`call`
row warns about, for token transfers.)

---

## 6. Access control & privileged roles

### 6.1 Mechanism

Privileged actions must be gated by an explicit, **least-privilege** authority.
OpenZeppelin's **`AccessControl`** models this as a **role hierarchy** rooted at
`DEFAULT_ADMIN_ROLE`, which administers granular roles — `MINTER_ROLE` (create
tokens), `BURNER_ROLE` (destroy tokens), `MODERATOR_ROLE` (freeze accounts), … —
each **grantable/revocable** by its own admin role ("**guardian**": every role
has an administrator that can grant or revoke it). Each specific role delegates a
single responsibility, so no key holds more power than its job needs. The classic
failures: missing/incorrect modifiers, an over-powerful single key, unprotected
initialisers, `tx.origin` auth (§4), and no safe hand-off of ownership.

**Choosing a protection pattern** (complexity vs. main risk):

| Pattern | Complexity | Main risk |
|---------|-----------|-----------|
| **Ownable** | Simple | single-key loss / compromise |
| **RBAC** (`AccessControl`) | Moderate | complex to administer correctly |
| **Timelock** (+ multisig) | High | blocking config (delay on every change) |

**The multisig + timelock cascade** (the strong end-state for a live protocol):
a **3-of-5 multisig** → a **48 h timelock** → the target contract. Set-up order:
① create the multisig, ② deploy the timelock, ③ configure roles, ④ renounce the
deployer admin, ⑤ transfer ownership to the timelock. **Result:** every sensitive
action needs a multisig-signed proposal, a 48 h public wait, then a public
execution — a **separation of powers** where no single entity can act
immediately. This is what turns "trust the owner key" into "observe-then-veto".

### 6.2 AxiumPass application

AxiumPass deliberately uses the **simpler two-authority model**, not a full role
hierarchy (there is no mint/burn — funds are merchant/customer ERC-20, never
minted by us):

- **Owner** — `Ownable2Step` on the v2 vault and `AutoSwapRouter` (safe two-step
  key rotation, `renounce` disabled); **immutable owner** on the v1 vault (no
  `transferOwnership` — see F5/F18).
- **Keeper** — `onlyKeeper` / `onlyKeeperOrSubscriber`, rotatable by the owner
  (`setKeeper`), authorised to trigger charges but **never** to change a
  subscription's `amount`/`recipient` (fixed at enrolment) — the non-custodial
  boundary.

Known access-control findings already tracked in the internal audit:
- **F1 (Critical, LIVE, AutoSwapRouter)** — a *compromised keeper* could redirect
  swap output because the receiver wasn't bound on-chain; the fix binds the
  receiver + enforces a `minOut` floor. This is the access-control blast-radius
  that matters most and is why the keeper key hygiene + monitoring in
  `SECURITY_HARDENING.md` §3 exist.
- **F5/F18** — v1's owner is a single immutable hot key; mitigated by hardware-key
  custody + keeper monitoring, and only fully resolved by a v2 migration to a Safe
  multisig + timelock.

**Verdict.** The model is intentionally minimal and least-privilege; the residual
risk is **key-management** (owner/keeper are hot keys), which is an *operational*
control (§ hardening runbook), not a missing on-chain check. Mapped to the
pattern table above, AxiumPass sits at **Ownable** today (main risk = single-key
loss), and the documented end-state — the exact **multisig + timelock cascade**
of §6.1 — is already prescribed in `SECURITY_HARDENING.md` §1 (Safe multisig +
48 h timelock), landing with a v2 migration since the v1 owner is immutable.
If a future contract ever needs granular roles (e.g. a pauser or moderator
separate from the owner), adopt `AccessControl` with `DEFAULT_ADMIN_ROLE` behind
that multisig, giving each role its own guardian.

---

## 7. Flash-loan + oracle-price manipulation

### 7.1 Mechanism

An atomic, capital-free attack in **one transaction** (so if any step fails the
whole thing reverts — the attacker risks nothing):

1. **Flash-borrow** a large amount.
2. **Manipulate the spot price** on a shallow venue (e.g. skew an AMM pool's
   `getReserves`).
3. **Exploit the protocol** that reads that spot price for valuation
   (over-borrow, mint too cheap, liquidate unfairly…).
4. **Extract funds.**
5. **Repay** the flash loan — keep the net profit.

The root cause is **valuing anything off a manipulable spot price**. Defence: use
a manipulation-resistant oracle (**Chainlink** decentralised feeds / **TWAP**),
never a single-block AMM spot; bound outputs with a `minOut`/floor; add staleness
checks.

### 7.2 AxiumPass application (evidence)

**Two layers, both clean:**

1. **The billing path is price-free.** Subscriptions are **fixed stablecoin
   amounts** (the stablecoins-only, fixed-amount invariant) — the vault charges
   `sub.amount`, reads **no** price and **no** oracle. There is simply no
   valuation to manipulate, so flash-loan/oracle manipulation has **zero surface**
   in the core product.
2. **The one price-dependent path is defended with the right oracle.** Only the
   AutoSwapRouter's optional `_oracleFloor` (F3) reads a price — and it reads a
   **Chainlink `AggregatorV3`** (`IAggregatorV3.latestRoundData`), *not* a
   flash-loan-manipulable AMM spot, with `answer > 0` + **staleness**
   (`feedHeartbeat`) checks and a slippage-bounded floor. Even if the swap venue
   (1inch) is fed a manipulated route, the merchant is protected by the
   Chainlink-derived floor **and** `minOut`.

**Test evidence (already in CI):**
- `AutoSwapRouter.t.sol::test_OracleFloor_RevertsBelow_PassesAbove` — a
  below-market swap (1500 USDC vs. a $1600 Chainlink feed, floor 1584) **reverts**
  `BelowOracleFloor`; a fair rate passes. This is exactly the "manipulated price →
  blocked" property.
- `test_OracleFloor_StaleFeed_Reverts` — an aged feed answer **reverts**
  `StaleOrBadFeed`, so a manipulated/stale oracle can't be used at all.

**Verdict.** No flash-loan/oracle surface in the billing engine (price-free by
invariant); the single price-reading path uses a manipulation-resistant Chainlink
oracle + `minOut` + staleness, proven by existing passing tests. Positive
assurance. Re-audit only if a future feature ever values something off an
on-chain **AMM spot** price — that is the pattern to never introduce.

### 7.3 The three oracle architectures (and which AxiumPass uses)

| Architecture | Examples | How it prices | Manipulation risk | AxiumPass |
|--------------|----------|---------------|-------------------|-----------|
| **Centralised** | Coinbase, Kraken | single entity pushes updates | single point of failure; **direct manipulation** by that entity | ❌ not used |
| **Decentralised** | **Chainlink**, Band | multi-source aggregation over an independent node network | **resistant via redundancy** | ✅ **this is what `_oracleFloor` uses** |
| **On-chain (DEX)** | Uniswap, PancakeSwap | derived from pool reserves (spot) | **the main attack target** — anyone can move the data source with a flash loan | ❌ **never used** — the pattern to never introduce |

AxiumPass sits squarely on the resistant tier (decentralised Chainlink) for the
one price it reads, and avoids the vulnerable tier (DEX-spot) entirely.

**Defensive strategies against price manipulation** (course) — principle → limit,
mapped to AxiumPass:

| Technique | Principle | Limitation | AxiumPass |
|-----------|-----------|------------|-----------|
| Decentralised oracles | multi-source aggregation w/ median | integration cost/complexity | ✅ Chainlink for `_oracleFloor` |
| Multi-oracle failover | compare Chainlink + on-chain TWAP | handling price divergence | ↗ future: add a TWAP cross-check if a second price-path appears |
| RBAC access controls | restrict updates to authorised roles | central point if mis-managed | ✅ `onlyKeeper`/owner gate updates (§6) |
| Timelocks + multisig | delay before changes apply | latency on emergency updates | ↗ prescribed for owner (F5/F18, §6.1) |
| Health / sanity checks | validate against historical sources | false positives in extreme volatility | ✅ `answer > 0` + `feedHeartbeat` staleness in `_oracleFloor` |

Net: of the five defences, AxiumPass already runs the three that apply to a
single-price, price-free-billing design (decentralised oracle, RBAC-gated
updates, staleness/sanity checks); the other two (multi-oracle failover,
owner timelock) are recorded as forward items keyed to features that don't exist
yet.

---

## Intake log

| Date | Module / source | Integrated as |
|------|------------------|---------------|
| 2026-07-08 | Arithmetic rebound / EVM ranges / phantom overflow + "Détecter & Neutraliser" procedure (Steps 1–2) | §1 — mechanism, procedure, and a full AxiumPass arithmetic map with per-line verdicts |
| 2026-07-08 | Storage-collision (proxy `delegatecall`, EIP-1967) diagram | §2 — mechanism + N/A assurance (no proxy) + forward guard |
| 2026-07-08 | Arithmetic procedure **Steps 3–5** (verify checks / boundary-value fuzzing / proxy audit) | §1.2 + §1.3 — application notes; honest boundary-fuzz gap + exact recommended cases |
| 2026-07-08 | **Vuln-class module 2 — Reentrancy** (vicious-cycle sequence + 4-type taxonomy, Type-1 confirmed) | §3 — mechanism, taxonomy, per-contract posture; mapped to documented finding **F8** (v1 CEI/no-guard, Low/latent) + v2/router `nonReentrant` |
| 2026-07-08 | **Reentrancy taxonomy Types 2–4** (cross-function / read-only cross-contract / cross-chain) | §3.2 + §3.3 — full taxonomy; AxiumPass audit of each (Type 3/4 = no material surface, with the pre-conditions spelled out) |
| 2026-07-08 | **Step-4 boundary tests SHIPPED** | `contracts/test/SubscriptionVaultArithmetic.t.sol` (4 tests, CI-verified via the `foundry` job) — resolves the earlier "not shipped" gap; the `forge`-constraint workaround documented in §1.3 Step 4 |
| 2026-07-08 | **Vuln-class module 3 — `tx.origin` phishing** | §4 — mechanism + N/A assurance (0 `tx.origin`; all auth via `msg.sender`) |
| 2026-07-08 | **Vuln-class module 4 — native-ETH `transfer`/`send`/`call`** | §5 — gas-stipend/return-value table + N/A assurance (ERC-20-only via `SafeERC20`, no `receive`/`payable`) |
| 2026-07-08 | **Vuln-class module 5 — access control / role hierarchy** | §6 — mechanism + AxiumPass Owner(`Ownable2Step`)/Keeper model mapped to findings **F1**, **F5/F18** |
| 2026-07-08 | Access-control cont'd — role guardian/least-privilege, pattern-selection matrix (Ownable/RBAC/Timelock), **multisig + 48 h timelock cascade** | §6.1 — patterns + cascade workflow, reconciled with `SECURITY_HARDENING.md` §1 |
| 2026-07-08 | **Vuln-class module 6 — flash-loan + oracle-price manipulation** | §7 — 5-step atomic-attack mechanism + AxiumPass audit: billing is price-free (zero surface); the `_oracleFloor` uses Chainlink + `minOut` + staleness, proven by existing passing router tests |

_Next intake: further vulnerability classes as their course images arrive —
each appended here and
applied to the AxiumPass surface with fresh evidence._
