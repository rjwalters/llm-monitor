# Work Log

Chronological record of merged PRs and closed issues, newest first. Maintained automatically by the Guide role.

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

### 2026-09-18

- **Issue #196** (closed): quota_calibration is never populated: compute tokens-per-weekly-point per account and alert on step changes
- **Issue #202** (closed): selftest hangs in a local swift:6.1 container on every subprocess-spawning test (documented Linux verification path can't run the suite)
- **PR #206**: fix: replace readabilityHandler pipe drains with a blocking-read thread (#202)
- **Issue #199** (closed): Surface quota calibration series in chart + menu-bar step-change alert
- **PR #205**: feat: surface quota calibration series in chart + menu-bar step-change alert
- **Issue #201** (closed): Ingested token spend is invisible: every read path joins on the NULL inferred_account_id
- **PR #204**: feat: fall back to host-total token chart when nothing is attributed
- **Issue #198** (closed): Compute daily quota calibration series (tokens-per-weekly-point) and export
- **PR #203**: feat: compute and export a daily quota-calibration series
- **Issue #197** (closed): Revive Swift transcript token ingest (token_usage/token_sessions writer)
- **PR #200**: feat: revive transcript token ingest (token_usage/token_sessions writer)

### 2026-09-17

- **Issue #194** (closed): Investigate legacy oauth_credentials.source='codex' vs expected 'codex-home'
- **PR #195**: fix: give a stranded OpenAI/Codex account a voice instead of silence (#194)
- **Issue #55** (closed): docs: README screenshots predate provider badges and the Premium % column
- **PR #193**: docs: refresh README screenshots and move them into docs/

### 2026-09-16

- **PR #184**: Fix Codex app-server spawn failing on newer CLI's --ask-for-approval values
- **Issue #188** (closed): accounts push/pull over ssh: converge a fleet's monitor stores without hand-shipping plaintext token bundles
- **PR #192**: feat: stream account bundles over ssh with `accounts push`/`pull`
- **Issue #187** (closed): scripts/install-linux.sh: one-command install/upgrade of the headless daemon on a Linux fleet host
- **PR #191**: feat: add scripts/install-linux.sh for one-command daemon install/upgrade
- **Issue #185** (closed): Publish a static-stdlib linux-x64 release binary — the documented Linux build is runtime-dependent and both fleet workers were running a binary that cannot load
- **PR #190**: ci: publish a static-stdlib linux-x64 release binary
- **Issue #186** (closed): docs: Linux build must use --static-swift-stdlib (or the swift:6.1 container); document the 'cannot open shared object file' failure and cure
- **PR #189**: docs: document --static-swift-stdlib for deployable Linux builds

### 2026-08-19

- **Issue #179** (closed): Simplify UsageStore history loaders: dedup cutoff-date boilerplate and decimation filter
- **PR #182**: refactor: dedupe UsageStore chart-history cutoff and decimation logic
- **Issue #181** (closed): [Refiled] accounts can persist with email=NULL (address only in account_name) — resolved

### 2026-08-16

- **Issue #176** (closed): Dedup repeated --db/--help CLI option parsing across CodexCLI and AccountSyncCLI
- **PR #177**: refactor: dedup --db/--help CLI option parsing across CodexCLI and AccountSyncCLI
- **Issue #173** (closed): loadActiveCredentials admits an empty-string access_token (no TRIM guard)
- **PR #174**: fix: reject empty-string access_token in loadActiveCredentials
- **Issue #169** (closed): isAbsentCodexIdentity's three hasStoredToken SQL copies diverge (missing TRIM/is_active checks)
- **PR #172**: refactor: factor the absent-identity stored-token predicate into one SQL helper
- **Issue #168** (closed): openAIAccountCount excludes more than absent identities — narrows the #111 ambient-home ambiguity guard
- **PR #171**: fix: count legacy usage_history rows in openAIAccountCount
- **Issue #130** (closed): Multi-identity Codex needs a lifecycle: discovery, provisioning, drift, and a cross-host view
- **Issue #135** (closed): Declarative intended Codex identity set: codex list/ranking.json should report 'absent', not just fewer rows
- **PR #166**: feat: report a declared-but-unprovisioned Codex identity as "absent"

### 2026-08-15

