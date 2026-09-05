# AxiumPass — Security-Audit Funding Strategy (for a bootstrapped founder)

> **The worry:** "I can't afford a $20–40k audit." **The answer:** you almost
> certainly **won't pay that out of pocket** — and, crucially, **you can serve B2B
> customers *today* without it.** This doc lays out the cheapest safe path, with
> the exact programs to apply to. Reasoned as a strategic Web3/DeFi B2B founder-
> engineer would: minimise cash out, maximise trust signal, don't block revenue.

---

## Reframe #1 — the audit does NOT block your B2B revenue

Your **v1 vault is LIVE, audited-internally, and non-custodial**. It already does
the whole job: recurring stablecoin subscriptions on Polygon/Base/Arbitrum/
Optimism. **You can onboard and bill B2B customers right now on v1.** The external
audit only gates the **v2 upgrade** (gasless/account-abstraction UX) and the
auto-swap router — *enhancements*, not the core product.

**Strategic consequence:** sell B2B on v1 now; fund the v2 audit in parallel via
the grants below. The money problem and the go-to-market are decoupled. Don't let
"v2 needs an audit" stall "v1 can take paying customers."

---

## Reframe #2 — your codebase is *cheap* to audit

Audit price is driven by **complexity, not vibes**. Market rates (2026): simple
contracts **$5–15k**, standard DeFi $20–60k, cross-chain/ZK $80k+. AxiumPass v2 +
router is **~750 nSLOC, non-custodial, stablecoins-only, no ZK, no cross-chain
messaging, reproducible build, internal audit already done, 7 test suites.** That
puts you at the **low end (~$5–15k for a focused review)** — and the grants below
can cover it. Competitive platforms (CodeHawks, Cantina) are cheaper entry points
than a boutique private audit.

---

## The funding ladder (cheapest → most, do them in order)

### ① FREE now — Immunefi bug bounty (continuous coverage, pay-per-bug)
- **Cost:** free to list. You **only pay if a valid bug is found**, at a reward
  **you set** (start modest, e.g. a $2–5k critical while pre-revenue; raise it as
  TVL grows). No staking. Immunefi replies to new projects within ~5 business days.
- **Why now:** it's the cheapest real security signal and it's continuous. List
  the repo (pre-deployment source program is allowed).
- **Apply:** <https://immunefi.com/bug-bounty-program/> → "Launch your bounty".

### ② FREE to you — ecosystem AUDIT GRANTS (the big unlock; you're eligible on all four chains)
These programs **pay for your audit**. You build ON their chains → you are exactly
who they fund.

- **Arbitrum Audit Program** — a **$10M+ (ARB) fund that subsidises third-party
  audits** for early-stage Arbitrum projects with product-market fit. You submit
  protocol details + GitHub + scope + timeline + preferred auditor; the Arbitrum
  Audit Committee matches you to a **pre-approved** auditor and covers cost.
  → <https://arbitrum.foundation/grants> · program thread:
  <https://forum.arbitrum.foundation/t/arbitrum-audit-program/28368> · how-to:
  <https://www.nethermind.io/blog/how-to-apply-for-the-arbitrum-audit-fund-and-pick-the-right-partner>
- **Optimism Superchain Audit Grants** — **covers the cost of audits for apps
  across the Superchain (Base + Optimism)**, for new apps with contracts deployed
  and preparing to launch. Grants Council replies ~1 week; open-source + willing to
  co-fund a small part helps.
  → <https://atlas.optimism.io/missions/audit-grants>
- **Base Builder Grants** — retroactive 1–5 ETH grants + weekly builder rewards for
  building on Base (fund tooling/security). → <https://base.org> (Builder Grants)
- **Polygon Community Grants** — grants for DeFi/infra on Polygon.
  → <https://polygon.technology/grants>

**Play:** apply to **Arbitrum Audit Program first** (biggest, purpose-built for
exactly this), and **Optimism Superchain Audit Grant** in parallel (you're on
Base+OP). One approval = your audit paid.

### ③ Low-cost paid — competitive review or a solo auditor (if grants are slow)
- **Cyfrin CodeHawks** (competitive, Cyfrin-powered; smaller/affordable pools) →
  <https://www.cyfrin.io/codehawks> · contact <https://www.cyfrin.io/contact>
- **Cantina / Spearbit** (elite independent researchers, flexible spot reviews,
  fast, no queue) → <https://cantina.xyz>
- **Sherlock** (contest + coverage) → <https://www.sherlock.xyz>
- **A single independent auditor** for ~750 nSLOC is often **$2–8k** — far below a
  contest pot. Find them via Cantina's researcher network or Code4rena "Zenith".

---

## The sequence I recommend (no cash up front to start)

1. **This week:** list the **Immunefi** bug bounty (free) + apply to the
   **Arbitrum Audit Program** and **Optimism Superchain Audit Grant** (both can
   pay the audit). Keep selling B2B on **v1**.
2. **On grant approval:** get matched with a pre-approved auditor (grant-funded);
   they review the v2 vault + fixed router (`AUDIT_ENGAGEMENT_PACKAGE.md` is your
   ready application).
3. **Post-audit:** follow `DEPLOY_RUNBOOK_V2.md` — flip the single flag.

**Net cash from you to reach an audited v2:** potentially **~€0** (grant-funded) +
whatever bug bounty you choose to pay only if a whitehat finds something. That is
the bootstrapped path.

---

## What to send (same for grants and audit intake)

The repo + a pinned commit + `AUDIT_ENGAGEMENT_PACKAGE.md`. Grants also ask for:
product description (non-custodial recurring stablecoin subscriptions, live on 4
chains), traction/PMF (merchants + payments — your Command Center metrics), and
why you're aligned with their chain (you deploy the vault natively on it).

---

_Companion: `AUDIT_ENGAGEMENT_PACKAGE.md` (the application), `DEPLOY_RUNBOOK_V2.md`
(post-audit go-live), `REALITY_LEDGER.md` (what's live vs. gated). Links verified
2026-07-08; program terms change — confirm on each site._
