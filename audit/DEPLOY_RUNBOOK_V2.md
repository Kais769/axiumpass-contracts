# AxiumPass — v2 Vault + Fixed Router Go-Live Runbook

> **Precondition (the gate):** an external review has cleared (see
> `AUDIT_ENGAGEMENT_PACKAGE.md`). Do **not** run this before the audit. Everything
> below is turnkey once that one gate is passed. Each step is exact; the final
> product-facing switch is a **single flag**.
>
> **What runs `forge` here:** the deploy environment (CI runner or a laptop with
> Foundry). The agent sandbox can compile-verify with `tools/solc_verify.js` but
> cannot run `forge`/`anvil`, so the artifact-regen + deploy steps are for the
> forge-equipped operator.
>
> **Funding the gate:** the audit is likely **grant-funded** — see
> `SECURITY_FUNDING_STRATEGY.md` (Arbitrum $10M+ audit fund / OP Superchain audit
> grant / free Immunefi bounty). You can keep billing B2B on the live v1 while the
> v2 audit is arranged, so this runbook is never on your critical revenue path.

---

## Phase A — Testnet canary (FREE, do this before mainnet)

De-risk the whole procedure on a testnet first — it costs only test-ETH and
surfaces any deploy/config mistake with zero funds at stake:

1. Deploy the (F30-patched) v2 vault + fixed router to **Base Sepolia** (and/or
   Arbitrum/OP Sepolia) with `deploy_vault_4337.py --chain base-sepolia`.
2. Run a full end-to-end: create a subscription (signed auth + permit), a keeper
   charge, a cancel — against test stablecoins.
3. Point a **testnet Immunefi bounty** or invite reviewers at the testnet address
   (cheap real-world testing before mainnet).
4. Only once the canary + the external audit are both green → proceed to mainnet
   (Steps 1–4).

---

## Step 0 — Pre-deploy source fixes (audit-blessed)

Apply the fixes the internal audit flagged as pre-deploy (F30/F30b/F11/F12/F18).
The one that changes bytecode and is unambiguous is **F30** — already
**compile-verified** with `tools/solc_verify.js` (0 errors, 0 warnings):

**F30 — add `nonReentrant` to the two ERC-1271 signature entrypoints**
(`contracts/src/SubscriptionVault4337.sol`):

```diff
   function subscribeWithAuthorization(
       SubscriptionAuthorization calldata auth,
       bytes calldata signature
-  ) public whenNotPaused returns (uint256 id) {
+  ) public whenNotPaused nonReentrant returns (uint256 id) {

   function cancelWithAuthorization(
       CancelAuthorization calldata auth,
       bytes calldata signature
-  ) external {
+  ) external nonReentrant {
```

`cancelWithAuthorization` intentionally stays available while paused (M-2:
"cancellation stays open"), so it gets `nonReentrant` but **not** `whenNotPaused`.
`nonReentrant` fully closes the reentrancy window on the attacker-controlled
`isValidSignatureNow` (ERC-1271) call, which subsumes the CEI concern.

- **F30b** (keeper gas-griefing on the sponsored path) is an **off-chain** control:
  the keeper/relayer must `eth_call`-simulate a sponsored submission before
  broadcasting, and/or restrict sponsorship to EOAs / vetted smart accounts. No
  contract change.
- **F11/F12/F18** — review with the auditor; close as advised (nonce decoupling,
  permit-front-run note, `renounceOwnership` already disabled).

Then regenerate the reproducible artifact **with forge** (this is why forge is
required here — solc-js bytecode is not byte-identical):

```bash
cd contracts && forge build
# adopt the fresh build as the committed artifact the CI gate checks:
python3 - <<'PY'
import json
o = json.load(open('out/SubscriptionVault4337.sol/SubscriptionVault4337.json'))
json.dump({'abi':o['abi'],'bytecode':o['bytecode']['object']},
          open('../backend/vault_build_4337.json','w'), indent=2)
PY
forge test -vvv   # full suite incl. a new invariant test pinning F30
```

Add an invariant/regression test asserting a re-entrant ERC-1271 wallet cannot
double-act during subscribe/cancel (the CI `foundry` job verifies it).

---

## Step 1 — Governance: Safe multisig + 48 h timelock (F5/F18)

Deploy the ownership cascade **before** the vault, so the vault is owned by the
timelock from block one (`SECURITY_HARDENING.md` §1):

1. Create a **Safe** multisig (recommended **3-of-5**) at `safe.global` on each
   target chain (or one canonical owner via a cross-chain-safe pattern).
2. Deploy an OpenZeppelin **`TimelockController`** with `minDelay = 48h`,
   `proposers = [Safe]`, `executors = [Safe or address(0) for public execution]`.
3. The Safe is the timelock admin; renounce the deployer's timelock admin role.

Result: every privileged action = Safe-signed proposal → 48 h public wait →
public execution. No single hot key.

---

## Step 2 — Deploy the contracts (owner = timelock)

Per chain (Polygon/Base/Arbitrum/Optimism), using the existing pipeline:

```bash
# v2 vault — pass the timelock as the owner, the keeper as the keeper.
python backend/deploy_vault_4337.py --chain <chain> --owner <TIMELOCK> --keeper <KEEPER>
# fixed AutoSwapRouter (F1/F3/NEW-3 corrected) — only if/when auto-swap ships.
python backend/deploy_vault_l2.py --chain <chain> --contract AutoSwapRouter --owner <TIMELOCK>
```

Verify on the block explorer: `owner() == TIMELOCK`, `keeper()` correct,
`renounceOwnership` disabled, code matches the audited commit (reproducible build).

---

## Step 3 — Configure (via the timelock, so 48 h-delayed + public)

- v2 vault: **allowlist** the stablecoins (`setTokenAllowed(USDT/USDC/EURC, true)`)
  — M-1 enforces stablecoins-only on-chain.
- Fund the keeper with native gas on each chain.
- (Router, only when auto-swap ships) merchants set their own rules/feeds;
  `setRuleFeed` now rejects `slippage >= BPS` (NEW-3).

---

## Step 4 — The single product switch

Set the env + flip routing (backend + frontend already switch to the v2 enrolment
flow on this signal — verified in `/onchain/config` `vault_v2_enabled`):

```
SUBSCRIPTION_VAULT_4337_<CHAIN> = <deployed v2 address>
# enable v2 routing for NEW subscriptions (existing v1 subs keep running):
preferred_vault_version(<chain>) → "v2"
```

That's the whole go-live. Existing v1 subscriptions are untouched; new ones route
to v2. Roll back by clearing the flag (routing falls back to v1) — no fund
movement, fully reversible at the routing layer.

---

## Rollback / incident

- **Pause** (v2 `Pausable`): the Safe can pause enrolments/charges (cancellation
  stays open) via the timelock's emergency path if configured, or a shorter-delay
  guardian role if you add one.
- **De-allow a token** to halt its charges in an incident (M-1).
- **Routing flag off** → new subs go back to v1 instantly.

---

_Companion: `AUDIT_ENGAGEMENT_PACKAGE.md` (the gate), `INTERNAL_AUDIT_2026-07.md`
(F1–F35), `REALITY_LEDGER.md` (live vs. gated). F30 patch compile-verified via
`tools/solc_verify.js` on 2026-07-08._