- **Issue #159** (closed): Dedup pointing-hand cursor onHover into a single View modifier
- **PR #163**: refactor: extract pointing-hand hover cursor into a View modifier
- **Issue #156** (closed): Menubar status-item badge is not gated by staleness or drift
- **PR #161**: fix: gate menubar badge percentage on staleness and credential drift
- **Issue #157** (closed): Remove two dead-code items: RateLimitWindow.remainingPercent, RollTokenView's unused store param
- **PR #160**: refactor: remove unused RateLimitWindow.remainingPercent and RollTokenView store param
- **Issue #147** (closed): Adopt a re-logged-in Codex identity instead of freezing: the app should follow a codex login switch
- **PR #158**: feat: adopt a re-logged-in Codex identity instead of freezing
- **Issue #148** (closed): No row should present a stale figure as current: a cause-independent freshness guarantee
- **PR #154**: feat: derive freshness thresholds from poll interval, gate stale rows
- **Issue #150** (closed): Remove unused OpenAI response fields: userId, idToken
- **PR #155**: chore: remove unread userId/idToken fields from OpenAI response structs
- **Issue #151** (closed): chore: fix stale stored-credential log message in OAuthPoller tier-2 fallback
- **PR #153**: fix: correct stale stored-credential fallback claim in tier-2 log line
- **Issue #146** (closed): A drifted Codex row shows a healthy green dot while frozen — identity conflict only writes a log line
- **PR #152**: fix: surface Codex identity drift as a distinct account state
- **Issue #142** (closed): Simplify SelfTest.swift: extract shared temp-dir + stub-writer helper
- **PR #144**: test: dedup temp-dir and writeStub boilerplate in SelfTest.swift
- **Issue #132** (closed): codex list: enumerate all discoverable Codex homes, not just registered accounts
- **PR #140**: codex list: discover unregistered ~/.codex* homes on disk
- **Issue #134** (closed): Surface Codex identity drift as a distinct account state (not stale/failed reading)
- **PR #138**: feat: report a re-logged-in Codex home as drift in `codex list`
- **Issue #133** (closed): Add codex provision <label> to collapse home-create + login + register into one command
- **PR #139**: feat: add codex provision <label> to collapse home-create + login + register
- **Issue #129** (closed): Clipboard account transfer silently drops Codex accounts after #123 — and reports "Nothing to copy" on a Codex-only host
- **PR #137**: fix: report excluded Codex accounts in clipboard account transfer
- **Issue #117** (closed): Purge the 18 orphaned probe_snapshots rows #106 left behind (and audit named_limits)
- **PR #126**: fix: purge orphaned probe_snapshots/named_limits rows left by #106
- **Issue #118** (closed): Three CodexAppServer/OAuthPoller robustness nits from the PR #111 review
- **PR #127**: fix: distinguish account/read decode failures from null account, make reap's wait suspend
- **Issue #104** (closed): Retire stored OpenAI OAuth tokens and exclude Codex accounts from accounts export
- **PR #123**: feat: null out stored OpenAI tokens and exclude Codex from account sync
- **Issue #116** (closed): selftest writes ~14 lines into the user's real debug.log: flog.info from a pure mapper
- **PR #125**: fix: move codex app-server usage logging out of the pure snapshot() mapper
- **Issue #115** (closed): docs: `brew install codex` installs a stale 0.46.0 formula — the cask is the correct package
- **PR #124**: docs: document Homebrew cask remediation, log resolved codex version
- **Issue #112** (closed): selftest --db fails on any host with a Codex account: over-strict 'backfilled to anthropic' assertion
- **PR #121**: fix: narrow over-strict provider-backfill assertion in selftest --db
- **PR #119**: chore: sync User-Agent to claude-code 2.1.224
- **Issue #101** (closed): Remove 5 unused computed properties: dead code in AnthropicAPI/UsageStore/OAuthPoller
- **PR #120**: refactor: remove 5 unused computed properties from AnthropicAPI/UsageStore/OAuthPoller
- **PR #109**: build(deps): bump actions/checkout from 5 to 7 in the github-actions group
- **Issue #103** (closed): Support multiple Codex accounts via per-account CODEX_HOME
- **PR #114**: feat: poll each Codex account from its own CODEX_HOME
- **Issue #105** (closed): accounts export fails with SQLITE_CANTOPEN on a WAL database with no -shm file
- **PR #113**: fix: escalate read-only SQLite opens when a WAL database has no -shm
- **Issue #102** (closed): Read Codex usage via `codex app-server` instead of storing OAuth tokens
- **PR #111**: feat: read Codex usage over `codex app-server` instead of a stored token
- **Issue #106** (closed): Orphaned oauth_credentials rows retain live tokens for deleted accounts
- **PR #110**: fix: delete an account's credential rows when the account is removed
- **PR #108**: chore: configure Dependabot for github-actions
- **PR #107**: docs: supersede the Codex spike — app-server replaces stored OAuth tokens
- **Issue #98** (closed): Remove dead RateLimitSnapshot.nextReset computed property
- **PR #99**: refactor: remove dead RateLimitSnapshot.nextReset computed property
- **Issue #94** (closed): Dedupe RankingExporter.normalizedISO parse body onto UsageRecord.parseISO
- **PR #96**: refactor: delegate RankingExporter.normalizedISO to UsageRecord.parseISO
- **Issue #83** (closed): Auditor Capability Request: no Swift toolchain or docker access on this host to validate claude-monitor builds
- **PR #93**: refactor: drop UsageStore.parseDate in favor of UsageRecord.parseISO
- **Issue #91** (closed): Remove duplicate parseDate helper in UsageStore: delegate to UsageRecord.parseISO
- **PR #88**: refactor: dedupe parseISO, colorForPercent, and b64url helpers
- **Issue #87** (closed): Dedupe copy-pasted helpers: parseISO, colorForPercent, b64url
- **PR #86**: refactor: unify percent-severity color thresholds into shared PercentSeverity enum
- **Issue #85** (closed): Remove duplicated percent-severity color logic (colorForPercent x2 + inline copy in main.swift)
- **PR #82**: refactor: convert static-only window controllers to enums
- **Issue #81** (closed): Convert static-only window-controller classes to enums for consistency
- **Issue #79** (closed): Remove unused formatResetTime function in UsagePopoverView.swift
- **PR #78**: refactor: remove dead helpers and struct with zero call sites
- **Issue #76** (closed): Remove dead code: unused helpers/struct in UsageStore, UsageChartView, UsagePopoverView

