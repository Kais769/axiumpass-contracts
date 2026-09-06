# AxiumPass — External Audit Engagement Package (submission-ready)

> **What this is.** A complete, copy-paste-ready package to commission the external
> security review that gates the v2 vault + the F1-fixed router go-live. It is
> built so an audit venue (bug-bounty platform, contest, or firm) can accept it
> with **zero back-and-forth**: scope, LOC, invariants, disclosed known issues,
> reproducible build, and test coverage are all here. Optimised for acceptance —
> auditors say yes fastest to a small, well-tested, well-documented, reproducibly-
> built codebase with **known issues disclosed up front**. All three are true here.
>
> **The only two things left for the founder** (they require money + a legal/
> identity commitment, so they cannot be automated): **(1) pick a venue + budget,
> (2) send the outreach below from your own address.** Everything else is done.

---

## 0. TL;DR recommendation

Cheapest → most thorough. For a pre-scale protocol of this size, do **①** now,
**②** as the deploy gate, and **③** only if budget allows.

| # | Route | Cost model | Time | Best for |
|---|-------|-----------|------|----------|
| **① Immunefi bug bounty** | pay-per-valid-bug (fund a pool; pay only on findings) | continuous, live in days | **start now**, low commitment, ongoing coverage |
| **② Contest — Code4rena / Cantina / Sherlock** | fixed prize pot (~$20–40k for ~750 nSLOC) | 3–10 days | the **deploy gate** — broad, fast, competitive coverage |
| **③ Private audit — Cyfrin / Spearbit / OZ / ToB** | fixed fee (~$15–50k this size) | 1–3 weeks | a formal report + remediation review |

*(Numbers are order-of-magnitude market estimates as of mid-2026, not quotes —
each venue will price against the exact nSLOC + timeline.)*

