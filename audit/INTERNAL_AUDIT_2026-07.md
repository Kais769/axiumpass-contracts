# AxiumPass — Internal Security Audit (2026-07)

> **Nature of this document.** This is an **internal, adversarial security review**
> of the AxiumPass smart contracts, produced with a multi-agent auditor panel
> (13 specialist auditors across every major vulnerability class) followed by
> multi-lens adversarial verification and independent expert confirmation of every
> consequential finding against the actual source. It is rigorous, but it is **not
> a substitute for an independent external audit** and does **not** authorize a
> mainnet deployment of any not-yet-deployed contract. For the mainnet gate we
> still recommend a paid external review — cheapest first: a public **bug bounty**
> (Immunefi) or a time-boxed **audit contest** (Code4rena / Sherlock / Cantina).

- **Auditor:** internal adversarial panel + lead review.
- **Date:** 2026-07-07
- **Commit / scope baseline:** `main` @ the 4337-hardening merge (PR #104/#105).
- **Methodology:** 7-step audit process (see §2), tool-assisted + manual, every
  Critical/High/Medium finding verified against the deployed/real source.

---

## 1. Scope

| # | Contract | File | Status | Blast radius |
|---|----------|------|--------|--------------|
| A | **SubscriptionVault (v1)** | `contracts/SubscriptionVault.sol` | **LIVE** — Polygon / Base / Arbitrum / Optimism | Real merchant money **now** |
| B | **AutoSwapRouter** | `contracts/src/AutoSwapRouter.sol` | **LIVE** — Base `0x4dCdC9C2057A1367003C608606F4F05629884Dc3`, Polygon `0x1dd00Dfb68773d2043e24A0Ebb6EAdC2e6Ab1953` | Merchant funds, once rules/approvals exist |
| C | **SubscriptionVault4337 (v2)** | `contracts/src/SubscriptionVault4337.sol` | Not deployed (external review is its deployment gate) | Future |

Off-chain components in scope for the fund-flow analysis: `backend/keeper.py`,
`backend/vault_autodeploy.py`, `backend/deploy_vault_l2.py`, `backend/paymaster_guard.py`,
CI (`.github/workflows/contracts.yml`, `contracts/slither.config.json`, `contracts/foundry.toml`).

**Out of scope:** vendored OpenZeppelin/forge-std libraries, the 1inch Aggregation
Router v6 (`0x111111125421cA6dc452d289314280a0F8842A65`, treated as a trusted
immutable dependency), the FastAPI/Mongo application layer beyond the keeper/deploy paths.

---

## 2. Methodology (7-step process)

> The audit vocabulary and process this report uses — the industry-standard
> severity scale, the audience-targeted report structure, and the Cyfrin
> 10-step method it compresses — are documented in
> [`AUDIT_METHODOLOGY.md`](./AUDIT_METHODOLOGY.md) (the living methodology corpus).

1. **Planning** — enumerate contracts, entry points, privileged roles, external
   calls, and the two hard invariants (non-custodial; stablecoins-only, fixed-amount).
2. **Risk assessment** — map the attack surface to the 2024–2026 loss taxonomy
   (input validation, logic errors, access control, price/oracle manipulation,
   reentrancy, unchecked external calls, flash loans, integer overflow, insecure
   randomness, DoS) plus crypto-specifics (signatures/replay, upgradeability/admin,
   custody, cross-chain).
3. **Internal-control testing** — review existing guards: modifiers, CEI ordering,
   `SafeERC20`/`ReentrancyGuard`/`Pausable`/`Ownable2Step`, allowlists, `minOut`.
4. **Fieldwork** — line-by-line manual review of each contract + the off-chain
   keeper/deploy paths that complete the trust model.
5. **Evidence collection** — each finding anchored to an exact `file:line` with a
   concrete failure/exploit scenario; every Critical/High/Medium re-verified against
   source by three adversarial lenses (reachability, exploit-construction, code-semantics).
6. **Reporting** — this document: severity-ranked findings, impact, remediation.
7. **Follow-up** — a prioritized remediation roadmap (§7), invariant tests to encode
   (§8), and continuous on-chain monitoring (§9) so regressions are caught in production.

**Tooling.** Static analysis: **Slither** runs in CI (`fail-on: high`). This review
additionally reasons about what **Mythril**, **Semgrep**, **solhint**, and dynamic
**Echidna / Foundry invariant** fuzzing would add (see §8) — the current gate is
Slither-only and does not fuzz the invariants.

**Severity scale.**

| Severity | Meaning |
|----------|---------|
| **Critical** | Direct theft/redirection of funds or a broken non-custodial invariant on a **deployed** contract. |
| **High** | Fund loss, over-billing, or DoS under realistic conditions; robustness gaps on a live contract. |
| **Medium** | Conditional / limited-impact issues; centralization with real user harm; live-infra process gaps. |
| **Low** | Hardening / defense-in-depth; latent issues inert on the current token set. |
| **Informational** | Observations, positive assurances, style. |

---

## 3. Summary of findings

**Counts:** Critical 1 · High 1 · Medium 5 · Low 17 · Informational 5 → **29 total.**

| ID | Sev | Contract | Location | Title |
|----|-----|----------|----------|-------|
| **F1** | 🔴 Critical | AutoSwapRouter (LIVE) | `executeSwap` L217/233 | Compromised keeper can redirect/drain merchant funds — swap receiver not bound on-chain, `minOut` is keeper-controlled |
| **F2** | 🟠 High | SubscriptionVault v1 (LIVE) | `processSubscription` L174 | Catch-up scheduling back-charges every lapsed period in one block (over-billing up to allowance) |
| **F3** | 🟡 Medium | AutoSwapRouter | `executeSwap` L233 | No on-chain `minOut` floor / price reference — `minOut=0` leaves swaps sandwich-able |
| **F4** | 🟡 Medium | AutoSwapRouter | `executeSwap` L224 | Output token can be permanently trapped (receiver=self + `minOut=0`); no sweep/rescue |
| **F5** | 🟡 Medium | SubscriptionVault v1 (LIVE) | L50 | Immutable owner == hot keeper; no pause/upgrade → a live bug or key compromise can't be contained |
| **F6** | 🟡 Medium | Keeper (off-chain) | `keeper.py` | No pending-nonce mgmt / stuck-tx replacement / gas ceiling → DB↔chain divergence |
| **F7** | 🟡 Medium | SubscriptionVault v1 (LIVE) | `foundry.toml` L5 | The live v1 vault is invisible to CI — not under `src/`, no Foundry test, Slither never compiles it |
| **F8** | 🟢 Low | SubscriptionVault v1 | L171 | CEI violation on the fund-mover; no ReentrancyGuard (latent on current tokens) |
| **F9** | 🟢 Low | SubscriptionVault v1 | L171 | Raw bool `transferFrom` via custom IERC20 (no SafeERC20) — no-return token → permanent billing DoS |
| **F10** | 🟢 Low | SubscriptionVault v1 | L171 | No token allowlist → attacker-chosen token enables keeper gas-griefing / event spam |
| **F11** | 🟢 Low | SubscriptionVault4337 | L122 | Shared sequential nonce couples subscribe & cancel → invalidates a pre-signed gasless cancel |
| **F12** | 🟢 Low | SubscriptionVault4337 | L279 | `subscribeWithPermit` front-runnable → subscription created with zero allowance, permit stranded |
| **F13** | 🟢 Low | AutoSwapRouter | `createRule` L148 | `minIntervalSec` unvalidated: `0` disables throttle; near-max overflows and bricks the rule |
| **F14** | 🟢 Low | AutoSwapRouter | `transferOwnership` L125 | Single-step ownership transfer + no `pause()` → a mistyped owner freezes admin irrecoverably |
| **F15** | 🟢 Low | SubscriptionVault v1 | L96 | `setKeeper`/constructor accept zero-address keeper → halts all charging |
| **F16** | 🟢 Low | SubscriptionVault v1 | `deploy_vault_l2.py` | Cross-chain identical address relies on CREATE `(deployer,nonce)`, not verified code identity |
| **F17** | 🟢 Low | Auto-deploy | `vault_autodeploy.py` | Address persisted only after irreversible deploy → DB-write failure orphans the vault, re-deploys |
| **F18** | 🟢 Low | SubscriptionVault4337 | L18/72 | `renounceOwnership()` not disabled (one-way brick) + unilateral pause/de-allow centralization |
| **F19** | 🟢 Low | v1 (LIVE) | `keeper.py` L120 | No runtime on-chain monitoring/alerting on live vaults + keeper |
| **F20** | 🟢 Low | SubscriptionVault4337 | test suite | No stateful invariant / Echidna campaign for the two hard invariants |
| **F21** | 🟢 Low | SubscriptionVault4337 | L348 | The `arbitrary-send-erc20` Slither suppression isn't pinned by a test → silent regression risk |
| **F22** | 🟢 Low | CI | `contracts.yml` L52 | Static gate is Slither-only, `fail-on:high` only — no Mythril/Semgrep/solhint; mediums never block |
| **F23** | 🟢 Low | CI | `slither.config.json` L2 | Slither excludes `solc-version`/`pragma` → floating pragmas on live/unaudited code never flagged |
| **F24** | 🟢 Low | Build | `foundry.toml` L13 | `deny_warnings = false` contradicts its own comment — compiler warnings don't fail the build |
| **F25** | ⚪ Info | v1 & v2 | `createSubscription` | Enrolment doesn't reject `recipient == vault` → funds directed into the vault get stuck |
| **F26** | ⚪ Info | v1 | `createSubscription` | No `MIN_PERIOD` floor, no on-chain stablecoin allowlist — "stablecoins only" enforced off-chain only |
| **F27** | ⚪ Info | SubscriptionVault4337 | L272 | `permit()` called on caller-supplied, not-yet-allowlisted token before validation; reverts swallowed |
| **F28** | ⚪ Info | v1 | L171 | Blacklist/freezable stablecoins can permanently brick a subscription's charges (generic revert) |
| **F29** | ⚪ Info | v1 & v2 | charge path | **Positive assurance:** no price-oracle / AMM / flash-loan surface in the charge path |

---

## 4. Critical & High findings (detail)

### F1 — 🔴 Critical — AutoSwapRouter: compromised keeper can redirect/drain merchant funds
**Contract:** AutoSwapRouter (**deployed** Base/Polygon) · `executeSwap` (`src/AutoSwapRouter.sol:184`, call `:217`, check `:231-233`).

**Description.** `executeSwap` (`onlyKeeper`) pulls up to `rule.maxAmountPerSwap`
of the merchant's `fromToken` into the router (`safeTransferFrom(from=r.merchant)`,
L210), `forceApprove`s 1inch, then forwards **fully keeper-supplied `swapData`** to
the router via a low-level call (L217). **The contract never decodes `swapData` to
bind the 1inch output receiver to `r.merchant`.** The only fund-flow guarantee is
the post-swap check `received = toT.balanceOf(r.merchant) - before; if (received <
minOut) revert` (L231-233) — but **`minOut` is also an unvalidated keeper parameter**
(no `> 0` floor, no oracle). The leftover check (L219-228) only proves no *input*
token is stranded, not that the merchant was paid.

