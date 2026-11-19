# Work Log

Chronological record of merged PRs and closed issues, newest first. Maintained automatically by the Guide role.

## Archives

- [2026-09](work_log/WORK_LOG_2026-09.md)
- [2026-08](work_log/WORK_LOG_2026-08.md)
- [2026-07](work_log/WORK_LOG_2026-07.md)
- [2025-12](work_log/WORK_LOG_2025-12.md)

### 2026-11-19

- **Issue #333** (closed): Popover: compareRows re-derives effectiveSortBy/visibleProviders and rateLimit per comparison (residual of #330/#331)
- **PR #335**: perf(popover): prepare sort keys once per sort instead of per comparison
- **Issue #331** (closed): Popover: hoist poolTallies/visibleProviders out of the per-row ForEach closure (residual of #330)
- **PR #332**: perf(popover): hoist poolTallies/visibleProviders out of the per-row closure
- **PR #329**: fix(popover): drop the per-row "resets: unknown" label
- **PR #330**: perf(popover): stop re-sorting every account per row on each redraw
- **Issue #326** (closed): Finish the repository-owner rename: stale rjwalters references outside the #323 scope

### 2026-11-18

- **PR #316**: ci: qualify Build workflow for GitHub merge queues
- **Issue #318** (closed): ci: settle whether CodeQL default setup reports on merge_group before selecting required checks
- **Issue #315** (closed): ci: qualify PR checks for GitHub merge queues

### 2026-11-17

- **PR #312**: fix: walk flattenValue object keys in sorted order so archive truncation is deterministic
- **Issue #301** (closed): flatten's 200-field cap truncates wham/usage archives nondeterministically (unordered dictionary walk)
- **PR #311**: fix: tie-break usage_history newest-row reads to the real row after a reset
- **Issue #310** (closed): latestUsage's point-read can return the synthetic reset row (no rowid tiebreak, no is_synthetic filter)
- **PR #309**: refactor: share the pool-input assembly and record-based reset advice
- **Issue #305** (closed): ResetAdvisor wiring re-derives inputs the codebase already spells once
- **PR #307**: docs: document ProviderPoolSummary/ResetAdvisor entries and update menubar/exporter notes in CLAUDE.md
- **Issue #306** (closed): CLAUDE.md: add ResetAdvisor.swift / ProviderPoolSummary.swift entries, and main.swift's menubar description is now stale
- **PR #304**: feat: flag accounts that should spend a stored limit reset (read-only)
- **Issue #303** (closed): Flag when an account should spend a stored limit reset (read-only; operator spends by hand)
- **PR #302**: feat: per-provider pool summary tabs in the popover and an accounts list CLI
- **Issue #297** (closed): Separate accounts into one tab per provider (pools of ~20 accounts each)
- **PR #299**: feat: surface Codex unused limit-reset credits from wham/usage readings
- **Issue #298** (closed): Show Codex reset credits: wham/usage already returns rate_limit_reset_credits

### 2026-11-14

- **PR #295**: docs: link ROADMAP.md from README and mark it human-maintained
- **Issue #290** (closed): docs/ROADMAP.md is unreferenced and off the path Loom's roadmap lookup reads
- **PR #294**: fix: refuse install-linux.sh --from-release on non-x86_64 hosts
- **Issue #289** (closed): install-linux.sh --from-release: refuse a non-x86_64 host before downloading
- **PR #286**: docs: roadmap as of 2026-11-13
- **PR #293**: chore: roll CHANGELOG to 2.2.0 and bump version strings
- **Issue #287** (closed): Prepare the 2.2.0 release: roll CHANGELOG [Unreleased] and bump the version
- **PR #292**: feat: add --list and --filter to selftest
- **Issue #288** (closed): selftest: add --list and --filter <substring> to run part of the suite

### 2026-11-13

- **PR #283**: Bump Repo Skills 0.25.10 -> 0.26.1

### 2026-11-09

- **PR #279**: docs: document claude sync and LOOM_SHARED_TOKENS_DIR
- **Issue #278** (closed): Document `llm-monitor claude sync` and the token-directory overrides in README and --help

### 2026-11-07

- **PR #276**: Bump Repo Skills 0.25.1 -> 0.25.10

### 2026-11-06

- **PR #274**: docs(changelog): backfill Unreleased with user-visible changes since 2.1.0
- **Issue #273** (closed): Backfill CHANGELOG [Unreleased] with the user-visible PRs merged since 2.1.0

