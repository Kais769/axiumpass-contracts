# AxiumPass Contracts

Public mirror of the smart contracts powering [AxiumPass](https://axiumpass.com) — non-custodial recurring stablecoin subscription infrastructure for B2B SaaS and Web3 businesses.

**Web3 Subscriptions, Engineered for B2B.**

## What's here

| Contract | Purpose | Status |
|---|---|---|
| [`src/SubscriptionVault.sol`](src/SubscriptionVault.sol) | v1 subscription vault: the subscriber approves an ERC-20 allowance and creates a subscription; each billing period the keeper (or the subscriber themself) calls `processSubscription`, which pulls the payment and forwards **100% of it directly to the merchant** — the vault never holds funds. | **LIVE** on 4 chains |
| [`src/AutoSwapRouter.sol`](src/AutoSwapRouter.sol) | Stateless "sign once" auto-swap router (1inch v6). Output receiver is enforced on-chain to be the merchant; the router holds no funds. | Deployed (Base, Polygon) |
| [`src/SubscriptionVault4337.sol`](src/SubscriptionVault4337.sol) | v2 account-abstraction-ready vault (EIP-712 session authorizations, EIP-2612 gasless enrolment, ERC-1271/ERC-6492 smart-account signatures). | Deployed, **not enabled** — gated behind an external audit |

## Deployed addresses (SubscriptionVault v1)

All four deployments are **source-verified** on their block explorers (and on Sourcify):

| Chain | Address |
|---|---|
| Polygon (137) | [`0x72ddc27e44FD5F8dCfb494317241c4e60575eEd3`](https://polygonscan.com/address/0x72ddc27e44FD5F8dCfb494317241c4e60575eEd3#code) |
| Base (8453) | [`0x162c5212C224137033919c6EE23Aee6A80a8bB78`](https://basescan.org/address/0x162c5212C224137033919c6EE23Aee6A80a8bB78#code) |
| Arbitrum One (42161) | [`0x72ddc27e44FD5F8dCfb494317241c4e60575eEd3`](https://arbiscan.io/address/0x72ddc27e44FD5F8dCfb494317241c4e60575eEd3#code) |
| Optimism (10) | [`0x72ddc27e44FD5F8dCfb494317241c4e60575eEd3`](https://optimistic.etherscan.io/address/0x72ddc27e44FD5F8dCfb494317241c4e60575eEd3#code) |

The Polygon/Arbitrum/Optimism addresses are identical because the same keeper wallet deployed with plain `CREATE` at the same nonce (`address = f(deployer, nonce)`).

Constructor argument (all chains): `keeper = 0x152c42b53ca48d0d9c6900C966d742558611F24F`.

### AutoSwapRouter

| Chain | Address |
|---|---|
| Base | [`0x4dCdC9C2057A1367003C608606F4F05629884Dc3`](https://basescan.org/address/0x4dCdC9C2057A1367003C608606F4F05629884Dc3#code) |
| Polygon | [`0x1dd00Dfb68773d2043e24A0Ebb6EAdC2e6Ab1953`](https://polygonscan.com/address/0x1dd00Dfb68773d2043e24A0Ebb6EAdC2e6Ab1953#code) |

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

## About this repository

This is a read-only mirror published for transparency and verification. Development happens in the main (private) AxiumPass repository; this mirror is updated when the contracts or their tests change. Issues and pull requests here are not monitored.

## License

[MIT](LICENSE). Vendored dependencies in `lib/` keep their own licenses (OpenZeppelin Contracts: MIT; forge-std: MIT/Apache-2.0).
