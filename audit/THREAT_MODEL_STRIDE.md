# AxiumPass — System Threat Model (STRIDE)

> **What this is.** A *system-wide* threat model — contracts **and** the FastAPI
> backend, the React frontend, the keeper, and the third-party edges — organised
> with the **STRIDE** framework. It complements the contract-focused
> [`VULN_CLASSES.md`](./VULN_CLASSES.md) and the operational
> [`SECURITY_HARDENING.md`](./SECURITY_HARDENING.md): STRIDE walks every **data
> flow and trust boundary** and asks the six systematic threat questions, so
> coverage is exhaustive by construction rather than by intuition.
>
> Produced by an internal adversarial red-team pass (parallel offensive-security
> agents over contracts / backend / frontend) followed by hands-on verification
> of every consequential claim against the source. Not a substitute for an
> external audit; the mainnet gate for new code is unchanged.

## STRIDE in one table

| Letter | Threat | Violates | The question to ask each flow |
|--------|--------|----------|-------------------------------|
| **S** | **Spoofing** (identity falsification) | Authentication | Can someone pretend to be another user/role/contract? |
| **T** | **Tampering** (data alteration) | Integrity | Can someone modify data/params/state they shouldn't? |
| **R** | **Repudiation** (denial of action) | Non-repudiation | Can an actor deny doing something, with no provable record? |
| **I** | **Information Disclosure** | Confidentiality | Can someone read data they shouldn't (secrets, other tenants, intent/MEV)? |
| **D** | **Denial of Service** | Availability | Can someone block/brick the service or a user? |
| **E** | **Elevation of Privilege** | Authorization | Can someone gain rights beyond their role? |

STRIDE analyses each data flow and trust boundary to surface these six
systematic threat categories.

## AxiumPass trust boundaries (the flows STRIDE walks)

```
  [Customer wallet] ──approve/pay──► (B1) SubscriptionVault ──transferFrom──► [Merchant wallet]
        │                                     ▲
        │                              (B2) Keeper (hot key) ── processSubscription
  [Browser / dApp] ──HTTPS──► (B3) FastAPI /api ──► (B4) MongoDB
        │                          │  │  │  │  │
     (B5) SIWE+JWT auth            │  │  │  │  └─► (B9) Stripe / Transak / KYB providers
                                   │  │  │  └────► (B8) 1inch / Alchemy RPC
                                   │  │  └───────► (B7) AutoSwapRouter ──► 1inch, Chainlink feed
                                   │  └──────────► (B6) Receipt HMAC links (customer, no JWT)
                                   └─────────────► Founder Command Center (founder JWT)
```

- **B1 Customer→Vault→Merchant** — the on-chain pull payment (non-custodial).
- **B2 Keeper→Vault** — the automation authority (hot key).
- **B3 Browser→API** — the whole HTTP attack surface.
- **B4 API→MongoDB** — persistence / injection surface.
- **B5 Auth** — SIWE proof-of-wallet → server-signed JWT → role gates.
- **B6 Receipt links** — detached HMAC tokens for customer PDF access.
- **B7 Router→1inch/Chainlink** — the only price-dependent path.
- **B8 API→Alchemy/1inch** — outbound RPC / SSRF surface.
- **B9 API→Stripe/Transak/KYB** — third-party money/identity edges.

---

## Trust zones — "green code trusts no one"

The threat model is organised by **trust zones**, crossing from hostile to
controlled:

```
  ZONE UNTRUSTED  ──►│──►  FRONTIER      ──►│──►  ZONE TRUSTED     ──►│──►  EXTERNAL
  Users / Frontend    │    Entry points      │    Core contract /      │    Oracles /
                      │    + validation       │    business logic       │    protocols
```

**Every boundary crossing demands strict validation. The trusted core (green)
trusts *no one*** — not the user, not the frontend, not even an external oracle
or protocol. The frontier is where validation lives; anything that reaches the
core has already been proven well-formed. This is exactly why AxiumPass:
re-checks every SIWE/JWT claim server-side (B5), binds on-chain deposits to
amount+recipient+sender (B1/B3), fixes subscription terms at enrolment so the
keeper can't tamper (B2), and reads only a manipulation-resistant Chainlink feed
at the one external price boundary (B7, `VULN_CLASSES.md` §7).