### 2026-11-01

- **PR #271**: Bump Repo Skills 0.24.7 -> 0.25.1

### 2026-10-31

- **PR #268**: ci: move build-macos runner from macos-14 to macos-15
- **Issue #267** (closed): CI: move macos-14 runner pins to macos-15 before the 2026-11-02 image retirement

### 2026-10-25

- **Issue #265** (closed): syncClaudeTokenFiles rewrites accounts.env, fighting external managers (claudeauth)

### 2026-10-23

- **Issue #246** (closed): Linux: top-bar tray indicator (AppIndicator) reading ranking.json

### 2026-10-21

- **PR #261**: Bump Repo Skills 0.24.3 -> 0.24.7

### 2026-10-17

- **Issue #259** (closed): Add a LICENSE file
- **PR #258**: chore: gitignore .loom/accounts.json (per-host Loom account pool state)
- **PR #242**: chore(claude): track .claude/settings.json

### 2026-10-16

- **PR #254**: Bump Repo Skills 0.24.1 -> 0.24.3

### 2026-10-15

- **PR #252**: Bump Repo Skills 0.19.5 -> 0.24.1

### 2026-10-07

- **Issue #243** (closed): Calibration alert: replace menu-bar dot with popover footer notice; ignore near-empty token days
- **PR #244**: Calibration alert: popover footer notice; ignore near-empty token days (#243)

### 2026-10-05

- **PR #237**: feat(ui): say why a stale or never-read row is blank
- **PR #241**: fix: keep a stored 401 sticky and stop treating a missing credential as one
- **PR #240**: fix: persist 401 poll failures and export revoked credentials as blocked

### 2026-10-03

- **Issue #238** (closed): Second launch of LLMMonitor should not start a second instance
- **PR #239**: Refuse a second LLMMonitor instance on the same data directory

### 2026-10-02

- **PR #236**: Resizable popover, no empty launch window, drop even-burn mark

### 2026-10-01

- **Issue #234** (closed): selftest push: stub ssh re-execs Bundle.main.executablePath → unbounded recursion when suite runs from a standalone binary
- **PR #235**: fix(selftest): stop the push check re-execing a non-CLI host (#234)

### 2026-09-30

- **PR #229**: fix: don't compare a legacy user- Codex id with a workspace id
- **Issue #226** (closed): UI: Add Account provider picker (Claude / z.ai / Codex)
- **Issue #227** (closed): UI: hide Anthropic-only columns when no visible account uses them
- **Issue #225** (closed): UI: provider-neutral copy (popover title, empty state, chart, Roll Token, Auth column)
- **PR #228**: feat(ui): provider-neutral UI for v3 (copy, Add Account picker, column hiding)

### 2026-09-29

- **Issue #230** (closed): Read Loom-profile Codex usage from 'accounts check --live' instead of rollout snapshots
- **PR #232**: feat(codex): prefer loom-daemon's live rate-limit check over rollout snapshots

### 2026-09-27

- **Issue #220** (closed): feat(ui): show elapsed-time-normalized 'even burn' position (glide-slope mark) per rate-limit window
- **PR #224**: feat: show elapsed-time-normalized even-burn mark per rate-limit window
- **Issue #221** (closed): fix(chart): time-to-limit projection ignores the window's reset instant
- **PR #223**: fix(chart): time-to-limit projection ignores the window's reset instant
- **Issue #219** (closed): feat(monitoring): evaluate Stage-11-Agentics/glideslope as reference implementation for LLM monitoring
- **PR #222**: docs: evaluate glideslope as a reference implementation (#219)

### 2026-09-26

- **PR #218**: feat: read rolled Claude tokens from ~/.claude-oauth and the Loom pool
- **PR #216**: fix: persist Codex snapshot diagnostics; export ranking.json on launch
- **PR #217**: fix(security): ignore sibling copies of the Loom token pool

### 2026-09-25

- **PR #207**: chore(deps): bump the github-actions group across 1 directory with 2 updates
- **PR #214**: feat: read-only visibility into Loom's Codex profiles
- **PR #211**: refactor!: rename Claude Monitor to LLM Monitor (2.0)
- **PR #209**: feat: z.ai (GLM Coding Plan) accounts as a third provider
- **Issue #212** (closed): Flaky selftest: CodexAppServer argfail-stub race under host load
- **PR #213**: fix: surface codex's stderr when it exits before the handshake (#212)