The contract's own comments (L20/24/33-35) and `memory/PRD.md:57` assert the output
is "codée vers le marchand" and "non-custodial par construction — the keeper can
NEVER divert funds." **Both are false:** the receiver is chosen off-chain by whoever
builds `swapData` (the keeper/backend), so the non-custodial guarantee reduces to
"trust the keeper" — exactly the single-hot-wallet compromise the design claims to survive.

**Impact.** A compromised keeper key calls `executeSwap` with `swapData` whose 1inch
`dstReceiver` = attacker and `minOut = 0`: the merchant's `fromToken` is pulled and
swapped to the attacker, `received = 0`, `0 < 0` is false → **no revert**. Repeatable
up to each rule's `maxAmountPerSwap` and the merchant's standing allowance. This is a
**deployed** contract; exploitation is gated on (a) merchant rules/approvals existing
and (b) keeper-key compromise. Per the roadmap the keeper-side `executeSwap` execution
appears still pending — **this is the window to fix it before merchants approve.**

**Recommendation.**
1. **Do not let the trusted caller supply the fund-flow guarantee.** Route the swap
   output to `address(this)` (an address the contract forces, not `swapData`), then
   `toT.safeTransfer(r.merchant, received)`; **or** decode and `require` the 1inch
   `dstReceiver == r.merchant` before the call.