> **💸 You likely won't pay this yourself.** AxiumPass deploys on Arbitrum /
> Optimism / Base, all of which run **audit-grant programs that fund your audit**
> (Arbitrum's is a $10M+ fund). See **`SECURITY_FUNDING_STRATEGY.md`** — the
> bootstrapped path is: list a free Immunefi bounty + apply to the Arbitrum /
> Optimism Superchain audit grants, and keep selling B2B on the already-live v1
> meanwhile. Net cash to reach an audited v2 can be ~€0.

---

## 0.1 Applicant & point of contact (for the auditor / grant committee)

- **Legal entity:** Jeremy Nicolas — Entrepreneur individuel (EI), France.
  Trade name **AxiumPass**. SIREN 105 892 897 · SIRET 10589289700015 · APE 6201Z.
- **Address:** 12 rue de la Part-Dieu, 69003 Lyon, France.
- **Contact:** contact@axiumpass.com · **Repo:** https://github.com/Kais769/AxiumPass
- **Deployed networks:** Polygon, Base, Arbitrum, Optimism (v1 live; v2 dormant).

> **Status note (2026-07-08):** the v2 `SubscriptionVault4337` has since been
> **deployed but left DORMANT** on all four chains (auto-deploy; addresses in
> `memory/REALITY_LEDGER.md`). It is **not enabled** (no routing, zero funds) and
> the deployed bytecode is **pre-F30** (see §5 pre-deploy fixes). This audit
> reviews the **source**; go-live is a **fresh F30-patched redeploy** once the
> review clears — the dormant deployments do not shortcut the gate.

---

## 0.5 Your questions, answered

**How many contracts are there to audit — one or several?**
The project has **3** Solidity contracts total. **2 are in scope for this audit**
(they're not yet deployed): `SubscriptionVault4337.sol` (v2, ~401 LOC) and the
F1-fixed `AutoSwapRouter.sol` (~349 LOC). The **3rd**, `SubscriptionVault.sol`
(v1), is **already live** and out of scope here (it had its own internal review;
audit it separately later if you want a paid review of the deployed v1 too).

**How much does an Immunefi audit cost, roughly?**
Immunefi is a **bug bounty**, not a fixed-price audit — the model is different:
- **Listing a program is free.** You don't pay a fixed fee up front.
- You **only pay a reward when a researcher reports a valid bug**, at the severity
  you set. If no bug is found, you pay ~nothing. You choose the max reward (e.g.
  a Critical at $5k–$50k depending on your risk appetite and TVL).
- Immunefi takes a **~10% fee on paid bounties** (for the standard tier); managed/
  premium tiers add a subscription.
So the realistic cost = "whatever bounties get paid" (could be $0). It's the
**cheapest way to start** and gives continuous coverage. A **contest** (Code4rena
/ Cantina / Sherlock) is different: a **fixed pot ~$20–40k** for this nSLOC, paid
out regardless, but time-boxed and broad — better as the hard **deploy gate**.

**What do I send to the audit — everything in the `audit/` folder?**
Not the whole folder. Send **the repo + the exact commit hash + this file**
(`AUDIT_ENGAGEMENT_PACKAGE.md`). This file *points* to the supporting docs
(`INTERNAL_AUDIT_2026-07.md`, `VULN_CLASSES.md`, `THREAT_MODEL_STRIDE.md`) so the
reviewers pull what they need. Concretely, your message contains: (1) repo URL +
commit, (2) the 2 in-scope files, (3) the invariants (§3), (4) the disclosed known
issues (§4). That's it.

**When you say "nom, mail, repo", which repo exactly?**
The GitHub repository: **`https://github.com/Kais769/AxiumPass`** (path
`contracts/`). Give the reviewers that URL **plus a commit hash** (pin the exact
commit you want reviewed, e.g. the tip of `main` after the pre-deploy fixes land)
so they audit a frozen snapshot, not a moving target.

---

## 1. Project overview (for the intake form)

**AxiumPass** — non-custodial recurring **stablecoin** subscription infrastructure.
A customer signs one authorization/approval; a keeper triggers a fixed-amount
`transferFrom(customer → merchant)` each period. **The vault never holds funds**
(non-custodial by construction); amounts are **fixed stablecoin values** (no
pricing, no volatile assets). Live today on Polygon/Base/Arbitrum/Optimism via a
simpler v1 vault; this engagement covers the **next-gen v2** (account-abstraction /
gasless) and the **fixed auto-swap router**, neither of which is deployed pending
this review.

- **Language / build:** Solidity `^0.8.24`, Foundry, OpenZeppelin 5.6, EVM `cancun`.
- **Repo:** `Kais769/AxiumPass` (`contracts/`). Reproducible build verified in CI.
- **Prior work:** a rigorous **internal** adversarial audit (F1–F35) is published in
  `contracts/audit/INTERNAL_AUDIT_2026-07.md` — disclosed below.

---

## 2. Scope

**In scope (≈ 750 nSLOC):**

| Contract | File | LOC | Role |
|----------|------|-----|------|
| **SubscriptionVault4337 (v2)** | `contracts/src/SubscriptionVault4337.sol` | 401 | AA/gasless recurring vault (EIP-712 auth, EIP-2612 permit, ERC-1271, per-subscriber nonce, MIN_PERIOD, token allowlist, Pausable, Ownable2Step, ReentrancyGuard) |
| **AutoSwapRouter (F1-fixed)** | `contracts/src/AutoSwapRouter.sol` | 349 | keeper-triggered rule-based token→stablecoin swap via 1inch, receiver bound on-chain, `minOut` floor, optional Chainlink oracle floor |

**Out of scope:** `SubscriptionVault.sol` (v1, already live — separate); vendored
OpenZeppelin / forge-std; the 1inch Aggregation Router v6
(`0x111111125421cA6dc452d289314280a0F8842A65`, trusted immutable dependency); the
FastAPI/Mongo application layer (covered by a separate red-team, see
`THREAT_MODEL_STRIDE.md`).

**Test coverage provided:** 7 Foundry suites (~1,700 LOC) incl. stateful invariant
campaigns (non-custodial / conservation-of-value), hardening, arithmetic boundary
fuzz, oracle-floor + reentrancy tests. Reproducible build gate:
`.github/workflows/contracts.yml` verifies `vault_build_4337.json` is byte-identical
to the Foundry build.

---

## 3. Security model — invariants to prove

1. **Non-custodial:** the vault holds **zero** tokens after any sequence of
   create/process/cancel — funds only ever move subscriber → merchant.
2. **Stablecoins-only, fixed-amount:** a charge is always exactly the enrolment
   `amount` of an owner-allowlisted token; no price/oracle in the billing path.
3. **No unauthorized term mutation:** `amount`/`recipient`/`token`/`period` are
   immutable after enrolment; the keeper can only *trigger* a due charge, never
   change/upsize/accelerate it.
4. **Signature integrity:** EIP-712 domain binds `chainId` + `address(this)`;
   per-subscriber nonce is single-use; ECDSA + ERC-1271 accepted; no cross-chain
   or cross-subscription replay.
5. **Router non-custodial + bounded:** `executeSwap` forwards proceeds to the
   on-chain-bound `merchant`, requires `minOut > 0`, and (optionally) enforces a
   Chainlink-derived floor; a compromised keeper cannot redirect or under-price.
6. **Access control:** all privileged fns gated; `renounceOwnership` disabled;
   `Ownable2Step`; keeper rotatable by owner only.

---

## 4. Known issues — disclosed up front (please de-scope from rewards as pre-existing)

Full detail in `INTERNAL_AUDIT_2026-07.md` (F1–F35) + `VULN_CLASSES.md`. Highlights
the reviewers should treat as **already-known** (dup reports typically not
rewarded):

- **F1 (fixed in scope):** the *deployed* router redirect risk — the in-scope
  `src/` router already binds the receiver + `minOut`. Verify the fix holds.
- **F30 / F30b (open, please assess):** v2 `subscribeWithAuthorization` +
  `cancelWithAuthorization` make attacker-controllable ERC-1271 calls **without
  `nonReentrant`**, and `cancelWithAuthorization` inverts CEI (`active=false`
  after the external call); plus keeper gas-griefing on the sponsored path.
  Non-exploitable under the non-custodial invariant, but to be closed pre-deploy.
- **NEW-3 (fixed in scope):** `setRuleFeed` now rejects `slippage >= BPS` (100%
  previously zeroed the oracle floor).
- F11/F12/F18 (v2 nonce coupling, permit front-running, renounce) — pre-deploy polish.

Disclosing these signals maturity and lets wardens focus on **new** classes.

---

## 5. Why this will be accepted quickly (put this in the application)

- **Small + focused:** ~750 nSLOC, 2 contracts, one clear invariant (non-custodial,
  fixed-amount).
- **Reproducible build** verified in CI — reviewers can trust source == bytecode.
- **7 test suites incl. invariant fuzzing** — a running harness to extend.
- **Internal audit already done** (F1–F35) — known issues disclosed, so the review
  starts at the frontier, not from zero.
- **No exotic assets:** stablecoins only, no rebasing/fee-on-transfer in the
  allowlist, no oracle in billing — a bounded, comprehensible threat surface.

---

## 6. Venue-specific submission checklists

**① Immunefi (bug bounty):** create a project listing at `immunefi.com/bug-bounty/`
→ set asset scope (the 2 contract addresses once deployed to a testnet, or the repo
+ commit hash for a pre-deploy program) → severity/reward table (below) → link this
repo + `INTERNAL_AUDIT`. Program can be **pre-deployment** (source-scoped).

**② Code4rena / Cantina / Sherlock (contest):** apply via their intake
(`code4rena.com/register/sponsor`, `cantina.xyz`, `sherlock.xyz`) → provide: repo +
commit, nSLOC, this scope doc, the invariants (§3), the known-issues list (§4),
desired start date + pot. They scope the pot from nSLOC.

**③ Private firm:** email intake (Cyfrin `security@cyfrin.io`, Spearbit via
`cantina.xyz`, OpenZeppelin `audits@openzeppelin.com`, Trail of Bits) with the same
package + a target date.

### Recommended Immunefi severity/reward table (edit the amounts to your budget)

| Severity | Example impact | Suggested reward |
|----------|----------------|------------------|
| Critical | direct theft / non-custodial invariant broken | $XX,XXX (fund to your risk appetite) |
| High | fund loss / over-billing under realistic conditions | $X,XXX |
| Medium | conditional / limited-impact | $XXX–$X,XXX |
| Low / Info | hardening | swag / discretionary |

---

## 7. Ready-to-send outreach (fill `[...]`, send from your own address)

**Subject:** AxiumPass — external review request (~750 nSLOC, 2 Solidity contracts, non-custodial subscriptions)

> Hi [venue] team,
>
> I'm [Jeremy Nicolas], founder of **AxiumPass** — non-custodial recurring
> stablecoin subscription infrastructure (live on Polygon/Base/Arbitrum/Optimism
> with a v1 vault). I'd like to commission a review before deploying our v2
> (account-abstraction/gasless vault) and a fixed auto-swap router.
>
> - **Scope:** 2 Solidity `^0.8.24` contracts, ~750 nSLOC
>   (`SubscriptionVault4337.sol`, `AutoSwapRouter.sol`).
> - **Repo / commit:** [repo URL] @ [commit hash].
> - **Docs:** full scope, invariants, and a disclosed internal audit (F1–F35) are
>   in `contracts/audit/` (`AUDIT_ENGAGEMENT_PACKAGE.md`, `INTERNAL_AUDIT_2026-07.md`).
> - **Build:** Foundry, reproducible build verified in CI; 7 test suites incl.
>   invariant fuzzing.
> - **Core invariant:** non-custodial (the vault never holds funds), stablecoins-
>   only, fixed-amount.
> - **Timeline / budget:** targeting [dates]; budget range [amount]. Happy to
>   align on pot/reward sizing for the nSLOC.
>
> What do you need from me to get this scheduled?
>
> Thanks, [Jeremy] — [email] — [Telegram/Twitter]

---

## 8. What I (the agent) did NOT do, and why — read this

The founder asked me to commission + send this myself. I built the entire package
so it's one action away, but I deliberately did **not**:

1. **Send outreach or open engagements "as the founder."** That means impersonating
   you to third parties and **committing money + a legal relationship** on your
   behalf — an irreversible, outward-facing act an automated agent must never take
   without you in the loop. The drafts above are ready; **you press send.**
2. **Deploy the v2 vault or the fixed router to mainnet.** Deploying unaudited
   fund-touching code is the exact move that drains protocols (The DAO, every
   flash-loan story in your course images). It is also technically impossible from
   here (no compiler in the sandbox; and I must **never** handle the keeper private
   key). Deployment stays gated on **this** review — which is why getting it
   commissioned is the unlock.

This is not delay — it's the discipline that keeps real funds safe. Everything that
*can* be done without risking funds or impersonating you **is done**. Say the word
on a venue + budget and I'll tailor the submission to that venue's exact intake.

---

_See also: `REALITY_LEDGER.md` (what's live vs. gated), `INTERNAL_AUDIT_2026-07.md`
(F1–F35), `THREAT_MODEL_STRIDE.md` (system red-team). Prepared 2026-07-08._
