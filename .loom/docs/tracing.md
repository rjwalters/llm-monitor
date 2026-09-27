# Execution traces

Loom's opt-in OTLP exporter carries completed spans alongside lifecycle logs and
metrics. Trace IDs and span IDs are native OTLP fields, so a backend can join a
log to its exact execution span. Enable the `otlp` Cargo feature and configure
`observability.enabled`, `exporter: "otlp"`, an endpoint, and an ingest key file
as described in [observability](observability.md).

## Identity and process boundaries

No trace or span ID is random; the derivations and the provenance every span
carries are policy: [trace identity](trace-identity.md). An issue
number never identifies an execution: retries and restarts of one issue are
distinct executions, each with a root span ID derived from its sweep id. An
issue sweep's trace ID, however, is its issue's **story trace** (#9037), keyed
per harness-ops D32 v1 (#9068): trace ID and story root span ID are
SHA-256-derived from `loom-story/v1:github:<repo_id>:<issue>`, where `repo_id`
is GitHub's numeric id for the checkout's `origin` (resolved once per repo and
cached), so every sweep of the issue, on any host and across renames, lands in
one trace, parented to the story root and tagged `loom.issue`, `loom.repo`,
`loom.story_id`, `loom.story` (`owner/repo#n`) and `loom.story.key_version`
(`v1`). Completed CI runs of the issue join the same story as `loom.ci.run` /
`loom.ci.job` spans (#9088; see
[ci-observability](ci-observability.md#story-stitching-9088)). The story root
span itself is emitted when the story ends (a later phase of #9037); until
then backends show it as a missing parent. Executions outside an issue, in a
checkout with no GitHub `origin`, or whose `repo_id` cannot be resolved
(warned once per repo) get their own deterministic trace derived from the
repo key and sweep id — never a random one. Before an owned sweep process is
spawned, Loom persists its root identity under `.loom/logs/trace-context/` and
passes `LOOM_TRACEPARENT` plus `LOOM_TRACE_CONTEXT_FILE` to that child. Reopening
the same execution after a daemon restart reuses its identity. A new attempt
gets a new execution identity. The parser accepts strict W3C version-00 context;
it rejects malformed, uppercase, and zero IDs.

The context directory is private and files are written atomically with fsync.
An exclusive file lock serializes creators. A corrupt, busy, or full context
store disables tracing for that launch with a diagnostic instead of delaying
issue execution. The store admits at most 1024 active executions. Terminal
instrumentation must successfully call `DurableQueue::push_durable` for the
completed root before removing its context;
unfinished work retains its identity across restart. This propagation hook does
not imply that arbitrary third-party harness tools emit spans.

## Delivery and privacy

Completed spans enter the same bounded durable queue as other telemetry. Only
sampled, valid spans are exported. Span names are a fixed enumeration; attributes
are allowlisted, length bounded, and exclude prompts, source, tool arguments,
command output, environment values, headers, and credentials. Links and events
are bounded. No prompt or tool payload capture is enabled.

Span envelopes use schema version 3. Existing lifecycle envelopes remain version
2 with an optional trace context. Old queue records still decode. The native
HTTPS backend receives lifecycle envelopes with context stripped and never
receives trace-only records; use OTLP for traces.

Graceful daemon signal and IPC shutdown gives registered senders one shared
two-second final-drain budget. Export failure or timeout leaves unsent records
on disk. An in-flight send is allowed to commit its acknowledgment before the
remaining queue is drained; expiration cancels it without immediately replaying
the same batch. SIGKILL cannot flush and relies on persistence. Shutdown does not
manufacture completion for active execution spans. Delivery can duplicate an
accepted request when the sender loses the response; no exactly-once claim is
made. An interrupted multi-signal request can also lose a not-yet-committed
acknowledgment and replay on restart. Trace IDs allow backend correlation, not
universal backend deduplication.

## Implementation boundary

The foundation defines persistence, propagation, encoding, and shutdown; the
owned lifecycle boundaries below add execution instrumentation. The two-backend
acceptance trial is tracked in issue #8529. Exported synthetic fixtures establish
transport behavior; live lifecycle acceptance requires the native workload too.

## Owned lifecycle instrumentation

Sweep dispatch persists the root before spawning, including the failed-spawn
path. Independent scheduled roles receive independent roots, and join stories
after the fact (below). Rust worker launches
record preflight and runtime spans; a rejected preflight does not create a runtime
span. Pi and OpenCode receive the validated context through their environment,
and the shared native read/write/edit/bash bridge records tool name and outcome.
There are no spans for model HTTP requests or hidden third-party CLI operations.
Resolved provider/model identity is distinct from a configured model alias.

Phase timing has two explicit forms. An explicitly launched role has an observed
start; its checkpoint completes that attempt. A role performed inside one
third-party CLI session has only an observed checkpoint completion, represented
as a zero-duration phase/role span. `loom.timing_source` distinguishes these from
legacy polling observations. Checkpoint writes preserve repeated Judge rejections,
Doctor completions, and subsequent Judge approvals even between daemon polls.
The terminal checkpoint helper journals after its atomic write succeeds. It does
not infer an earlier start or a missing verdict. A caller that bypasses that
helper can provide only the phases that the daemon actually observes.

`loom.role_attempt` spans have distinct IDs for retries. Explicit checkpoint
attempt numbers are retained. Unknown usage remains absent; measured zero stays
zero. Outcome logs include existing grouped usage, failure classification, ordered
Judge verdicts and Doctor counts. Grouped usage inherits the source journal's
attribution window and is not a measured provider bill. Free-form role error text,
configuration blobs, prompts and account contents are not exported.

## Role-runner ticks join stories after the fact (#9168)

A role-runner tick (Judge, Curator, Champion, Doctor, …) is spawned without a
target, so its `loom.role_attempt` root is its own trace. Once the tick ends,
the same transcript pass that tallies `role_tick.outcome` `actions` also
collects the issues and PRs the tick **wrote** to: `gh issue|pr
comment/edit/close/reopen/…`, `gh pr merge|review|ready`, `merge-pr.sh <N>`
(not `--dry-run`), and `gh api` `POST`/`PATCH`/`PUT`/`DELETE` on
`repos/<o>/<r>/{issues,pulls}/<N>/…`. Reads (`view`, `list`, `diff`,
`checks`, `GET`) never count; a command naming another repository (`-R`,
URL, explicit API path, `GH_REPO`) or run after a `cd` out of the tick's
checkout is refused, and one whose repository cannot be told (`cd $DIR`,
`GH_HOST`, `GIT_DIR`) yields nothing (#9180); a branch name or `$VAR` names
nothing. Here-document bodies — also `cat<<EOF` and the
`--body "$(cat <<'EOF' … EOF)"` form — are never parsed as commands.

Each distinct target gets one additional `loom.role_attempt` span in its story
trace, parented to the story root (`story_context(repo_id, N)`). One batched,
cached (10 min) GraphQL `issueOrPullRequest` lookup says whether
the number is an issue — its own story — or a PR, which joins a story by the
CI stitcher's rule: exactly one same-repo closing issue, counting the
`feature/issue-N` head branch. Zero or several candidates, a foreign closing
reference, a failed lookup, or an unresolvable `repo_id` → no story span.
The whole lookup — `repo_id` included — shares one 20 s deadline per tick, and
a failed or rate-limited lookup is not retried for that repository for 60 s. The
span id is derived from the story root, `loom.role_tick`, the tick's execution
id (`loom.sweep_id`) and the target (`pr:<M>` / `issue:<N>`), so a re-emit
yields the same id. It carries `loom.role`, `loom.issue`, `loom.pr_number`
(PR targets), `loom.story`, `loom.story.key_version`, `loom.repo`,
`loom.result`, `loom.runtime`/`loom.model` when known, and
`loom.timing_source=tick` — its start and end are the whole tick's, not the
individual action's — plus a link to the tick's own root. The spans are
appended to the tick's trace journal and drained like every lifecycle span.
All of this is best-effort after the tick's child has exited; it never fails
the tick. Non-Claude runtimes record no transcript actions, so their ticks
join no story yet.

## Journals and recovery

Workers append bounded records to per-execution journals under
`.loom/logs/trace-context/`; they never open the daemon's export queue. Starts and
completions use an exclusive file lock and fsync. Writer contention retries for
at most one second before a fixed diagnostic; the lock wait is bounded.
Backfill releases the append lock before queue/cursor I/O. Each journal is capped at 16 MiB,
each entry at 32 KiB, and attributes retain the foundation's 256-byte value bound.
The daemon backfills completed spans using a byte cursor, advancing it only after
`push_durable` succeeds. A truncated final entry remains unread by backfill. The next locked writer
truncates only that incomplete tail, logs recovery, and preserves every complete
record before accepting new work. Queue failures
retain the cursor and context. After every child and root completion is durably
queued, the daemon retires that execution's context and journal.

The queue remains bounded: its existing drop-oldest policy and drop counter still
apply under sustained overload. A crash between queue persistence and cursor
persistence can replay a span with the same IDs. Backends may retain duplicate
rows; count distinct execution/trace identities when comparing accepted issues.

Parent process completion, cancellation and reaping close observed work. An exit
that Loom could not observe stays `exit_unobserved`; it does not inherit a
successful sweep result. A separately persisted supervisor identity protects
execution results between worker exit, reaping, and independent verification.
Lock-based restart adoption renews that supervisor using the authoritative sweep
ID before exposing the registry to telemetry. Recovery checks identities and
records completion under the same journal lock as supervisor transfers, so a
stale recovery snapshot cannot override adoption or a terminal result.
Recovery closes orphaned work only when all recorded worker and supervisor
identities are demonstrably gone, labels the observation, and leaves execution
status unknown. On Linux, an owner observation timestamp also lets Loom reuse its
existing process-start identity check to recognize a recycled PID. This clock is
updated when ownership transfers to the actual child, independently of phase
start time. Older journals without that clock, unsupported process-start probes,
and container PID namespaces remain conservative; authoritative parent/reaper
observations remain necessary. Root IDs
remain separate for identical issue numbers in different repository roots.

Persistence has a measurable cost. Loaded-host fixtures measured 100 durable
start/completion pairs in 11.12 and 18.63 seconds, about 111–186 ms per span,
excluding export. These are observed test-host results, not production latency guarantees. Measure
on the deployment filesystem and include this cost when evaluating a model run.

When upgrading lifecycle instrumentation, refresh the gateway deployment’s
`config.yaml` from `defaults/observability/collector/config.yaml` and recreate
only that Collector service, retaining its persistent queue directory. The
updated log allowlist preserves measured token/line counts, ordered Judge
verdicts, and bounded runtime/provider/model experiment settings. An older
gateway drops those additional fields even though Loom exports them.

The Rust checkpoint port requires a binary built with #8525. Its declared
`0.19.255` minimum is the development baseline, not a claim that the published
release with that number contains the command. Until the first containing
release is identified, pin a verified matching build and check
`loom-daemon sweep-checkpoint --help` before using the shell helper. Missing or
older binaries remain operational failures, never evidence of a missing
checkpoint; do not mark this dependency optional.