2. Require `minOut > 0` and derive/clamp it from an independent on-chain reference
   (e.g. a Chainlink stable feed) or a merchant-signed floor — never a bare keeper arg.
3. Restrict the router call to a known function selector.
4. Correct the false "non-custodial by construction" comments.
5. **Incident response:** treat the deployed routers as at-risk. If any merchant has
   approved them, advise revoking the approval until a fixed router is deployed.

---

### F2 — 🟠 High — v1 vault back-charges every lapsed period in one block
**Contract:** SubscriptionVault v1 (**LIVE**) · `processSubscription` (`contracts/SubscriptionVault.sol:157`, `:174`).

**Description.** A charge is gated only on `require(block.timestamp >= sub.nextPaymentTime)`
(L157) and then advances with the **fixed increment** `sub.nextPaymentTime +=
sub.periodSeconds` (L174) instead of re-basing to now. When `nextPaymentTime` lags
wall-clock by *K* periods (keeper downtime, an off-chain "PAUSE" that leaves the
on-chain sub active, or a stretch of insufficient balance so earlier charges reverted),
*K+1* charges become simultaneously eligible: each call pulls `amount` and bumps
`nextPaymentTime` by one period (still in the past), so the next call succeeds again in
the same block. There is no per-block replay guard and no `MIN_PERIOD` floor.