### 2026-08-06

- **PR #72**: ci: add workflow_dispatch fallback trigger, document manual CI re-run
- **Issue #66** (closed): GitHub Actions not triggering on open PRs (#64, #65)
- **PR #70**: feat: round-trip OpenAI/Codex credentials through clipboard account transfer
- **Issue #67** (closed): Extend clipboard account transfer format to round-trip OpenAI/Codex credentials
- **PR #64**: fix: report accurate exported-account count when copying accounts
- **Issue #63** (closed): Copy/Paste Accounts silently drops OpenAI/Codex accounts; copy count over-reports

### 2026-08-05

- **Issue #60** (closed): Guide: document-maintenance phase creates a self-perpetuating docs-PR loop
- **PR #61**: fix(guide): exclude self-authored docs-maintenance PRs from work-log scan
- **PR #58**: docs: Guide document maintenance update
- **PR #57**: docs: Guide document maintenance update
- **PR #56**: docs: Guide document maintenance update

### 2026-08-04

- **PR #54**: Order capped accounts by time until they are usable again

### 2026-08-02

- **Issue #51** (closed): Adopt Swift 6 language mode package-wide (3 known concurrency errors to fix)
- **PR #53**: build: adopt Swift 6 language mode package-wide
- **Issue #52** (closed): CI: bump actions/checkout to v5 (Node.js 20 deprecation warning)

### 2026-07-31