## Actor threat map (who attacks what)

| Actor | Vectors | AxiumPass boundary / control |
|-------|---------|------------------------------|
| **User** | phishing, key theft | B1/B5 — non-custodial (keys never leave the user), anti-blind-sign confirmation before wallet approval, SIWE proves wallet ownership |
| **Contract** | reentrancy, overflow | B1 — `VULN_CLASSES.md` §1 (arithmetic, checked + boundary tests) & §3 (reentrancy: v2/router `nonReentrant`, v1 = F8 latent) |
| **Oracle** | manipulation, flash loans | B7 — Chainlink (not DEX-spot) + `minOut` + staleness + a strictly-positive floor (NEW-3 fix) |
| **Admin** | key compromise, misuse | B2 — keeper can only trigger fixed-term charges; owner key = F5/F18, endgame = multisig+timelock (`SECURITY_HARDENING.md`) |

> **Critical vector:** a contract that *trusts external data* turns every actor
> into a possible point of compromise — which is why the core validates at every
> frontier and treats oracles/1inch as untrusted (bounded by `minOut` + floor).

## Attack-tree method (root goal → sub-goals)

An **attack tree** decomposes a root goal into the sub-goals an attacker must
each achieve — the canonical example is **The DAO**: *steal funds* → *exploit
reentrancy* → *external call before balance update* + *recursive fallback* →
`call.value` re-entered while *balance not yet zeroed* → **3.6M ETH drained**.
The defence is to break **any one** node: AxiumPass breaks the DAO chain at the
root — it is **non-custodial** (no pooled ETH/tokens to drain), uses **checked
arithmetic**, guards v2/router with `nonReentrant`, and never sends native ETH
(`VULN_CLASSES.md` §5). The one residual DAO-shaped node — v1's "external call
before state update" (F8) — is inert only because the tokens are callback-free
stablecoins (see §3 there), which is why it stays an operational control.

---

## STRIDE × boundary — findings & posture

Result of the red-team round (2026-07-08). Ranked by residual risk. Verdicts:
**FIXED** (this change), **TRACKED** (recorded as a finding in
`INTERNAL_AUDIT_2026-07.md`, actioned at its gate), **DEFENDED** (attack
considered, existing control blocks it).

| # | STRIDE | Boundary | Attack considered | Verdict & evidence |
|---|--------|----------|-------------------|--------------------|
| 1 | **S/E** | B5 auth | Empty `AXIUMPASS_JWT_SECRET` ⇒ public HS256 key ⇒ forge a `founder` token | **FIXED** — startup fail-fast (`auth.py` after L37) + test `test_jwt_secret_fail_fast_on_empty` |
| 2 | **I/D** | B8 API→1inch | Unauth `POST /api/fusion/*` rides the paid 1inch key (quota/billing abuse) | **TRACKED F31** — gate behind `require_merchant` via a custom FusionSDK connector + rate-limit (needs frontend test; not shipped blind) |
| 3 | **I/D** | B3 API | Mongo `$regex` injection on `/companies/by-owner/{wallet}` → enumerate hidden merchants / ReDoS | **FIXED** — strict `^0x[0-9a-f]{40}$` + `re.escape` (`server.py`) + test `test_companies_by_owner_rejects_regex_injection` |
| 4 | **T** | B3/B4 | Concurrent confirms: one `tx_hash` credits two deposits (non-atomic check) | **TRACKED F32** — bounded by the subscriptions unique index; fix = partial-unique index / atomic `find_one_and_update` (touches the money path — verified fix deferred) |
| 5 | **T/I** | B3→browser | Unvalidated `brand_color` → CSS `url()` beacon on a customer's browser | **FIXED** — server-side hex coercion `_safe_brand_color` (`server.py`) + tests |
| 6 | **D** | B3 | IP rate-limits keyed on spoofable `X-Forwarded-For` | **TRACKED F33** — money-moving limits are wallet-keyed (safe); IP-keyed deposit/receipt limits need a trusted-proxy hop (env-specific) |
| 7 | **E/D** | B7 router | `setRuleFeed(slippage == BPS)` silently zeroes the F3 oracle floor | **FIXED** — reject `>= BPS` (`AutoSwapRouter.sol`) + test `test_SetRuleFeed_FullSlippage_Reverts` |
| 8 | **D/E** | B1 v2 vault | v2 `subscribe/cancelWithAuthorization` make attacker-controlled ERC-1271 calls with no `nonReentrant`; `cancel` inverts CEI | **TRACKED F30** — pre-deployment (v2 not deployed; reproducible-build gate = fix at the forge/deploy step); non-exploitable today (non-custodial) |
| 9 | **D** | B1 v2 vault | Keeper gas-griefing via unbounded ERC-1271 on the sponsored path | **TRACKED F30b** — cap forwarded gas / EOA-only sponsorship + relayer simulation |
| 10 | **S** | B3 CORS | `allow_origin_regex` trusts any `*.vercel.app` with credentials | **TRACKED F34** — mitigated (Bearer-in-memory + `httpOnly`/`SameSite=lax` refresh); tighten to an explicit preview allowlist |
| 11 | **S** | B5 auth | SIWE `domain` mismatch logged, not rejected | **TRACKED F35** — low (nonce still must be server-issued + wallet-bound); reject on mismatch per EIP-4361 |