Caller is `onlyKeeperOrSubscriber`, so this is a **keeper-side over-billing correctness
bug, not an anonymous-attacker drain** — and funds still reach the enrolment-fixed
merchant (non-custodial intact). But it breaks the product's "at most once per period"
promise on the **live** rail with the documented MAX-approval enrolment. **v2 explicitly
fixes exactly this** (`SubscriptionVault4337.sol:332-334`), confirming it's unintended.

**Recommendation.** Adopt the v2 forward-to-now rule:
```solidity
uint256 scheduled = sub.nextPaymentTime + sub.periodSeconds;
sub.nextPaymentTime = scheduled > block.timestamp ? scheduled : block.timestamp + sub.periodSeconds;
```
v1 is immutable and live, so in the interim: make the keeper **strictly single-charge-per-period**
(never issue catch-up calls), and **cancel paused subscriptions on-chain** rather than
leaving them active. Prioritize migrating billing to a corrected vault.

---

## 5. Medium findings (detail)

- **F3 — AutoSwapRouter, no `minOut` floor.** `minOut` is a keeper argument with no
  `> 0` requirement and no on-chain price reference; even an honest keeper's swap is
  sandwich-able if `minOut` is set loosely, and a stale/bad quote is unprotected.
  *Fix:* require `minOut > 0`, clamp against an on-chain reference or merchant-signed floor.
- **F4 — AutoSwapRouter, trapped output, no rescue.** With receiver=self + `minOut=0`
  the output stablecoin lands in the router and there is **no sweep/rescue** function
  (verified: none exists), contradicting "holds no funds." *Fix:* force output to
  `address(this)` then transfer to the merchant (see F1), and add an `onlyOwner` rescue
  for stuck tokens.
- **F5 — v1, owner == hot keeper, no pause.** The immutable `owner` is set to the
  deployer, which per the deploy model (`deploy_vault_l2.py` uses `KEEPER_PRIVATE_KEY`
  as deployer+keeper) is the **same hot wallet** as the keeper. There is no `pause` and
  no upgrade path. A discovered bug or key compromise cannot be contained on-chain.
  Blast radius is bounded because v1's `recipient` is fixed at enrolment (funds can't be
  redirected — unlike F1), so this is **Medium** (containment/centralization), not Critical.
  *Fix:* on the next vault, separate owner (multisig) from keeper and add `Pausable`
  (already present in v2).
