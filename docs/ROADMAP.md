# Roadmap

LLM Monitor shows subscription quota, reset times and usage trends for Claude,
OpenAI Codex and z.ai GLM Coding Plan accounts, as a macOS menu-bar app or a
headless Linux daemon.

Status as of 2026-11-13, `main` @ `84df471`.

[`WORK_PLAN.md`](../WORK_PLAN.md) is generated from issue labels and
[`WORK_LOG.md`](../WORK_LOG.md) records what merged; this file is the direction.

## Where it stands

Released: **v2.1.0** (2026-09-26, `CHANGELOG.md`). `UsageStore.swift` still
reads `static let current = "2.1.0"`.

Done and on `main`:

- **Three providers.** Claude over OAuth (`AnthropicAPI.swift`), Codex over
  `codex app-server` with no stored OpenAI credential (`CodexAppServer.swift`,
  design in `docs/spikes/2026-07-30-codex-usage-probe.md`), and z.ai by API key
  (`ZaiAPI.swift`).
- **One portable core, two front ends.** The menu-bar UI is fenced with
  `#if os(macOS)`; the same package builds as a headless Linux daemon
  (`HeadlessMain.swift`, `scripts/install-linux.sh`, `scripts/llm-monitor.service`).
- **Outputs other tools read.** `ranking.json` (`RankingExporter.swift`),
  transcript token ingest (`TranscriptImporter.swift`, `tokens sync`) and the
  daily quota-calibration series (`QuotaCalibration.swift`, `calibrate`).
- **Multi-host.** `accounts push` / `pull` over ssh (`AccountSyncRemote.swift`),
  rolled Claude tokens read from Loom's pool (`ClaudeTokenFiles.swift`,
  `claude sync`), Loom Codex profiles read-only (`LoomAccountsCheck.swift`).
- **Tests and CI.** `llm-monitor selftest` (`SelfTest.swift`, about 9,000
  lines, 133 test functions, no network) runs on macOS and Linux in
  `.github/workflows/build.yml`, which also builds a static-stdlib
  `llm-monitor-linux-x64` binary and attaches it to each published release.

Merged since v2.1.0 and **not yet released** (`CHANGELOG.md` `[Unreleased]`,
backfilled by #274): live Codex readings from `loom-daemon accounts check
--live` (#230), single-instance lock (#238), the reason line on stale rows
(#237), resizable popover (#236), provider-neutral UI and the Add Account
provider picker (#225, #226, #227), calibration alert moved to the popover
footer (#243), time-to-limit bounded by the window reset (#221), revoked
credentials exported as `"status": "blocked"` (#240, #241), the `selftest`
recursion fix (#234), and `claude sync` documentation (#278).

## Now

Nothing in the tracker is ready to build: no open issue carries `loom:issue`.
The three items below can start today and have no issue yet; drafts exist.

1. **Prepare the 2.2.0 release.** A host installed with
   `install-linux.sh --from-release` gets v2.1.0, which lacks every change
   listed above, including the `blocked` status in `ranking.json`.
   Done when: a PR renames `[Unreleased]` to `[2.2.0]` with a fresh empty
   `[Unreleased]` above it, and the version constant and both plist strings
   read `2.2.0` (the `bump:` command in `.repo/release-policy.md`), with CI
   green. Publishing the release is a separate, attended step; it triggers
   `publish-linux-release-asset`, which attaches the Linux binary.
2. **`selftest --filter` and `--list`.** The suite is one command that runs
   everything; there is no way to run one area while working on it.
   Done when: `llm-monitor selftest --list` prints the test names,
   `--filter <substring>` runs only matching tests and exits non-zero when
   nothing matches, the unfiltered run is unchanged, and `selftest --help` and
   the README "Run" section describe both.
3. **`install-linux.sh --from-release` refuses a non-x86_64 host up front.**
   The only release asset is `llm-monitor-linux-x64`; on another architecture
   the script downloads it and fails later at the `--version` smoke test.
   Done when: the script checks `uname -m` before downloading, exits with a
   message that names `--from-source` as the alternative, and `--from-source`
   and `--binary` are unaffected.

## Next

- **z.ai seats from Loom's shared API-key pool, and sub-1% burn display**
  (#249, PR #250). Done when a Linux host with only pool key files shows its
  z.ai seats in `zai list` and `ranking.json`, and a lightly used seat no
  longer reads `0%`. Unblocked once the scope question under "Blocked and
  waiting" is answered and PR #250 is rebased (it conflicts with `main`).
- **Remove the Claude Monitor compatibility shims** (#210): the
  `~/.claude-monitor` symlink, the `claude-monitor` binary alias and duplicate
  release asset, the `CLAUDE_MONITOR_*` environment fallback. Done when the
  checklist in #210 is ticked and CI's smoke run no longer asserts the symlink.
  Unblocked once every host that syncs with `accounts push` / `pull` runs
  2.0 or newer and a Loom release that reads `~/.llm-monitor` natively
  (rjwalters/loom#8849, closed) is deployed there.

## Later

- **Per-account usage-limit resets** (#285). Question first: how may the app
  read a claude.ai web session at all, given that it stores no cookie today,
  and which endpoint carries the data? See below.
- **A linux-arm64 release asset.** Question first: does any host that runs the
  headless daemon need it, or is `--from-source` enough there?
- **Splitting `SelfTest.swift` and `OAuthPoller.swift`** (about 9,000 and 3,400
  lines). Question first: does `--filter` (Now item 2) remove most of the pain,
  and can the split be done without changing any assertion?
- **A real `lint` step.** `package.json`'s `lint` script is a placeholder.
  Question first: is the toolchain's `swift format lint` acceptable with a
  configuration that needs no mass reformat of the existing sources?

## Blocked and waiting

- **#285, operator decision.** The issue body ranks three options (a
  browser-console script with nothing stored, a stored session cookie, or
  dropping the feature). Endpoint discovery is paused: the 2026-11-13 comment
  records that an automated browser hit a captcha loop on login.
- **#249 / PR #250, scope ruling.** The issue asks for pool seats to be
  discovered; a 2026-10-30 comment on the issue asks that shared-pool seats not
  be imported unless a denylist is honoured. Those two need reconciling before
  PR #250 is worth rebasing. The PR also comes from a fork and has been
  cycling between hold labels (see its 2026-10-17 comment).
- **#231, needs a specific host.** Live verification of `LoomAccountsCheck`
  against a populated `accounts check --live` report needs a Swift-capable
  host with a live database and at least one provisioned Codex profile. The
  decoder and fixture are covered offline; this is evidence, not code.
- **#210, deployment state.** See Next; not checkable from this repository.
- **PR #208, unreviewed since 2026-09-21.** It replaces
  `.github/dependabot.yml` with Renovate. The current `dependabot.yml` states
  that an actions-only Dependabot configuration is deliberate, so the PR needs
  an explicit accept-or-close decision. It carries no review label.

## Not planned

- **A Linux tray indicator.** #246 was closed as not planned; Linux stays
  headless and other tools read `ranking.json`.
- **Storing an OpenAI credential.** The 2026-08-15 supersession in
  `docs/spikes/2026-07-30-codex-usage-probe.md` reversed that design; usage is
  read over `codex app-server`.
- **Calling claude.ai cookie endpoints from the app.** The README's roll-token
  section keeps those in a browser console; #285 may revisit this, by decision.
