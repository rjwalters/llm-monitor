# `merge-pr.sh` exit codes 3, 4 and 5 — the three "not a failure" outcomes

`merge-pr.sh` reserves three exit codes for outcomes that look like failures to
a naive `|| handle_failure` caller but are not: the merge did not happen,
nothing is wrong, and the correct response is to re-queue the PR for a later
pass.

Champion's operative handling lives in
`.claude/commands/loom/champion-pr-merge.md` →
"Exception: exit codes 3, 4 and 5". This file holds the rationale, the design
decisions behind it, and the forensics notes — the parts a Champion session
does not need loaded to act correctly.

| exit | cause | who moved the head |
|---|---|---|
| `3` | The PR's head branch changed between the fresh head-SHA read taken immediately before merging and the merge call itself (#5579). | someone else |
| `4` | The #8248/#8919 required-check freshness guard blocked the merge and `--redate-stale-checks` re-dated the checks with a tree-identical no-op push (#8508). | this run |
| `5` | `--auto`'s bounded settle-wait expired before this head's checks finished, or before the check-runs API became readable (#8896). | nobody |
| `1` | Everything else, including a #8248 block with no remedy left. | — |

## Exit 3 — a foreign push raced the merge (#5579)

`merge-pr.sh` passes the head SHA it read to the forge's merge API as an
optimistic-concurrency precondition. When the branch has moved on, the forge
refuses and the script exits 3 rather than 1: the PR is still Judge-approved,
its diff just moved out from under the attempt. Most commonly a session pushed
new commits to an open, `loom:pr`-labeled branch while Champion was running.

**Diagnostic output.** The script logs to stderr both the stale SHA (the one it
gated the merge on) and the current head SHA, so it is easy to see which
commits raced in. These appear in the `merge-pr.sh` output and the caller's run
log. They are deliberately **not** posted as a PR comment: an exit-3 re-queue is
an ordinary operational event, and commenting on every occurrence would be
noise on a race condition that resolves itself.

## Exit 4 — this run re-dated the stale required checks (#8508)

### What #8248 leaves open

The #8248 required-check freshness guard refuses a merge whose green required
checks started before the base branch's current tip: that result is evidence
about a tree that no longer exists. The guard is correct — it exists because a
ratchet baseline tightened under an in-flight PR and red-lined `main` on
2026-09-18 — and this remedy does not weaken it in any path.

What it left open is that **nothing in the fleet produces the fresh evidence it
waits for.** On 2026-09-21, PR #8493 failed three consecutive Champion merge
ticks with the identical refusal:

- its branch had no new commits, so no CI run ever re-dated its checks;
- `main` kept advancing, so each retry compared against an even later tip;
- `merge-pr.sh`'s internal re-run and a direct `gh run rerun` both failed with
  `Resource not accessible by integration` — the merge token has no
  `actions:write`.

The only recorded escapes were a human merging with an elevated token or a
human pushing a no-op commit. Neither happens automatically, so a
Judge-approved, safety-criteria-clean PR could sit blocked indefinitely — and
invisibly, because Champion's rejection-comment idempotency guard suppresses
the repeated identical failures, leaving no durable record on the PR at all.

### Why an in-place re-run is NOT the first choice (#8914, withdrawn by #8919)

#8914 re-ran, in place, every GitHub Actions workflow run holding a stale
required check (`POST /repos/{o}/{r}/actions/runs/{id}/rerun`). The attraction
was that the head SHA does not move, so the stale-verdict guard (#5686) has
nothing to react to and `loom:pr` survives — unlike the push below, whose head
move costs a full Judge re-review for a byte-identical tree (PR #8909,
2026-09-25).

**It was withdrawn in #8919 because a re-run does not re-test against the new
base.** GitHub re-runs a workflow run with the same `GITHUB_SHA` as the original
event, and for a `pull_request` run that SHA is the test merge commit GitHub
built when the event fired — built on the OLD base. Verified 2026-09-25 on run
36145858487 (PR #8692), job `File Size Ratchet`:

| attempt | job started | checkout log |
|---|---|---|
| 1 | 14:12:11Z | `HEAD is now at cb7c91f Merge 162b0f05… into 803f0c7d…` |
| 7 | 16:26:47Z | `HEAD is now at cb7c91f Merge 162b0f05… into 803f0c7d…` (same commit) |

`main` moved several times between the two attempts. Attempt 7 still tested base
`803f0c7d` from 14:06Z; only its `started_at` advanced. So the re-run satisfied
#8248's time rule without re-validating anything: #8078's `File Size Ratchet`
would have been re-run against the merge commit that still carried baseline
1845, passed, and merged onto 1815. A manual `gh run rerun` before
`merge-pr.sh` has the identical problem. **An in-place re-run does not keep a
verdict valid; it only moves a timestamp.**

Two consequences:

- **`redate-checks` goes straight to the push below.** `--rerun-wait-secs` and
  `LOOM_REDATE_ALLOW_PROCEED` are still accepted and do nothing, and exit **5**
  is never returned. `merge-pr.sh` is frozen by the file-size ratchet and still
  carries its exit-5 arm; that arm is simply unreachable with a current binary,
  and is what keeps an older one working mid-rollout.
- **`Actions: write` is no longer what this needs.** The push path runs on the
  `contents: write` the script already uses, so withholding Actions: write no
  longer costs a PR its Judge verdict.

A cheaper required-checks workflow would not have helped either: a faster re-run
is still a re-run of the stale merge commit. #8919's remedy is instead to stop
counting *unrelated* base moves as staleness at all — the input-scoped
predicate in `loom-daemon/src/merge_pr/stale_checks/inputs.rs`, keyed on the
base each check actually tested.

### Fallback: the tree-identical push (#8508)

`--redate-stale-checks` makes `merge-pr.sh` perform the remedy the guard's own
refusal text names (push any no-op commit, so a new `pull_request` event
rebuilds the merge commit against the current base). `loom-daemon merge-pr redate-checks` creates a commit pointing at the
**same tree** as the current head with the current head as its only parent, and
fast-forwards the branch ref onto it through the Git Data API (`git/commits` +
`git/refs/heads/<branch>`) — no local clone, matching `merge-pr.sh`'s
worktree-safe, API-only discipline. Pushing to the head branch re-triggers
every `pull_request` workflow, which is the fresh evidence #8248 asks for.

It needs no new token grant: the same `contents: write` that `merge-pr.sh`
already uses to sync a base branch into a head branch covers it. Since #8919 it
is the ONLY remedy — the re-run above cannot produce fresh evidence at all.

Properties worth stating explicitly, because they are what make this a remedy
rather than a bypass:

- **The diff does not change.** The new commit reuses the current tree
  byte-for-byte, so nothing about what Judge reviewed is altered.
- **No evidence is fabricated.** Nothing asserts a check passed; CI runs for
  real against the new head, and the next merge attempt still has to satisfy
  #8248 on its own terms.
- **It is opt-in.** Without the flag, `merge-pr.sh` behaves exactly as before
  — a human merging by hand never has a commit pushed onto a branch by
  surprise. Champion passes it; nothing else does by default.
- **It never runs on an unknown.** The guard's fail-closed exit (freshness
  undeterminable) does not trigger the remedy — only a positively STALE
  verdict does. `--dry-run` never writes.
- **The head move is honest.** It invalidates the standing Judge approval
  (#5686), exactly as any other push does, so the PR cycles back through
  `loom:review-requested` before merging. That re-review is the correct cost,
  not a regression.

### The bound, and why there is one

If CI on the re-dated head takes longer than the interval between merges on
`main`, the guard is stale again the moment it finishes. An unbounded remedy
would push a fresh no-op commit every tick forever, burning a full CI run and a
Judge re-review each time while never out-racing the base branch.

So the remedy is bounded to **one push per head**. Each push records

```
<!-- loom:stale-check-redate to=<new-sha> -->
```

on the PR. Finding that marker for the *current* head means the full re-date →
CI → block cycle already completed with no forward progress, which is a
strictly stronger signal than a tick counter (and needs no process to own the
count — it is durable forge state).

### Escalation when the bound is reached

The PR is escalated the same way `champion-pr-merge.md`'s merge-risk hold
escalates:

- one idempotent notice keyed on the blocked head
  (`<!-- loom:stale-check-hold head=<sha> -->`), so a later push re-opens the
  question with a fresh notice rather than being silenced by the old episode;
- the `loom:operator` label — the first-class "engine will not act further, a
  human is the only transition out" state (#5502).

`merge-pr.sh` then returns the ordinary exit **1** with the original #8248
refusal: the merge is still refused, and the PR is now simply a held PR that
every `loom:operator` consumer already handles.

**Release** is a human act, by design, and there are two:

1. merge it directly with a token carrying elevated merge permission; or
2. push any commit to the branch (or rebase it) — that rebuilds the merge commit
   against the current base, re-runs every required check against it, and
   returns the PR to the normal Judge → Champion path. Re-running the existing
   checks in place is NOT one of the options: see #8919 above.

Remove `loom:operator` once you have acted. Nothing removes it automatically:
the label is what makes the stuck PR visible and keeps the engine from
re-litigating a state it has already proven it cannot resolve.

## Exit 5 — CI outlasted `--auto`'s bounded settle-wait (#8896)

Since #8410, `--auto` does not arm the forge's server-side queue: it waits, in
this process, for the head's checks to settle (`LOOM_AUTO_MERGE_TIMEOUT`,
default 600s, polled every `LOOM_AUTO_MERGE_POLL_INTERVAL`), re-validates the
guards, and merges here. When the wait runs out, the run ends without merging.

That is the same shape as exits 3 and 4 — nothing merged, nothing is wrong, try
again later — but until #8896 it left through `error()`, i.e. exit **1**, which
is indistinguishable to a caller from "the merge API refused this PR".
Champion's "Merge Failed" path therefore posted *"a human will need to
investigate and merge manually"* on a PR whose only problem was that CI was
still running. On this repo `Shell Test Suites (hermetic)` alone takes about ten
minutes against a 600s default, and the pass right after an exit-4
`--redate-stale-checks` re-run starts CI from scratch, so the timeout is
routinely reachable rather than exotic.

Two sites exit 5, both inside `_wait_for_checks_then_sync_merge`:

- **pending checks at the deadline** — one or more non-skipped check-runs on
  this head are still `queued`/`in_progress`;
- **an unreadable check-runs API at the deadline** — every poll's fetch failed
  (and not with the confirmed-404 streak that means "this repo has no checks",
  which short-circuits to the merge instead).
  A persistently **truncated** read (#8895: fewer rows than the forge's own
  `total_count`) is this case too — it is withheld as a failed fetch, so it
  also exits 5 at the deadline, never 0 and never 1 (#8993).

A third case *reaches* the same deadline without exiting 5 — a check-runs
rollup that is readable but **empty** (zero rows, never once seen non-empty).
It settles and merges (exit 0), because an empty rollup most often means the
repo simply has no CI configured for this commit. #6169 made it re-poll rather
than trust a single empty read, since a degraded forge response looks identical;
#9091 then bounded that re-polling, because "wait out the whole deadline" hit
hardest exactly where the empty read is *genuine*. On a repo with no CI on the
changed paths every poll returns zero rows forever, so every `--auto` merge
there spent the full `LOOM_AUTO_MERGE_TIMEOUT` before merging — long enough
that the calling agent's own process cap killed it first, which is how
a private fleet repo's PR (2026-09-26; full timeline in rjwalters/loom#9091) got
a "Proceeding with squash merge…" comment and then no merge, no failure and no
label change. The bound is conditional on the base
branch's **required** status-check set:

- **no required contexts** → settle after `LOOM_ZERO_CHECKS_SETTLE_POLLS`
  (default 3, spaced `LOOM_ZERO_CHECKS_SETTLE_INTERVAL`, default 5s — about 10s
  of grace for a check-run that is merely slow to *register*). The poll count is
  floored at 2, so no operator value can restore the single-read settle #6169
  fixed; and a wrongly-empty read here can at worst skip *informational*
  checks, which this path already merges over by design (#3486).
- **required contexts present, or the lookup errored** → the full wait stands
  unchanged. A required context that has not registered yet is a gate that
  *can* block, and an unreadable protection lookup is not evidence of its
  absence.

That decision — including the two knobs, their floors, and the two-source
required-context lookup it shares with the #8248 freshness guard — is
`loom-daemon merge-pr zero-checks-settle`
(`loom-daemon/src/merge_pr/zero_checks.rs`). `merge-pr.sh` consults it on every
zero-row poll and obeys the sentinel it answers with; it holds no copy of the
rule. A daemon too old to know the verb (or missing entirely) produces no
sentinel, and the script then falls back to #6169's full deadline-bounded wait —
the state this narrows, so a fault there costs time and never skips a gate. It
cannot degrade into settling on a single empty read.

What exit 5 deliberately is **not**:

- **Not a failed check.** A failing *required* check still exits 1 — that is
  evidence about this head, not a timing accident, and it needs a fix, not a
  retry. Failing *informational* checks with nothing pending still merge
  (#3486).
- **Not a head move.** Nothing pushed, so the standing `loom:pr` verdict is
  untouched and the next pass re-evaluates the same head with more of its CI
  finished. Exit 3's #5686 caveat does not apply.
- **Not a bypass.** The wait is the gate; expiring it merges nothing.

The remedy, if a repo hits it every pass, is configuration rather than a PR
action: raise `LOOM_AUTO_MERGE_TIMEOUT` past the repo's slowest suite (or
shrink the required set). A Champion tick that ends in exit 5 should
cost nothing but a log line.

## Merge-ancestry detection trap (applies to all three)

If you need to verify by hand whether a re-queued PR's commits actually landed
or were silently stranded, `git merge-base --is-ancestor <commit> origin/main`
is **not reliable evidence for a squashed merge**: a squash merge produces a
brand-new commit SHA on `main` that is not a git-ancestry descendant of any
commit on the original PR branch, regardless of whether that commit's content
made it into the squash. Loom's default is now merge commit (#9105), under
which the PR branch's commits ARE ancestors of `main` — there the ancestry
check works as expected. For a squashed PR (or on any repo configured
squash-only), there is no cheap ancestry check for "squashed-and-landed" vs.
"stranded" — verification requires diffing the actual file content on `main`
against the branch or commit in question.
