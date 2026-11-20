# Work Plan

Prioritized roadmap derived from current GitHub label state. Regenerated automatically by the Guide role whenever labels change — see [WORK_LOG.md](WORK_LOG.md) for completed work.

<!-- guide:plan-body:start -->
_Generated: 2026-11-20T05:52:54Z (snapshot; compare against live labels)_
## Operator Attention: Merge-Risk-Hold Pileup

Judge-approved PRs under a hold (`loom:blocked` or `loom:operator`) — only a human merge decision is missing.

- **#325**: feat: add in-app update check and one-click self-install for macOS

## Very Important

`loom:very-important` (one counts per workspace); every stage takes these first.

_None._

## Important

`loom:important`; taken before unlabelled work.

_None._

## Ready

Human-approved issues (`loom:issue`) ready for implementation — excluding held (`loom:blocked`/`loom:operator`/`loom:frozen`), `loom:building`, and issues closed by an open `loom:pr` PR (listed under Approved).

_None._

## In Progress

Issues currently being built (`loom:building`).

- **#285**: Show each account's available usage-limit resets (weekly and per-model) alongside utilization
- **#320**: Codex accounts show "usage unknown" on a host that no longer runs Codex, though other hosts hold fresh readings
- **#323**: Offer an in-app "Update now" when a newer release is available
- **#338**: Per-account scope (personal | work): push/export skip personal accounts; popover marks them

## PRs Awaiting Review

PRs waiting on Judge (`loom:review-requested`).

_None._

## Approved (Awaiting Merge)

PRs that passed review (`loom:pr`). Held PRs require a human merge decision.

- **#325**: feat: add in-app update check and one-click self-install for macOS — closes #323

## Proposed

Issues carrying `loom:curated`.

- **#231**: Live-verify LoomAccountsCheck against a populated 'accounts check --live' report *(curated)* *(held)*
- **#249**: z.ai seats invisible on Loom workers: also discover keys from Loom's shared api-keys pool (~/.loom/api-keys/zai), show sub-1% burn *(curated)* *(held)*
- **#285**: Show each account's available usage-limit resets (weekly and per-model) alongside utilization *(curated)*
- **#320**: Codex accounts show "usage unknown" on a host that no longer runs Codex, though other hosts hold fresh readings *(curated)*
- **#323**: Offer an in-app "Update now" when a newer release is available *(curated)*
- **#338**: Per-account scope (personal | work): push/export skip personal accounts; popover marks them *(curated)*

## Proposed (Architect / Hermit)

_None._

## Epics

_None._

## Backlog Balance

| Bucket | Count |
|------|-------|
| Operator merge-risk holds | 1 |
| Very important | 0 |
| Important | 0 |
| Ready (`loom:issue`, net of holds/building/merge-pending) | 0 |
| In Progress (`loom:building`) | 4 |
| PRs awaiting review | 0 |
| Approved PRs awaiting merge | 1 |
| Curated | 6 |
| Architect / Hermit proposals | 0 |
| Active epics | 0 |
<!-- guide:plan-body:end -->
