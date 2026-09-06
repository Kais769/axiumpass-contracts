# AxiumPass — Smart-Contract Audit Methodology (living corpus)

> **What this is.** A *living* reference that distils external smart-contract
> security education (audit-firm playbooks, bug-bounty triage standards, the
> Cyfrin/CodeHawks audit method) into the shared vocabulary and process the
> AxiumPass security corpus runs on. It is **integrated on a rolling basis** —
> new course material is folded in as it arrives (see the [Intake log](#intake-log)),
> and each addition is reconciled with what we already practise in
> [`INTERNAL_AUDIT_2026-07.md`](./INTERNAL_AUDIT_2026-07.md) and
> [`SECURITY_HARDENING.md`](./SECURITY_HARDENING.md).
>
> Per-vulnerability-class deep dives (mechanism + detection procedure + the
> concrete AxiumPass application) live in
> [`VULN_CLASSES.md`](./VULN_CLASSES.md) — the class-by-class half of this corpus.
>
> Nothing here changes the deployment gate: new code touching real funds still
> requires an **external** review (bug bounty / audit contest) before mainnet.

---

## 1. Severity — the universal language

Severity is the *lingua franca* of smart-contract security: the same scale is
used by audit firms, bug-bounty programs (Immunefi) and DeFi platforms, so a
finding communicates its stakes to every audience without translation. The
grade is a function of **impact × likelihood**, not of how clever the bug is.

| Severity | Impact / meaning | Action posture |
|----------|------------------|----------------|
| 🔴 **Critical** | Direct theft/redirection of funds or a broken core invariant (here: the non-custodial invariant) on a **deployed** contract. | Stop-the-line; fix before anything else ships. |
| 🟠 **High** (`ÉLEVÉE`) | Major losses, over-billing, or DoS under realistic conditions. | **Urgent to fix.** |
| 🟡 **Medium** (`MOYENNE`) | Conditional / limited-impact risk; centralization with real user harm. | **Recommended** — fix or accept with rationale. |
| 🔵 **Low** (`FAIBLE`) | Minimal impact; hardening / defense-in-depth; latent issues inert on the current token set. | **Optional** — schedule opportunistically. |
| ⚪ **Informational** (`INFO`) | Best practices, code quality, positive assurances, style. | No fund risk; improves maintainability. |

**Why the discipline matters.** A standardised classification lets the team
*prioritise remediation* (a Critical blocks a release; a Low does not) and
*communicate clearly with every stakeholder* — investors, developers, auditors,
counsel — from one shared table.

This mirrors, one-to-one, the scale already applied to the 29 findings in
`INTERNAL_AUDIT_2026-07.md` §Severity scale. The course simply confirms that the
in-house grading speaks the industry-standard dialect. Colour semantics also
stay inside the frozen brand system (green/orange/red are **status** colours).

---

## 2. Report structure — write for the reader, not the tool

An audit report is a *communication* artefact. Each section targets a distinct
audience and answers the question that audience actually asks. A finding that a
developer can act on is useless to an investor who needs the one-line risk
posture — so the report carries both, in the right sections.

| Section | Core content | Primary audience |
|---------|--------------|------------------|
| **Executive Summary** | Overview, security score, findings by severity. | Investors, leadership |
| **Introduction & Scope** | Exact perimeter, tools used, limitations & disclaimers. | Counsel, due-diligence |
| **Detailed Findings** | Technical description, PoC, vulnerable code, recommendations. | Developers, architects |
| **Severity Classification** | Definitions of Critical/High/Medium/Low with criteria. | All audiences |
| **Recommendations** | Gas improvements, patterns, technical documentation. | Technical team |
| **Conclusion** | Final assessment of the security posture. | All stakeholders |

`INTERNAL_AUDIT_2026-07.md` already follows this layout (Scope → Methodology →
Severity scale → per-finding detail with `file:line` + exploit scenario →
remediation roadmap → Closing assessment). Use this table as the checklist when
producing or commissioning any future report so no audience is left without its
section.

---

## 3. The Cyfrin audit method — 10 systematic steps

A repeatable, front-loaded process: understand the protocol *before* reading a
single line of code, then work inward from context → local behaviour →
architecture → known-vuln priors → manual review → report. All ten steps below
are **confirmed verbatim from the course** (see the [Intake log](#intake-log));
the right-hand column maps each to where AxiumPass already does it.

| # | Step | What it entails (course) | Where AxiumPass does it |
|---|------|--------------------------|-------------------------|
| **1** | **Gain the context** | Analyse the technical documentation, the whitepaper, and understand the protocol's business logic **before writing a line of code**. | The two hard invariants (non-custodial; stablecoins-only, fixed-amount) restated up front in every review; `memory/PRD.md`, `ARCHITECTURE.md`. |
| **2** | **Test the protocol locally** | Clone the repo, run the test suite, and interact with the protocol to understand its **real** behaviour. | Foundry suite (`contracts/test/*`), `backend/tests/*` (46+ integration tests booting the app on in-memory Mongo). |
| **3** | **Analyse test coverage** | Identify the code areas **less covered** by existing tests — those are the areas to examine with particular attention. | `forge coverage` on the vaults; the v1 vault was brought under CI precisely because it was a coverage blind spot (F7). |
| **4** | **Visualise the architecture** | Build flow / interaction diagrams between contracts to identify **trust boundaries**. | Fund-flow trust model in `INTERNAL_AUDIT_2026-07.md` §1 (vault ↔ keeper ↔ router ↔ 1inch), keeper/deploy paths named as in-scope. |
| **5** | **Check Solidity versions** | Confirm the versions used and identify **obsolete patterns** or known version-specific vulnerabilities. | Pinned pragma + `foundry.toml`; solhint in CI; OZ vendored at a known version. |
| **6** | **Consult past vulnerabilities** | Use databases like **Solodit** to search for vulnerabilities found in **similar protocols**. | Risk assessment maps the surface to the 2024–2026 loss taxonomy (§2 of the internal audit); subscription/vault-specific priors (over-billing, keeper compromise). |
| **7** | **Anatomy of the protocol** | Map the **roles, access controls, `payable` functions, and possible system states** (the state machine). | Roles/`onlyKeeper`/`Ownable2Step`/subscription statuses (ACTIVE/PAUSED/PAST_DUE/EXPIRED/CANCELLED) enumerated in the audit + `CLAUDE.md`. |
| **8** | **Automated static analysis** | Run **Slither, Aderyn** and other tools to quickly identify known problematic patterns. | Both run **blocking in CI** (`contracts.yml`): Slither `fail-on:high`, Aderyn blocking-on-HIGH, plus solhint. |
| **9** | **Line-by-line review** | Manually examine **every line**, especially critical functions and external interactions. | Manual fieldwork pass in the internal audit; every Critical/High/Medium re-verified against source by three adversarial lenses. |
| **10** | **Write the final report** | Document each finding with **code proof, exploitation scenario, and actionable recommendations**. | This corpus + `INTERNAL_AUDIT_2026-07.md`: every finding anchored to `file:line` with a concrete exploit scenario and remediation. |

**How AxiumPass already runs this.** The internal audit's 7-step process
(Planning → Risk assessment → Internal-control testing → Fieldwork → Evidence
collection → Reporting → Follow-up) is this same loop, compressed. The mapping:

- Cyfrin 1, 4, 6, 7 → internal **Planning** + **Risk assessment** (context,
  architecture/trust boundaries, known-vuln priors, protocol anatomy)
- Cyfrin 2, 3 → **local testing** + **coverage analysis** (Foundry + pytest, `forge coverage`)
- Cyfrin 5, 8 → **Tooling** (pinned pragma; Slither `fail-on:high` + Aderyn + solhint, all blocking in CI)
- Cyfrin 9 → **Internal-control testing** + **Fieldwork** + **Evidence collection**
- Cyfrin 10 → internal **Reporting** + **Follow-up** (severity-ranked, `file:line`,
  PoC; remediation roadmap §7, invariant tests §8, on-chain monitoring §9)

The one gap the course underlines — **Step 1, context first** — is the cheapest
and most under-done step in practice, and the reason the internal review opens
with the two hard invariants (non-custodial; stablecoins-only, fixed-amount)
before any code is read.

---

## 4. How to use this in the corpus

- **Before any review** (internal or external) of an AxiumPass contract: start
  at Step 1 — re-read the relevant `memory/` and `contracts/` docs and restate
  the invariants the contract must preserve.
- **When grading a finding:** use the §1 table; keep colours in the status set.
- **When writing it up:** use the §2 structure; anchor every finding to
  `file:line` with a concrete failure scenario, exactly as the internal audit does.
- **When new course material lands:** append it here, reconcile it with the
  internal audit + hardening runbook, and record it in the intake log below.

---

## Intake log

Rolling record of course material folded into this corpus — the "perpetual
continuity" of the security education stream.

| Date | Module / source | Integrated as |
|------|------------------|---------------|
| 2026-07-08 | Severity scale (High/Medium/Low/Info definitions) | §1 — mapped to the internal severity scale |
| 2026-07-08 | Report sections & their audiences | §2 — report-structure checklist |
| 2026-07-08 | Cyfrin 10-step approach — **Step 1: Gain the context** (confirmed) | §3 — steps table |
| 2026-07-08 | Cyfrin 10-step approach — **Steps 2–10 confirmed verbatim** (local testing, coverage, architecture, Solidity versions, past vulns/Solodit, protocol anatomy, static analysis, line-by-line, final report) | §3 — full table; each row mapped to where AxiumPass already does it |
| 2026-07-08 | **Vuln-class module 1** — arithmetic over/underflow, phantom overflow, EVM ranges, storage collision + detect-and-neutralise procedure | Split into [`VULN_CLASSES.md`](./VULN_CLASSES.md) §1–§2 with a full AxiumPass arithmetic map + storage-collision N/A assurance |

_The Cyfrin 10-step method is now fully captured, and per-vulnerability-class
deep dives have started in `VULN_CLASSES.md`. Next intake: further course
modules (more arithmetic-procedure steps, the next vulnerability classes,
tooling specifics) as they arrive._