- **F6 — Keeper, nonce/gas resilience (off-chain).** `keeper.py` reads `nonce` at
  `latest` (not `pending`), no local nonce tracking, blocks on a 180s receipt wait with
  no replacement, and has an unbounded Polygon gas add / an L2 underpricing path. A
  timed-out-but-mined tx makes the DB believe a charge failed while the chain succeeded
  → `PAST_DUE` shown though the customer paid. *Fix:* pending-nonce tracking,
  idempotency key `(chain, vault_subscription_id, period_end)`, `maxFeePerGas` cap +
  bump-and-replace, or adopt a managed relayer (**OpenZeppelin Relayer**).
- **F7 — v1 invisible to CI.** The only contract holding real money is **excluded from
  every automated check**: it sits at the repo root (not `src/`), is imported by no test,
  has no artifact in `out/`, and Slither never compiles it — so `fail-on:high` can never
  fire on it. *Fix:* bring the exact deployed source into `contracts/src/`, add
  `SubscriptionVault.t.sol` (happy-path + too-early + insufficient-allowance/balance +
  cancel + keeper-auth), and confirm Slither emits an artifact for it.

---

## 6. Low & Informational findings (condensed)

**Low.**
- **F8** v1 CEI violation (`transferFrom` before state update), no `ReentrancyGuard`,
  no allowlist — latent (standard stablecoins have no callback; not exploitable on the
  current token set).
- **F9** v1 raw bool `transferFrom` on a **custom `IERC20`** (no `SafeERC20`). A
  no-return token would make the call revert → permanent billing DoS for that sub.
  Inert on the currently-listed tokens (which return a bool), but fragile. *Fix:* `SafeERC20`.
- **F10** v1 has no on-chain token allowlist; `createSubscription` is permissionless, so
  junk tokens can spam `SubscriptionCreated` and grief a naive keeper.
- **F11** v2 shares one sequential `nonce` across subscribe & cancel → a subscriber can
  hold at most one outstanding signature, invalidating a pre-signed gasless "kill switch."
  Recoverable via the signature-free `cancelSubscription`. *Fix:* per-operation (hash-keyed) nonces.
- **F12** v2 `subscribeWithPermit` is bundle-front-runnable → subscription created with
  zero allowance and the permit stranded (no funds at risk). *Fix:* bind permit+enrol atomically.
- **F13** AutoSwapRouter `createRule` validates `maxAmountPerSwap != 0` but **never
  `minIntervalSec`** (verified L152): `0` disables the throttle; a near-`uint256max`
  value overflows `lastExecuted + minIntervalSec` and bricks the rule. *Fix:* bound it.
- **F14** AutoSwapRouter single-step `transferOwnership` + no `pause()` → a mistyped
  owner irrecoverably freezes admin. *Fix:* `Ownable2Step` + `Pausable`.
- **F15** v1 `setKeeper`/constructor accept a zero-address keeper → halts all charging. *Fix:* `require != 0`.
- **F16** Cross-chain identical vault address is a CREATE `(deployer,nonce)` coincidence,
  **not** verified code identity — don't treat address equality as a trust anchor.
  *Fix:* verify/publish source+bytecode per chain, pin init-code hash, use CREATE2 for future rollouts.
- **F17** `vault_autodeploy.py` persists the address only **after** the irreversible
  deploy → a Mongo write failure orphans the vault and re-deploys a second one next boot.
  *Fix:* persist tx-hash/intent before broadcast; make persist idempotent.
- **F18** v2 doesn't disable inherited `renounceOwnership()` (one-way brick, bypasses the
  two-step path) and concentrates pause/de-allow powers in one key. *Fix:* override
  `renounceOwnership` to revert; put owner behind multisig + timelock.
- **F19** No runtime on-chain monitoring on the live vaults/keeper (see §9). Low by
  rubric, but on live money. *Fix:* OpenZeppelin Monitor.
- **F20** No stateful invariant / Echidna campaign for the two hard invariants (see §8).
- **F21** The `arbitrary-send-erc20` suppression added this cycle isn't pinned by a test
  → a future `from`-binding regression would stay silently muted. *Fix:* add an invariant
  asserting `from == sub.subscriber`.
