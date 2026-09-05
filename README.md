# AxiumPass Contracts

Public mirror of the smart contracts powering [AxiumPass](https://axiumpass.com) — non-custodial recurring stablecoin subscription infrastructure for B2B SaaS and Web3 businesses.

**Web3 Subscriptions, Engineered for B2B.**

## What's here

| Contract | Purpose | Status |
|---|---|---|
| [`src/SubscriptionVault.sol`](src/SubscriptionVault.sol) | v1 subscription vault: the subscriber approves an ERC-20 allowance and creates a subscription; each billing period the keeper (or the subscriber themself) calls `processSubscription`, which pulls the payment and forwards **100% of it directly to the merchant** — the vault never holds funds. | **LIVE** on 6 chains |
| [`src/AutoSwapRouter.sol`](src/AutoSwapRouter.sol) | Stateless "sign once" auto-swap router (1inch v6). Output receiver is enforced on-chain to be the merchant; the router holds no funds. | Deployed (Base, Polygon) |
| [`src/SubscriptionVault4337.sol`](src/SubscriptionVault4337.sol) | v2 account-abstraction-ready vault (EIP-712 session authorizations, EIP-2612 gasless enrolment, ERC-1271/ERC-6492 smart-account signatures, gas-free revocation, at-most-one-charge-per-period scheduling). | **LIVE** on 4 chains (hardened redeploy, enabled 2026-07) |
| [`src/FoundersRegistry.sol`](src/FoundersRegistry.sol) | The contract that makes "your name engraved on-chain" literal for the Founders Wall. `owner != registrar` is enforced by the contract itself — one key holding both roles could seal the wall with nobody able to rotate it out — and it has **zero payable functions**, so it can never hold value. | **LIVE** on Base since 2026-07-29 — [`0x411B6B3CbC94CCd9fCe135d11aE2a5BaF14f42F9`](https://basescan.org/address/0x411B6B3CbC94CCd9fCe135d11aE2a5BaF14f42F9) |

## Deployed addresses (SubscriptionVault v1)

The **same bytecode is deployed on all six chains** — 3,028 bytes, read with `eth_getCode` from six
independent public RPCs (one per chain) and hashing to:

```
sha256(runtime bytecode) = cc1dfb8b371fe379a6cd6fb974b9eac2643a26eeeecd5c2b5a7c1e88461a3f7b
```

Anyone can reproduce that check against any RPC, without trusting us.

Source verification is **published on Sourcify for the first four**; the Avalanche and BNB deployments
carry that identical bytecode but their Sourcify entry is not published yet. We say which is which
rather than letting one word cover both.

| Chain | Address |
|---|---|
| Polygon (137) | [`0x72ddc27e44FD5F8dCfb494317241c4e60575eEd3`](https://polygonscan.com/address/0x72ddc27e44FD5F8dCfb494317241c4e60575eEd3#code) |
| Base (8453) | [`0x162c5212C224137033919c6EE23Aee6A80a8bB78`](https://basescan.org/address/0x162c5212C224137033919c6EE23Aee6A80a8bB78#code) |
| Arbitrum One (42161) | [`0x72ddc27e44FD5F8dCfb494317241c4e60575eEd3`](https://arbiscan.io/address/0x72ddc27e44FD5F8dCfb494317241c4e60575eEd3#code) |
| Optimism (10) | [`0x72ddc27e44FD5F8dCfb494317241c4e60575eEd3`](https://optimistic.etherscan.io/address/0x72ddc27e44FD5F8dCfb494317241c4e60575eEd3#code) |
| Avalanche C-Chain (43114) | [`0x72ddc27e44FD5F8dCfb494317241c4e60575eEd3`](https://snowtrace.io/address/0x72ddc27e44FD5F8dCfb494317241c4e60575eEd3) |
| BNB Chain (56) | [`0x72ddc27e44FD5F8dCfb494317241c4e60575eEd3`](https://bscscan.com/address/0x72ddc27e44FD5F8dCfb494317241c4e60575eEd3) |

The Polygon/Arbitrum/Optimism/Avalanche/BNB addresses are identical because the same keeper wallet deployed with plain `CREATE` at the same nonce (`address = f(deployer, nonce)`).

Constructor argument (all chains): `keeper = 0x152c42b53ca48d0d9c6900C966d742558611F24F`.

### SubscriptionVault4337 (v2 — live on 4 of the 6 chains)

New subscriptions route to v2 **on these four chains only**. On Avalanche C-Chain and BNB Chain none of
the three v2 addresses listed below carries any code — `eth_getCode` returns empty for all three on both
chains — so subscriptions there are created on the v1 vault above. That is a capability difference, not
a rollout in progress, and it is stated here rather than left to be discovered.

| Chain | Address |
|---|---|
| Polygon (137) | [`0xe9234C7706a7b15A20947fCBd8390c808c523646`](https://polygonscan.com/address/0xe9234C7706a7b15A20947fCBd8390c808c523646#code) |
| Base (8453) | [`0x6Ed0049DD3F8d6eb24f81fc1ad9978D50cd1D7d8`](https://basescan.org/address/0x6Ed0049DD3F8d6eb24f81fc1ad9978D50cd1D7d8#code) |
| Arbitrum One (42161) | [`0x1dd00Dfb68773d2043e24A0Ebb6EAdC2e6Ab1953`](https://arbiscan.io/address/0x1dd00Dfb68773d2043e24A0Ebb6EAdC2e6Ab1953#code) |
| Optimism (10) | [`0x1dd00Dfb68773d2043e24A0Ebb6EAdC2e6Ab1953`](https://optimistic.etherscan.io/address/0x1dd00Dfb68773d2043e24A0Ebb6EAdC2e6Ab1953#code) |

**Security posture, stated honestly:** the v2 vault is covered by the Foundry test
suite in [`test/`](test/), static analysis (Slither), and an internal hardening
review — but the **external audit is still the outstanding formal quality bar**.
We do not describe these contracts as "audited" and won't until an independent
firm has signed off.

### AutoSwapRouter

| Chain | Address |
|---|---|
| Base | [`0x4dCdC9C2057A1367003C608606F4F05629884Dc3`](https://basescan.org/address/0x4dCdC9C2057A1367003C608606F4F05629884Dc3#code) |
| Polygon | [`0x1dd00Dfb68773d2043e24A0Ebb6EAdC2e6Ab1953`](https://polygonscan.com/address/0x1dd00Dfb68773d2043e24A0Ebb6EAdC2e6Ab1953#code) |

> Note: the Arbitrum/Optimism v2 vault and the Polygon AutoSwapRouter share the
> address `0x1dd0…1953` — same deployer wallet, same nonce, different chains
> (`CREATE` address = f(deployer, nonce)). Each explorer link above shows the
> verified source of the contract actually deployed on that chain.

## Non-custodial by construction

- Payments flow **customer → merchant** in a single transaction; no contract in this repo can accumulate user funds.
- The keeper can only trigger a charge **to the merchant recorded at subscription creation** — it cannot redirect funds, change amounts, or charge more than once per period.
- The subscriber keeps full control: `cancelSubscription` is callable by the subscriber alone, and `processSubscription` is callable by the subscriber as well as the keeper — so subscriptions keep working even without AxiumPass's automation.
- Stablecoins only (USDT, USDC, EURC).

## Build & test

Requires [Foundry](https://getfoundry.sh).

```bash
forge build
forge test
```

Dependencies (OpenZeppelin Contracts, forge-std) are vendored in `lib/` — no submodule setup needed.

## Reproducing the deployed v1 bytecode

The live v1 vault was compiled with solc `0.8.20`, EVM `shanghai`, optimizer `200`. That configuration is pinned in the [`verify_v1`](foundry.toml) profile:

```bash
FOUNDRY_PROFILE=verify_v1 forge build
```

## Security & audit dossiers

The nine documents under [`audit/`](audit/) are byte-identical copies of `contracts/audit/` in the private
tree (published 2026-09-05). They are what a security firm reads before pricing an engagement, so they sit
next to the code they describe rather than behind a request.

| Document | What it is |
|---|---|
| [`AUDIT_ENGAGEMENT_PACKAGE.md`](audit/AUDIT_ENGAGEMENT_PACKAGE.md) | Scope, invariants, deliverables and gate for an external review of `SubscriptionVault4337` |
| [`INTERNAL_AUDIT_2026-07.md`](audit/INTERNAL_AUDIT_2026-07.md) | The internal adversarial review, findings F1–F35 with severity, `file:line` and status |
| [`THREAT_MODEL_STRIDE.md`](audit/THREAT_MODEL_STRIDE.md) | STRIDE threat model across contracts, keeper, backend and frontend |
| [`VULN_CLASSES.md`](audit/VULN_CLASSES.md) | Vulnerability classes checked, and how each maps onto this codebase |
| [`AUDIT_METHODOLOGY.md`](audit/AUDIT_METHODOLOGY.md) | The review method (planning → fieldwork → reporting) and its intake log |
| [`SECURITY_HARDENING.md`](audit/SECURITY_HARDENING.md) | Operational hardening runbook that accompanies the audit |
| [`DEPLOY_RUNBOOK_V2.md`](audit/DEPLOY_RUNBOOK_V2.md) | How v2 was (re)deployed, with the pre-deploy fixes it required |
| [`VERIFY_RUNBOOK.md`](audit/VERIFY_RUNBOOK.md) | Source-verification procedure on the block explorers |
| [`SECURITY_FUNDING_STRATEGY.md`](audit/SECURITY_FUNDING_STRATEGY.md) | How the external audit is meant to be funded (grants first) |

Two things these documents say about themselves, repeated here so nobody reads more into them:

* The internal audit is **not** an external audit. The formal external review of `SubscriptionVault4337`
  remains the outstanding quality bar; none of the contracts here should be described as "audited".
* Finding **F31** in the internal audit (an unauthenticated relay that injected a paid API key on the
  backend side) was **fixed and verified in production on 2026-09-05**: the relay now requires the
  merchant's JWT and answers 401 to anonymous calls. The dossier keeps the finding as written, because
  a finding that disappears from the record is worse than one marked fixed.

## About this repository

This is a read-only mirror published for transparency and verification. Development happens in the main (private) AxiumPass repository; this mirror is updated when the contracts or their tests change. Issues and pull requests here are not monitored.

## License

[MIT](LICENSE). Vendored dependencies in `lib/` keep their own licenses (OpenZeppelin Contracts: MIT; forge-std: MIT/Apache-2.0).
