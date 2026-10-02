# Spike: glideslope as a reference implementation (2026-09-27)

> **Outcome (2026-10-01):** the even-burn ◆ mark recommended in §1 shipped in #224 (#220) and was then removed at the operator's request — it was not wanted in the UI. Do not re-adopt it without an explicit ask.

**Question.** Does [Stage-11-Agentics/glideslope](https://github.com/Stage-11-Agentics/glideslope)
do anything llm-monitor should adopt? (#219)

**Outcome.** One idea is worth adopting in adapted form: the elapsed-time-normalized
"even burn" position, which glideslope calls the ◆ glide-slope mark. It is filed as
**#220**. Reading glideslope's projection code also turned up a missing bound in
llm-monitor's time-to-limit estimate, filed as **#221**. Nothing else is recommended
for adoption. Credential posture is independently converged. The pool and cost
figures answer different questions from ours. The menu bar app is a surface
glideslope explicitly lacks.

## Scope and evidence

- **glideslope** was read at commit `33c9edf10e8396b4522a596b00ca9553904943d0`
  (`main`, committed 2026-09-26 15:36 -0700). The files read were `README.md`,
  `SECURITY.md`, `PROVIDERS.md`, `skills/glideslope/SKILL.md`, and the relevant
  functions of `glideslope.py`: `even_pace_percent`, `exhausts_at`,
  `best_alternative`, `claude_pool`, `total_pool`, `roll_forward_windows`,
  `shadow_cost`/`SHADOW_PRICES`, `render_api_equivalent`, and
  `query_harness_spend`. Every glideslope claim below comes from that commit. None
  is copied from the issue body.
- **llm-monitor** was read at `e8079a1` (`main`). The files were
  `PercentSeverity.swift`, `RateLimitWindow.swift`, `UsageChartView.swift`,
  `QuotaCalibration.swift`, and `UsageStore.swift` (the `sortedAccountsForPopover`
  ranking).
- **Out of scope.** The original filing's framing is out of scope:
  request interception, streaming traces, queuing, and backpressure. Both
  projects are passive usage monitors. Neither sits in the request path, and
  llm-monitor has no broker or proxy.

### Corrections to the issue's citations

The issue body was written from glideslope's README. The code differs from that
summary in two places that matter for this comparison:

1. **The pool is not a sum of caps.** The README says "the sum of all those
   accounts' 7-day limits is the pool". `claude_pool()` computes two
   **unweighted means** over the largest group of accounts on the same plan:
   `used = Σ usedᵢ / n` and `◆ = Σ phaseᵢ / n`. For equal caps this equals
   total spend divided by total cap, so the README is not wrong. But the code
   deliberately refuses to mix plan sizes: a Pro account "sits out rather than
   diluting two Max 20x budgets". A separate `total_pool()` does mix providers.
   It weights each account by its **monthly subscription price**
   (`PLAN_PRICE_USD`), not by its cap.
2. **The API-equivalent overlay is not computed by glideslope.** The ledger
   figure ("$14,885 API-equivalent on $600/mo") is read from an optional
   `<store>/spend.json`, and the README says its producer "is not part of this
   repo". The only pricing code in the repo is `SHADOW_PRICES` / `shadow_cost()`.
   It is a small static table of per-1M-token (input, output, cache-read) list
   prices, and it feeds only the OpenRouter-harness "≈ API" column.

## 1. The glide-slope position metric: adopt, adapted (#220)

**What glideslope does.** `even_pace_percent()` computes
`100 · (1 − (resets_at − now) / window)`, clamped to [0, 100]. It returns `None`
when the reset or duration is unknown, or when the reset has already passed.
That value is where an even burn would put `used` right now. Every surface
shows `used` against it:

- The CLI cell reads `62% (◆ 48%)`.
- The approach plot uses x = % of window elapsed and y = % used, with a dashed
  y = x reference line.
- The register shows a signed deviation such as `+66%`.

Two details are worth keeping:

- **A stale reading gets no mark.** glideslope treats a stale value as a floor,
  not a position. The one exception is a "presumed" zero after a rollover, whose
  clock is known.
- **Banking counts as news.** Below the mark means capacity that will expire at
  the reset. glideslope ranks accounts by slack (`pace − used`) against each
  account's own mark (`best_alternative()`), not by raw percent.

**What llm-monitor has.**

- `PercentSeverity` bands raw percent (>95 critical, ≥90 warning).
- `UsageChartView`'s `.percent` mode plots raw percent against wall-clock time.
- `sortedAccountsForPopover` ranks by `max(session, weekly)` raw percent, with
  reset time as the tiebreak.

Nothing in the codebase computes elapsed-normalized position. A search for
pace, elapsed, or even-burn logic finds none. So 60% at hour 4.5 of a 5-hour
session and 60% at hour 1 look identical here, although the first is on track
and the second will hit the cap in about 40 minutes.

**The inputs already exist.** Every `RateLimitWindow` carries `resetAt` and
`durationSeconds`. Anthropic's kind-labelled windows get `durationSeconds` from
`kind.nominalDuration`. Codex, Codex snapshots, and z.ai supply their own. The
metric is a pure function of data llm-monitor already stores.

**Recommendation: adopt the metric, adapt the presentation.** #220 has the
details.

- **`RateLimitWindow.swift`** (portable core): add `evenBurnPercent(at:)` and
  `slack(at:)`. Both return nil rather than 0 when the metric is unknown, which
  follows the "omitted, never zeroed" rule used everywhere else here.
- **`UsagePopoverView.swift`**: show a mark beside each percent. Hide it under
  the existing `AccountFreshness.shouldSuppressPercent` rule, which is our
  version of glideslope's "a floor gets no pace".
- **`UsageChartView.swift`** (`.percent` mode): draw a dashed even-burn line for
  each window instance, from (window start, 0) to (reset, 100), on the existing
  time axis.
- **`PercentSeverity.swift`: no change.** Severity stays a function of raw
  percent. The mark is a separate visual channel, the same rule the #199
  calibration dot follows. Folding pace into the three-band palette would make
  "92% at hour 4.9" and "92% at hour 0.5" the same color, and that is exactly
  the distinction the metric exists to show.

**Adaptations, and why:**

- **The approach plot's x-axis is declined.** It is built to put many accounts'
  windows in one scatter. The llm-monitor chart shows one account's history over
  wall-clock time, and a reference line on that axis carries the same
  information without the learning curve glideslope's own README warns about.
- **Ranking by slack is deferred, not adopted here.** `sortedAccountsForPopover`
  drives the menu bar auto-pick. `RankingExporter` status feeds loom-daemon's
  token selection. Changing the ordering changes which account the fleet is
  handed, so it needs an operator decision. #220 records it as explicitly out of
  scope. glideslope's case for it is sound: 40% on day one is closer to the wall
  than 40% on day six.

## 2. Credential posture: already converged, nothing to change

glideslope's `SECURITY.md` invariants map almost one to one onto rules
llm-monitor already enforces:

| glideslope invariant | llm-monitor equivalent |
|---|---|
| 1. No credential store of its own | Claude tokens are **read, not owned** (`ClaudeTokenFiles.swift`, minted outside the app). Codex holds no credential at all (`CodexAppServer.swift`). |
| 2. No token is minted; never refreshes Claude or writes the keychain | Same for rolled Claude tokens since the 2026-09-26 leak response. |
| 3. Codex is read through the app-server protocol; tokens are never read, copied or refreshed | `CodexAppServerClient` (`codex -s read-only -a never app-server`). Loom-owned profiles are read from rollout `rate_limits` snapshots only (`CodexProfiles.swift`). |
| 4. Static keys stay static | z.ai keys (`ZaiAPI.swift`), stored like Anthropic tokens and never logged. |
| 6. Nothing credential-bearing crosses machines (beacons carry numbers and emails) | **Divergence:** `accounts push`/`pull` deliberately moves credentials between hosts. It streams over ssh stdin/stdout so no plaintext file exists at either end (#188). This is a conscious difference in scope (fleet provisioning), not an oversight. |
| 7. Failed reads are not retried in a loop | Poll cadence plus the staleness backstop (#148). |

glideslope has one scoped exception: it refreshes the Grok Build session in
place. llm-monitor has no Grok provider, so there is nothing to compare.

Two independent projects reached the same rules for the same reason: a
monitor must never become a second writer of another program's rotating
credential. This validates `ClaudeTokenFiles.swift` and `CodexAppServer.swift`
as designed. **No change.**

## 3. Multi-account pooling: different purpose, one optional idea (in #220)

| | glideslope `claude_pool()` | llm-monitor `QuotaCalibration` pool scope |
|---|---|---|
| Question answered | Is the fleet ahead of or behind its combined even-burn pace **right now**? | What does one weekly point cost, in tokens and list-price dollars, **per day**? |
| Math | mean `used` vs. mean phase, over the largest same-plan group, ≥2 accounts | `points_consumed` summed across accounts, with `accounts_reporting` and `points_per_account` because the denominator moves (19 → 15 → 19 → 20) |
| Unequal plans | Excluded (`claude_pool`), or price-weighted across providers (`total_pool`) | Not distinguished. Every reporting Anthropic account counts equally. OpenAI is excluded outright. |
| Staleness | Pool is marked a *floor* if any member is stale, and a floor below the mark is `undecided` | Freshness is handled upstream. Calibration works on stored history deltas. |

The two do not overlap. The calibration pool is a cost series and should stay
one.

**What glideslope suggests for presentation.** llm-monitor has no live pooled
row. The popover lists about 20 accounts, but no single figure says whether the
fleet as a whole is burning too fast. glideslope's pooled mark (mean used vs.
mean phase) is cheap to compute from `latestUsage` once #220's
`evenBurnPercent` exists. Its two safety rules port directly:

- a stale member makes the pool a floor;
- mixed plan sizes must not be averaged.

It is recorded in #220 as a natural follow-on, **not** part of that issue's
scope.

**A caveat, not an action.** glideslope's equal-plan rule points at an
assumption in `points_per_account`: every account's point is the same size.
That holds for today's all-Max fleet. `accounts.plan` exists in the schema but
is mostly NULL, so the calibration cannot detect a mixed-tier pool. No issue is
filed, because there is no mixed-tier fleet today. It should be revisited if
one appears.

## 4. Token-cost overlay: llm-monitor's model is the more rigorous one

| | glideslope | llm-monitor `QuotaCalibration` |
|---|---|---|
| Where it is computed | Mostly **outside the repo**: `spend.json` comes from an external collector, and glideslope only renders it. In-repo `SHADOW_PRICES` covers only the OpenRouter-harness "≈ API" column. | In-repo: transcript ingest (`TranscriptImporter`), then `recompute`, then `quota_calibration_daily` |
| Price terms | (input, output, **cache-read**) per 1M tokens. No cache-write term. | input, output, cache-write (1.25×), cache-read (0.1×), **priced per model while the model is known** (`TokenAggregate`) |
| Price versioning | One undated-in-code table ("read 2026-08-06" in a comment) | Dated `CostWeights` table. `version` is stamped on every row, and a new table is added on re-pricing rather than the old one edited. |
| Unknown model | Renders "—" | Priced at Sonnet-class fallback **and reported** |
| Headline figure | API-equivalent $ vs. $/mo of plans ("24.8×"), and a per-meter "$ / 1%" | `cost_usd_per_point` and `raw_tokens_per_point`, per day, pool and per-account, with step-change alerts (#199) |

glideslope's per-meter **"$ / 1%"** is the same idea as `cost_usd_per_point`.
That is a second independent arrival at the figure, which validates the design
choice. glideslope's version divides the spend in the current window by the
current percent. Ours is a daily series built from history deltas that handles
resets explicitly. Neither technique fills a gap in ours.

**Considered and declined:** a leverage figure (list-price value divided by
subscription fee). It would need a per-account plan price, which is
operator-declared data llm-monitor does not reliably hold (`accounts.plan` is
mostly NULL). It also has no downstream consumer: rjwalters/loom#8063 consumes
cost-per-point, not leverage. It is a presentation nicety with no current
reader.

## 5. Surface coverage: an existing differentiator

glideslope ships two surfaces, a terminal table and self-contained HTML pages
opened in a browser. Its README says: "a menu bar, a side panel, a dashboard
cell: not shipped … we would take the pull request."

llm-monitor already has that surface: a native macOS menu bar app with a
popover table, a per-account chart window, and a calibration badge. It also has
a surface glideslope has no equivalent for: a **headless Linux daemon**
producing `usage.db` and `ranking.json` for loom-daemon to consume. These are
existing differentiators, not gaps. **No action.**

(glideslope does have a surface we lack: an agent skill that relays usage
mid-task. Loom agents already get ranking through `ranking.json` and
`loom-tokens check --ranking`, so it is not recommended.)

## Also noted: a missing bound in the time-to-limit estimate (#221)

glideslope's `exhausts_at()` returns "does not exhaust" whenever the projected
instant lands at or after the window's reset. llm-monitor's
`UsageChartWindow.estimateTimeToLimit()` has **no reset comparison at all**. A
steep session burn can make it print "limited in ~2 days due to session limits"
for a 5-hour window that resets in minutes. Filed as #221 (scope: bound the
projection by the reset; keep the existing regression).

## Adoption summary

| Candidate | Verdict | llm-monitor files | Tracking |
|---|---|---|---|
| Even-burn position (◆ mark) | **Adopt, adapted** | `RateLimitWindow.swift`, `UsagePopoverView.swift`, `UsageChartView.swift` (not `PercentSeverity.swift`) | #220 |
| Rank accounts by slack instead of raw percent | Deferred (needs an operator decision, changes loom-daemon's input) | `UsageStore.swift` (`sortedAccountsForPopover`), `RankingExporter.swift` | Out of scope in #220 |
| Pooled fleet mark | Optional follow-on to #220 | `UsagePopoverView.swift`, `RateLimitWindow.swift` | Noted in #220 |
| Bound time-to-limit by reset | **Adopt** (bug fix surfaced by comparison) | `UsageChartView.swift` | #221 |
| Credential invariants | Already converged | none | none |
| Plan-aware calibration pool | Caveat only, no mixed-tier fleet today | `QuotaCalibration.swift` | none |
| List-price leverage figure | Declined (no plan-price data, no consumer) | none | none |
| Menu bar surface | Already shipped here (differentiator) | none | none |

Beyond the glide-slope metric and the #221 fix it surfaced, **no other adoption
candidates were found.**