- **Issue #45** (closed): Healing migration: merge duplicate provider accounts sharing an email
- **PR #50**: fix: heal duplicate provider accounts sharing an email at launch
- **Issue #47** (closed): Provider-aware column titles in the summary table ("Fable Left" is meaningless for OpenAI rows)
- **PR #49**: fix: provider-aware column titles for premium/extra summary columns
- **Issue #46** (closed): macOS: `--version` without `--headless` launches the GUI instead of printing
- **PR #48**: macOS: dispatch --version at top level so it never launches the GUI
- **Issue #38** (closed): Verify the OpenAI token-refresh path against a real expiring token
- **Issue #39** (closed): build-macos-app.sh User-Agent detection misses a Homebrew-installed claude
- **PR #44**: fix: fall back to claude --version for User-Agent detection
- **Issue #40** (closed): sortedAccountsForPopover tie-breaks on account UUID, giving arbitrary order
- **PR #43**: fix: tiebreak account ordering on natural display name, not account id
- **Issue #41** (closed): Document that a clean local swift build does not gate Swift strict-concurrency errors
- **PR #42**: docs: clarify local swift build does not gate strict-concurrency errors

### 2026-07-30

- **PR #37**: fix: grow the mascot to 16x13 to balance against the rosette
- **PR #36**: feat: use OpenAI's rosette for the provider badge
- **PR #35**: feat: draw provider badges as pixel-art glyphs
- **PR #34**: fix: sort account names naturally (agent-10 after agent-9)
- **Issue #32** (closed): Chart OpenAI per-model sub-limits (additional_rate_limits[]) in the per-account history window
- **PR #33**: feat: persist and chart OpenAI per-model sub-limits (named_limits)
- **Issue #25** (closed): Epic: multi-provider support — monitor OpenAI GPT (Codex) subscription accounts alongside Claude
- **Issue #29** (closed): [Epic #25 Phase 3] OpenAI usage poller + provider-aware ranking export
- **PR #31**: feat: poll OpenAI/Codex usage and tag ranking.json with provider
- **Issue #28** (closed): [Epic #25 Phase 2] Provider abstraction: Account schema + provider-agnostic rate-limit model
- **PR #30**: feat: provider-agnostic rate-limit model + provider column on accounts
- **Issue #26** (closed): spike: can a cheap authenticated probe read ChatGPT/Codex subscription usage + rate-limit windows?
- **PR #27**: docs: write up static-analysis findings on ChatGPT/Codex usage probe
- **Issue #13** (closed): CI: add a Linux build job to cover the headless target
- **PR #24**: ci: add Linux build job for the headless daemon target
- **Issue #16** (closed): feature: headless CLI to export/import account records + credentials for multi-host sync
- **PR #22**: feat: headless CLI to export/import accounts + credentials for multi-host sync
- **Issue #15** (closed): accounts can persist with email=NULL (address only in account_name) — breaks downstream consumers keying on email
- **PR #23**: fix: backfill accounts.email from a well-formed account_name label
- **Issue #18** (closed): wire package.json check scripts to swift build so Loom's build gate isn't vacuous
- **PR #21**: build: wire package.json check scripts to swift build
- **Issue #19** (closed): icon-master.source.json sha256 no longer matches icon-master.png
- **PR #20**: fix: update icon-master.source.json sha256 to match tracked PNG
- **Issue #14** (closed): claude-monitor.service: network-online.target ordering is a no-op in the systemd user manager
- **PR #17**: fix: drop no-op network-online ordering from user systemd unit

### 2026-07-28

- **Issue #7** (closed): Refresh README screenshots — they predate the 1.15 UI
- **PR #12**: docs: refresh README screenshots to the 1.15 UI
- **Issue #6** (closed): Document Roll Token workflow (temporary fix) and its reliance on undocumented claude.ai endpoints
- **PR #11**: docs: document Roll Token workflow and its undocumented-endpoint dependency
- **Issue #5** (closed): dist/cli.js fails at startup: Cannot find package 'commander' (ERR_MODULE_NOT_FOUND)
- **PR #10**: docs: note legacy pre-2.0 artifact cleanup in Uninstall (closes stale-CLI report)
- **Issue #8** (closed): Headless Linux mode: run the usage poller as a daemon on cloud loom worker hosts
- **PR #9**: Add headless Linux mode: portable core + UI-less poll loop daemon

### 2026-07-22

- **PR #4**: Add Fable/premium usage tracking and master account list
- **Issue #2** (closed): Emit ranking.json for external load balancers (loom + lean-genius)
- **PR #3**: Emit ranking.json for external load balancers (loom + lean-genius)

### 2025-12-15

- **PR #1**: Release v1.5.0: Fix extension resource cleanup
