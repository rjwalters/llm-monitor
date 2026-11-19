# Work Log Archive — 2026-09

Sections moved byte-for-byte from [WORK_LOG.md](../WORK_LOG.md) by `loom-daemon work-docs archive`.

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
