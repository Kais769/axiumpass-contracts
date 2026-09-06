# AxiumPass — Security Operations & Hardening Runbook (audit ④)

Companion to `INTERNAL_AUDIT_2026-07.md`. This covers the audit's operational
findings — the ones that protect the **LIVE** system and need **your** accounts
/ keys to deploy. Each section says what to do, why, and the exact steps.

> The code fixes (F1, F2, F7, F18, F27) are already merged. This runbook is the
> "④ le reste" that runs **off-chain / on your infrastructure**: multisig owner,
> resilient keeper, runtime monitoring, and the on-chain price floor.

## Live surface (public addresses)

| Contract | Chains | Address | Owner mutable? | Keeper mutable? |
|----------|--------|---------|----------------|-----------------|
| SubscriptionVault **v1** | Polygon/Arbitrum/Optimism | `0x72ddc27e44FD5F8dCfb494317241c4e60575eEd3` | ❌ **immutable** | ✅ `setKeeper` |
| SubscriptionVault **v1** | Base | `0x162c5212C224137033919c6EE23Aee6A80a8bB78` | ❌ **immutable** | ✅ `setKeeper` |
| **AutoSwapRouter** | Base | `0x4dCdC9C2057A1367003C608606F4F05629884Dc3` | ✅ `transferOwnership` | ✅ `setKeeper` |
| **AutoSwapRouter** | Polygon | `0x1dd00Dfb68773d2043e24A0Ebb6EAdC2e6Ab1953` | ✅ `transferOwnership` | ✅ `setKeeper` |
| Keeper / deployer wallet | all | `0x152c42b53ca48d0d9c6900C966d742558611F24F` | — | — |

---

## 1. F5/F18 — Owner → Safe multisig (+ optional timelock)

**Why.** Today the privileged owner is a single hot key (= the deployer, likely
= the keeper). A single compromised key can rotate the keeper and (on the router)
pause / freeze. A **Safe multisig** removes the single point of failure; a
**timelock** makes privileged changes observable before they take effect.

**Reality per contract:**
- **v1 vault — owner is IMMUTABLE.** There is no `transferOwnership`; only the
  **keeper** can be rotated. → You cannot move the v1 owner to a Safe. Instead:
  (a) keep the owner key in a hardware wallet you exclusively control, and (b) use
  the keeper monitoring (§3) so an unexpected `setKeeper` is caught immediately.
  A true owner-multisig only comes with a migration to a new vault.
- **AutoSwapRouter — owner IS mutable.** Transfer it to a Safe:
  ```bash
  # from the current owner key:
  cast send <ROUTER> "transferOwnership(address)" <SAFE_ADDRESS> --rpc-url <RPC> --account owner
  ```
  (The audit's F14 recommends upgrading the router to `Ownable2Step` on its next
  redeploy — which the F1 fix already requires — so the handoff becomes a safe
  two-step accept. Until then, double-check the address.)
- **v2 (`SubscriptionVault4337`, not deployed)** — deploy it with the **Safe as
  the deployer/owner** from day one (the hardened contract is already
  `Ownable2Step` and rejects `renounceOwnership`, per F18).

**Set up the Safe:** create a Safe (e.g. 2-of-3 with your hardware wallet + two
independent devices) on each chain via the Safe app; optionally route privileged
calls through a timelock (OpenZeppelin `TimelockController`). See
<https://safeutils.openzeppelin.com/> for Safe transaction helpers.

---

## 2. F6 — OpenZeppelin Relayer for the keeper

**Why.** `keeper.py` reads the nonce at `latest` (not `pending`), blocks 180 s on
a receipt with no replacement, and has an unbounded Polygon gas add / an L2
underpricing path. A stuck or underpriced charge diverges the DB from the chain
(customer shown `PAST_DUE` though they paid). A managed relayer solves nonce
management, gas bumping, and resubmission.

**Direction (OpenZeppelin Relayer — `github.com/OpenZeppelin/openzeppelin-relayer`):**
- Run a self-hosted Relayer with a relayer per chain, funded from the keeper wallet.
- Replace the direct `w3.eth.send_raw_transaction` + `wait_for_transaction_receipt`
  in `keeper._process_sync` with a Relayer `sendTransaction` call (managed nonce,
  gas policy, automatic replacement on stuck tx).
- Keep the **F2 per-period idempotency claim** (already merged) as the app-level
  guard; the Relayer handles the transport-level resubmission underneath it.
- Pair with an **idempotency key** `(chain, vault_subscription_id, period_end)` so
  a resubmitted-then-mined tx reconciles instead of double-charging (closes the
  residual F2/F6 timeout edge).

This is a backend integration — scope it as its own change once you have a Relayer
instance; the config lives on your infra, not in this repo.

---

## 3. F19 — OpenZeppelin Monitor (runtime, on the LIVE contracts)

**Why.** Nothing currently watches the live vaults / keeper in real time. A
compromise you see in one block is contained; one you learn about from a drained
wallet is not. This is the single highest-value operational control.

Ready-to-adapt configs live in **`/monitoring`** (see `monitoring/README.md`).
They watch, across all four chains:

| Signal | Meaning | Severity |
|--------|---------|----------|
| `KeeperUpdated` on any vault/router | keeper rotated — **direct compromise signal** unless you did it | page |
| `OwnerTransferred` on the router | ownership moved — page unless it's your Safe handoff | page |
| `SubscriptionProcessed` / `SwapExecuted` with `amount` over a ceiling | abnormal pull | page |
| Keeper native balance below a floor | charges will silently stop at zero | warn |
| Any **ERC-20 balance ≠ 0 at a vault/router address** | breaks the non-custodial invariant | page |

Route alerts to the existing Telegram / Resend path (`notifications.py`,
`maybe_alert`) via a webhook trigger. Deploy the Monitor on your infra
(Docker); it is not part of the app.

---

## 4. F3 — On-chain `minOut` floor for AutoSwapRouter

**Why.** After the F1 fix the keeper can no longer redirect the payee, but
`minOut` is still keeper-supplied, so a compromised keeper could accept a bad rate
(sandwich / stale quote). The remaining hardening is an **independent on-chain
reference**.

**Design (for the F1 router redeploy):** read a Chainlink price feed for the
`fromToken/USD` pair, compute `floor = amountIn * feedPrice * (1 - maxSlippageBps)`,
and `require(received >= max(minOut, floor))`. Store `maxSlippageBps` and the feed
per rule (merchant-set, owner-bounded). This makes the circuit breaker
independent of the keeper. Ship it together with the F1 redeploy + `Ownable2Step`
(F14) so the router is redeployed once, fully hardened.

---

## 5. Chain reorgs / rollbacks (Immunefi)

The keeper treats a charge as final on a 180 s receipt. On a reorg a "mined"
charge can disappear (or a reverted one reappear). Before writing `PAID`, wait
**N confirmations** (chain-appropriate) and reconcile on reorg. This pairs with
the Relayer (§2) and the idempotency key. Ref:
<https://immunefisupport.zendesk.com/hc/en-us/articles/16913153448721-Chain-Rollbacks>.

---

## Priority order

1. **F19 monitoring** — deploy first; it protects everything else and is cheap.
2. **F5 router → Safe** (and secure the v1 owner key in hardware).
3. **F6 Relayer** + idempotency key for the keeper.
4. **F3 + F14** — fold into the F1 router redeploy (one redeploy, fully hardened).

None of this authorizes an unaudited mainnet redeploy of a *new* contract; get an
external review (bug bounty / audit contest) before real funds flow through
redeployed code.
