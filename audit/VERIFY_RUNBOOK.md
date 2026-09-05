# AxiumPass — Verify the live v1 vault source on block explorers

**Goal:** turn every deployed vault from `is_verified:false` → **verified** on the
public explorers, so a grant/audit reviewer reads the exact deployed source in one
click. This is the single free "serious engineer" signal flagged in
`memory/GRANT_APPLICATIONS.md`.

## What runs, and how autonomous it is

The `.github/workflows/verify-contracts.yml` workflow runs `forge verify-contract`
for you (the agent sandbox can't run `forge` or reach explorer APIs; CI can). Two
tiers:

| Tier | Needs a key? | What it covers | Founder action |
| --- | --- | --- | --- |
| **Sourcify** | **No** | Sourcify + Sourcify-consuming explorers (e.g. **Blockscout**, which is where we measured `is_verified:false`) | **None.** Auto-runs on merge to `main`. |
| **Etherscan V2** | One free key | Polygonscan / Basescan / Arbiscan / Optimistic Etherscan (single Etherscan V2 endpoint) | One-time: add a repo secret. |

So the **Sourcify verification is fully hands-off** — it fires automatically the
moment this lands on `main`, and again any time the vault source changes. You can
also trigger it manually: GitHub → Actions → **verify-contracts** → *Run workflow*.

## The Etherscan-family explorers — exactly two 90-second human steps

These two steps are the *only* thing no automation can do for you: creating an
API key is an identity action on your account, and placing a secret is a
credential action — an agent must never do either (that is the same discipline
that keeps AxiumPass non-custodial). Everything downstream is automated for you.

1. **Create the free key** (one Etherscan V2 key covers all chains):
   <https://etherscan.io/apidashboard> → *Add* → copy the key.
   (Sign in / free sign-up at <https://etherscan.io/register> if needed.)
2. **Store it as a repo secret** — open the new-secret form directly:
   `https://github.com/Kais769/AxiumPass/settings/secrets/actions/new`
   → **Name** = `ETHERSCAN_API_KEY`, **Secret** = paste the key → *Add secret*.

**There is no step 3.** A daily scheduled run (`schedule` in the workflow) picks
up the secret automatically and verifies the Etherscan-family explorers the next
morning — hands-off. Want it instantly instead of waiting for the daily run?
Optionally click *Run workflow* here:
`https://github.com/Kais769/AxiumPass/actions/workflows/verify-contracts.yml`.

> **Never paste the key into a chat, a file, or a commit** — only into the GitHub
> secret box above. The workflow reads it from the encrypted secret and never
> prints it. If a key ever leaks, rotate it at the Etherscan dashboard.

**Note:** this is purely additive. Blockscout is already verified via Sourcify
(automatic, no key), which by itself satisfies "a reviewer reads the exact
deployed source in one click." The Etherscan key only adds the Etherscan-branded
UIs.

## The exact facts it verifies

- **Contract:** `contracts/src/SubscriptionVault.sol:SubscriptionVault`
  (single self-contained file; no external imports).
- **Compiler:** solc **0.8.24**, EVM **cancun**, optimizer **on / 200 runs**
  (from `contracts/foundry.toml` — `forge` applies these automatically).
- **Constructor:** `constructor(address _keeper)`, arg = keeper
  `0x152c42b53ca48d0d9c6900C966d742558611F24F` (confirmed from the on-chain
  creation tx; the deployer/keeper is the sole arg on every chain).
- **Addresses:** Polygon/Arbitrum/Optimism `0x72ddc27e44FD5F8dCfb494317241c4e60575eEd3`;
  Base `0x162c5212C224137033919c6EE23Aee6A80a8bB78`.

## If a chain fails to verify

The workflow is idempotent and safe to re-run. The most likely cause is
**compiler-settings drift**: the deployed `backend/vault_build.json` bytecode was
produced by settings that differ from the current `foundry.toml`. The workflow's
**pre-flight step** prints whether `forge build` reproduces the deployed artifact —
if it says they differ, reconcile `foundry.toml` with the deploy-time settings
(solc version / optimizer runs / evm version) and re-run. Nothing on-chain is ever
at risk; verification only reads bytecode and publishes public source.

_Hand-run equivalent:_ `cd contracts && ./tools/verify_deployed.sh [chain]`.