**DEFENDED (verified strong, no change needed):** founder/merchant gating is
strict JWT (legacy `X-Owner-Wallet`/`X-Founder-Wallet` are dead code, not
reachable); per-company authz via `_assert_access` (no cross-tenant IDOR;
viewer/admin/owner boundaries hold); receipt HMAC is timing-safe + per-deposit
(no forge/IDOR); on-chain verifier binds amount+recipient+token+confs; the
`is_demo` simulation is hard-gated (no real deposit can be mock-confirmed);
Transak/payment webhooks verify signatures with pinned algorithms; SIWE nonces
are atomically consumed (replay-safe). Frontend: no `dangerouslySetInnerHTML`/
`eval`/`innerHTML` anywhere; onboarding query-params are allowlist-validated; the
wallet `approve` spender is always the trusted vault (never merchant input) with
an anti-blind-sign confirmation; tokens are in-memory/`httpOnly`, not
`localStorage`; no secret leaks in the bundle. Contracts: no post-enrolment term
mutation; every state change emits an event; all privileged fns modifier-gated;
`renounceOwnership` disabled on v2/router; ids never reused; F1 receiver-binding
fix holds.

---

## Blockchain immutability (why the ledger itself isn't the weak link)

**Transaction lifecycle:** user *sends a transaction* → the *network validates it
by consensus* → the *EVM executes the code* deterministically → the result is
written to *permanent state*. Once executed, the result is **immutable and
replicated on every node**. Each block carries the hash of its predecessor — a
cryptographic chain — so tampering with any past record would require re-mining/
re-staking every block after it on a majority of nodes.

**Consensus (why that replication is trustworthy):**

| Criterion | Proof of Work | Proof of Stake |
|-----------|---------------|----------------|
| Mechanism | solve math puzzles (mining) | stake (deposit) crypto |
| Energy | very high | ~99.9% lower |
| Attacker cost | expensive hardware/energy | **loses the staked funds if dishonest** |
| Validation | first miner to solve | stake-weighted random selection |

AxiumPass settles on **PoS** L2s/sidechains (Polygon, Base, Arbitrum, Optimism),
where a dishonest validator is slashed — the settlement layer is tamper-evident
**and** economically defended by construction.

**Consequence for the threat model:** the on-chain record is the *strong* part.
AxiumPass's residual risk lives entirely at the **boundaries into and out of it**
(the B1–B9 rows above) — the user/frontend inputs, the API, the keeper key, the
oracle/1inch edges — not in the chain itself. That is exactly why this document
concentrates on boundary crossings, and why the design keeps the trusted on-chain
core minimal (fixed-term, non-custodial) so the least code possible depends on
anything outside the chain.

---

## Appendix — method

Red-team scope: three parallel adversarial agents (backend API/auth, smart
contracts via STRIDE, frontend/web), each instructed to report only
reachability-verified findings with `file:line` + a concrete exploit, then a
lead verification pass re-checking every consequential claim against source
before it is recorded here. Solid surfaces are recorded as explicitly as
findings, so "no issue" is a checked result, not a gap in coverage.