- **F22** CI static gate is Slither-only, `fail-on:high` only — mediums never block; no
  Mythril/Semgrep/solhint.
- **F23** Slither config excludes `solc-version`/`pragma` → floating pragmas (`^0.8.20`
  on the live v1) never flagged.
- **F24** `foundry.toml deny_warnings = false` contradicts its own "fail on any warning"
  comment — warnings don't fail the build. *Fix:* set `deny = ["warnings"]`.

**Informational.**
- **F25** Enrolment doesn't reject `recipient == vault` → funds directed to the vault get stuck (no withdrawal).
- **F26** v1 has no `MIN_PERIOD` floor and no on-chain stablecoin allowlist — the
  "stablecoins only" and period bounds are enforced only off-chain.
- **F27** v2 `subscribeWithPermit` calls `permit()` on the caller-supplied, not-yet-allowlisted
  token before validation, with all reverts swallowed by `try/catch` (contained: `nonReentrant`
  + later allowlist revert; masks legitimate permit failures). *Fix:* check allowlist first; narrow the catch.
- **F28** Blacklist/freezable stablecoins (USDC/USDT) can permanently brick a sub's charges (generic revert).
- **F29** **Positive assurance** — the vaults have **no price-oracle / AMM / flash-loan
  surface** in the charge path (fixed-amount billing confirmed). The oracle/flash-loan
  classes from the 2026 threat charts are **not applicable to the subscription vaults**
  (they *are* relevant to AutoSwapRouter's swap — see F1/F3).

---

## 7. Prioritized remediation roadmap

1. **[F1 · Critical · LIVE]** Fix AutoSwapRouter's receiver binding + `minOut` floor
   **before** any merchant enables auto-swap; if approvals already exist, have merchants
   revoke until a fixed router ships. Redeploy the corrected router.
2. **[F2 · High · LIVE]** Enforce single-charge-per-period in the keeper immediately;
   cancel paused subs on-chain; plan migration to a vault with the v2 scheduling clamp.
3. **[F7 · Medium · LIVE]** Put the live v1 source under CI (compile + Slither + a Foundry
   test) so it's no longer unmonitored.
4. **[F5/F6 · Medium · LIVE]** Separate owner (multisig) from keeper on the next vault;
   harden the keeper (nonce/gas/idempotency) or move to a managed relayer.
5. **[F3/F4/F13/F14 · Medium/Low]** AutoSwapRouter hardening: `minOut>0`, output-to-self+transfer,
   sweep, `minIntervalSec` bounds, `Ownable2Step`+`Pausable`.
6. **[F8–F10, F15, F26 · Low/Info]** v1 defense-in-depth (`SafeERC20`, allowlist, zero-checks)
   — realistically delivered by migrating to the hardened v2 lineage.
7. **[F11/F12/F18/F27 · Low/Info]** v2 pre-deployment polish (per-op nonces, atomic permit,
   disable `renounceOwnership`, allowlist-before-permit).
8. **[F16/F17 · Low]** Deployment integrity: CREATE2 + published bytecode; persist-before-broadcast.
9. **[F19–F24 · Low]** Tooling & monitoring (§8, §9).

---

## 8. Automated tooling & invariant tests to encode

**Add to CI** (beyond the current Slither `fail-on:high`):
- **Foundry invariant / Echidna fuzzing** for the hard invariants:
  - `INV-1 (non-custodial):` for every vault, `token.balanceOf(vault) == 0` after any
    sequence of create/process/cancel calls (and, for AutoSwapRouter, after `executeSwap`).
  - `INV-2 (at-most-once-per-period):` no two `SubscriptionProcessed` for the same id
    within one `periodSeconds` window (this would have caught **F2**).
  - `INV-3 (no-charge-after-cancel):` once cancelled, `processSubscription` always reverts.
  - `INV-4 (monotonic schedule):` `nextPaymentTime` strictly increases and never lands
    ≤ `block.timestamp - periodSeconds` after a charge.
  - `INV-5 (from-binding, pins F21):` every `transferFrom.from` equals the enrolment-bound subscriber.
  - `INV-6 (AutoSwapRouter payee):` after `executeSwap`, the merchant's balance increased
    by ≥ `minOut` **and** no other address received the output (this would have caught **F1**).
- **Mythril** (symbolic execution) and **solhint**/**Semgrep** (lint/pattern) as
  advisory jobs; consider surfacing Slither **medium** findings as required once triaged.
- **Formal verification** (the article's point): the fixed-amount, no-oracle charge path
  is a good candidate for **Certora** specs or the Solidity **SMTChecker** on the core
  scheduling + custody invariants — high assurance for a small, well-defined surface.

---

## 9. Runtime monitoring & incident response

The strongest lever for the **live** contracts is continuous monitoring — a live bug you
detect in one block is contained; one you learn about from a drained wallet is not.

- **OpenZeppelin Monitor** (`github.com/OpenZeppelin/openzeppelin-monitor`) on each of the
  four live vaults + AutoSwapRouter + the keeper wallet:
  - **Page** on `KeeperUpdated` / any ownership-change event (v1's keeper is mutable — an
    unexpected change is a direct compromise signal).
  - **Page** on `SubscriptionProcessed` / `SwapExecuted` with an amount beyond an expected
    ceiling or an unknown recipient.
  - **Warn** on keeper native balance below a floor (at zero, every charge silently stops).
  - **Page** on any **non-zero ERC-20 balance at a vault/router address** (INV-1 breach).
  - Route to the existing `notifications.py` Telegram/Resend `maybe_alert` path.
- **OpenZeppelin Relayer** for the keeper: managed nonce/gas, resilient resubmission —
  directly addresses **F6**.
- **safeutils.openzeppelin.com** + a **Safe multisig** as the owner of future vaults
  (addresses **F5/F18** centralization) with a timelock on the pause/allowlist powers.
- **Chain rollbacks / reorgs** (Immunefi): the keeper treats a charge as final on a 180s
  receipt; on a reorg a "mined" charge can disappear. Confirm charges to *N* confirmations
  before writing `PAID`, and reconcile on reorg — related to **F6**.

---

## 10. Closing assessment

The **v2 `SubscriptionVault4337`** is the strongest contract in the codebase (post-hardening:
`Pausable`, `Ownable2Step`, `ReentrancyGuard`, token allowlist, `MIN_PERIOD`, correct
scheduling) — its residual items are Low/Info pre-deployment polish. The **v1 vault** is
functionally sound and its non-custodial invariant holds (recipient fixed at enrolment),
but it is under-hardened, immutable, and — most importantly — **outside CI** (F7); its main
real-world risk is over-billing on lapsed periods (F2).

The one finding that demands action is **F1**: a **deployed** contract whose central
"non-custodial by construction" claim does not hold on-chain. It is not permissionlessly
exploitable, but it removes the keeper-compromise protection the whole design markets — fix
it before the auto-swap feature is switched on for merchants.

None of this authorizes an unaudited mainnet deployment of new code. Before real funds flow
through a *new* contract, obtain an external review (bug bounty / audit contest) as the gate.

---

## 11. Red-team round 2 (2026-07-08) — STRIDE, system-wide

A second adversarial pass extended scope beyond the contracts to the **whole
system** (backend API/auth, frontend/web, keeper, third-party edges), organised
with the **STRIDE** framework — see [`THREAT_MODEL_STRIDE.md`](./THREAT_MODEL_STRIDE.md)
for the full boundary-by-boundary analysis and the DEFENDED (verified-strong)
surfaces. No new Critical/High. Fixes that were safe + locally/CI-verifiable
shipped with this round; the rest are tracked below and actioned at their gate.

**Shipped this round (verified):**
- **JWT fail-fast** — `auth.py` now refuses to start on an empty `AXIUMPASS_JWT_SECRET`
  (an empty HS256 key is public → forgeable founder tokens). Test: `test_redteam_hardening.py`.
- **`$regex` injection** — `/companies/by-owner/{wallet}` strict-validates the address
  + `re.escape` (no merchant enumeration / ReDoS). Test: same.
- **`brand_color` CSS beacon** — server-side hex coercion `_safe_brand_color` on create +
  profile update. Test: same.
- **NEW-3 oracle-floor** — `AutoSwapRouter.setRuleFeed` rejects `slippageBps >= BPS`
  (100% slippage silently zeroed the F3 floor). Test: `AutoSwapRouter.t.sol::test_SetRuleFeed_FullSlippage_Reverts`.

**Tracked (fix at the noted gate):**

| # | Sev | Boundary | Finding | Fix / gate |
|---|-----|----------|---------|-----------|
| **F30** | Low | v2 vault (not deployed) | `subscribeWithAuthorization` (L247-250) + `cancelWithAuthorization` (L313-317) make attacker-controllable ERC-1271 calls with **no `nonReentrant`**, and `cancelWithAuthorization` sets `active=false` **after** the external call (CEI inversion). Non-exploitable today (non-custodial, fixed terms), but contradicts v2's hardened branding. | Add `nonReentrant` to both entrypoints; move `active=false` before the signature check; add an invariant test. **Gate:** the v2 external-audit + deploy step (source change requires regenerating the reproducible `vault_build_4337.json` via `forge`, which the deploy pipeline runs). |
| **F30b** | Low | v2 vault (not deployed) | Keeper gas-griefing: the sponsored path pays gas for an attacker-controlled `isValidSignature`, which can burn to the block limit then return non-magic (revert; nonce not consumed → costless to attacker). | Cap gas forwarded to the ERC-1271 call, or restrict sponsorship to EOAs / vetted wallets; require relayer `eth_call` simulation. Same deploy gate as F30. |
| **F31** | Med | B8 API→1inch | `POST /api/fusion/{path}` (`oneinch.py:281`) has **no auth and no rate-limit** yet injects the platform `ONEINCH_API_KEY` — an open relay of a paid key (quota/billing abuse). Host is fixed (`api.1inch.dev`), so not arbitrary-host SSRF. | Gate behind `require_merchant` (+ rate-limit) like the `/swap/*` routes — needs a custom `@1inch/fusion-sdk` httpConnector that forwards the JWT, plus a frontend swap-flow test; not shipped blind to avoid breaking gasless swaps. |
| **F32** | Low-Med | B3/B4 | `deposits.tx_hash` is non-unique + the "already credited" check is a non-atomic read-then-write → two concurrent confirms can credit one `tx_hash` to two deposits. Bounded by the `subscriptions (company_id, plan_id, customer_key)` unique index (collapses to ≤1 extra renewal), but double-counts deposit records / founder telemetry. | Partial unique index on `tx_hash` where `status:"confirmed"`, or gate the confirm write behind an atomic `find_one_and_update`. Touches the money-confirm path → verified fix deferred to a dedicated change. |
| **F33** | Low | B3 | IP rate-limits (`ratelimit.py`) key on spoofable leftmost `X-Forwarded-For`; `create_deposit`/`receipt_pdf` limiters are bypassable by rotating XFF. Money-moving limits are wallet-keyed (unaffected). | Derive client IP from a trusted proxy hop (Render ingress) — env-specific. |
| **F34** | Low | B3 CORS | `allow_origin_regex=r"https://[a-z0-9-]+\.vercel\.app"` + `allow_credentials=True` trusts any `*.vercel.app`. Mitigated (Bearer token in JS memory; refresh cookie `httpOnly`+`SameSite=lax`), but wider than intended. | Explicit preview-domain allowlist. |
| **F35** | Low | B5 auth | SIWE `domain` mismatch is logged, not rejected (`auth.py`); EIP-4361 says reject. Low (nonce must still be server-issued + wallet-bound). | Reject on `domain` mismatch. |

Doc-only hardening notes also recorded in the threat model: the `deposit_guard.py`
docstring overstates the "connected wallet" proof (it's client-supplied, not
signature-proven — bind it to the on-chain `from` at confirmation), and
`FOUNDER_WALLETS` must be explicitly set in prod (never rely on the hardcoded
default).
