import Foundation
// `kill` / `SIGKILL` are POSIX, not Foundation: Linux's swift-corelibs-foundation
// does not re-export them, so the platform module has to be imported explicitly
// for the headless build (same reason `SubprocessIO.swift` does).
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Loom's **live** Codex availability check, read as a freshness source for the
/// pooled profiles `CodexProfiles` otherwise only ever sees through rollout
/// snapshots (#230).
///
/// ### Why a live reading is allowed here when a direct one is not
///
/// `CodexProfiles`' header explains why this app must never spawn `codex`
/// against a Loom-owned `CODEX_HOME`: OpenAI rotates the refresh token on every
/// use, exactly one process may refresh a given home, and for a session-managed
/// profile that process is its session container. That rule is unchanged, and
/// the three guards that enforce it (`pollOpenAI` → `pollCodexSnapshot`,
/// `OAuthPoller.isLoomCodexProfile`, `codex list`) are untouched.
///
/// What changes is *who* asks. `loom-daemon accounts check --live` probes each
/// account **from inside its own session container** (ADR-0017) — the one
/// process that already owns that home's refresh chain — and prints the numbers
/// it measured. This app spawns `loom-daemon`, not `codex`; it reads no
/// `auth.json`, holds no bearer, and writes nothing into any profile. The
/// credential-ownership boundary is the same one `CodexProfiles` draws, honoured
/// by asking the owner instead of going around it.
///
/// The price the snapshot path pays is freshness: a rollout reading is only as
/// current as the account's last Codex turn. A live reading is as current as the
/// probe. So the live result is preferred **only when it is newer** than the
/// freshest rollout snapshot (`OAuthPoller.pollCodexSnapshot`) — never
/// unconditionally, because an unconditional preference would let a
/// `session_unavailable` host overwrite a good local reading with nothing, which
/// is the failure mode `AccountFreshness` (#148) exists to keep out.
///
/// ### Which registry this asks about
///
/// `accounts check` is scoped to a Loom *workspace*'s account registry, while
/// `CodexProfiles` reads the host-level, workspace-agnostic profile pool
/// (`~/.loom/codex-profiles`). llm-monitor is not a per-repo Loom participant
/// and has no workspace of its own, so it names loom-daemon's **shared,
/// machine-level** registry root — `$LOOM_SHARED_ACCOUNTS_ROOT`, else `$HOME`,
/// whose `.loom/accounts.json` is the shared registry (loom-daemon's
/// `shared_accounts_root()`, mirrored here the same way `CodexProfiles.root()`
/// mirrors `codex_profile_root()`). That is the one scope with the same
/// host-level, repo-independent reach as the profile pool this app reads.
///
/// This deliberately creates no registry and writes no file: when the shared
/// registry does not exist, loom-daemon's `codex_inventory` falls back to
/// *discovering every profile directory in the pool*, keyed by directory name —
/// exactly the set `CodexProfiles.scan()` enumerates. A host that does have a
/// shared registry gets that registry's entries instead, which is the operator's
/// stated intent. Either way this app is a reader: `--ranking` is never passed,
/// so the command is a pure read that persists nothing on the Loom side.
///
/// ### Wire shape (loom-daemon 0.19.503, verified 2026-09-29)
///
/// `accounts check` prints its progress preamble on **stderr** and the JSON
/// document on stdout, in one of two envelopes:
///
/// ```json
/// {"workspace":"…","accounts":[],"ranking_path":null}
/// {"workspace":"…","report":{"ranked_at":"2026-09-29T07:00:00Z",
///   "accounts":[{"name":"agent-1","status":"available",
///     "5h_utilization":0.12,"7d_utilization":0.43,
///     "5h_reset":"…","7d_reset":"…","limit_reset":"…","reset_overdue":false}],
///   "overdue_reset_accounts":0},"ranking_path":null,
///  "marked_exhausted":[],"cleared":[]}
/// ```
///
/// - The empty-pool envelope puts `accounts` at the top level; the populated one
///   nests the whole `ProbeReport` under `report`. Both are accepted.
/// - Utilization is a **0–1 fraction** (loom-daemon's `used_fraction`), not a
///   percent — it is `used_percent / 100` on the Codex side, matching what
///   Claude's `.ranking` carries.
/// - A null utilization is **unknown, never 0**: a row that measured nothing
///   (`not_logged_in`, `session_unavailable`,
///   `rate_limits_unsupported_by_codex_cli`, a disabled account) carries no
///   window at all, and this app falls back to the rollout snapshot for it.
/// - The windows arrive already filed by kind: loom-daemon's `slot_by_duration`
///   files each window by its own `window_minutes` before naming it `5h`/`7d`,
///   so the duration → kind derivation this codebase insists on has already
///   happened upstream. The `window_minutes` figure itself is not on this wire,
///   so each window takes its bucket's nominal duration
///   (`RateLimitWindowKind.nominalDuration`) — the same thing this app already
///   does for Anthropic's kind-labelled `5h`/`7d` header families.
/// - A window whose reset instant has already passed is dropped as unknown,
///   never carried forward — the identical rule `CodexProfiles` applies.
///
/// Portable core: no AppKit / SwiftUI / Combine / os.Logger — builds on Linux.
enum LoomAccountsCheck {
    // MARK: - Binary resolution

    /// Explicit override, and the seam `selftest` points at a stub binary.
    /// Mirrors `LLM_MONITOR_CODEX_BIN` / `LLM_MONITOR_SSH_BIN`, for the same
    /// reason: `/usr/bin/env` resolves against launchd's minimal `PATH` in a
    /// Finder-launched bundle and finds nothing.
    static let overrideEnvKey = "LLM_MONITOR_LOOM_DAEMON_BIN"

    /// Absolute fallbacks probed after `PATH`. `~/.local/bin` first because that
    /// is where Loom's own installer puts the binary.
    static let fallbackDirectories = [
        "~/.local/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
    ]

    /// First executable `loom-daemon` among: the override, each `PATH` entry,
    /// then `fallbackDirectories`. Nil when none exists — which is the ordinary
    /// state of a host that does not run Loom, and means "fall back to rollout
    /// snapshots", never an error.
    static func resolveBinary(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        if let override = AppPaths.environment("LOOM_DAEMON_BIN", in: environment)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            // A broken override is a configuration mistake worth failing on,
            // not something to paper over with PATH (same rule as CodexBinary).
            return fileManager.isExecutableFile(atPath: override) ? override : nil
        }
        let home = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pathDirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in pathDirs + fallbackDirectories {
            guard !directory.isEmpty else { continue }
            var expanded = directory
            if expanded.hasPrefix("~/") {
                guard let home = home, !home.isEmpty else { continue }
                expanded = (home as NSString).appendingPathComponent(String(expanded.dropFirst(2)))
            }
            let candidate = (expanded as NSString).appendingPathComponent("loom-daemon")
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// The workspace whose account registry this asks about — loom-daemon's
    /// shared machine-level root (see the type doc). An explicitly empty
    /// `LOOM_SHARED_ACCOUNTS_ROOT` disables the shared registry in loom-daemon,
    /// so it disables the live check here too rather than silently naming some
    /// other scope.
    static func workspace(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let value = environment["LOOM_SHARED_ACCOUNTS_ROOT"] {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return nil }
            return (trimmed as NSString).expandingTildeInPath
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// The exact argv, spelled once so the self-test and the poll path cannot
    /// disagree. `--ranking` is deliberately absent: without it the command is a
    /// pure read that writes nothing on the Loom side.
    static func arguments(workspace: String) -> [String] {
        ["accounts", "check", "--provider", "codex", "--live", "--json", "--workspace", workspace]
    }

    // MARK: - Decoded result

    /// One account row from the report.
    struct Reading: Sendable {
        /// The account name loom-daemon reports — a registry entry's name, or,
        /// with no registry, the profile directory's own name. Never a path.
        let name: String
        /// `available` | `exhausted` | `rate_limited` | `blocked` | `error` |
        /// `skipped` | `unknown`.
        let status: String
        /// Why nothing was measured, when nothing was (`not_logged_in`,
        /// `session_unavailable`, `rate_limits_unsupported_by_codex_cli`,
        /// `no_rate_limit_snapshot`, `disabled`, …). Nil on a measured row.
        let detail: String?
        /// When the probe ran: the report's own `ranked_at`. This is the figure
        /// the "is live newer than the rollout snapshot" comparison turns on,
        /// and the timestamp any row written from it carries.
        let observedAt: Date
        /// Whatever windows the probe could measure. Empty is a first-class
        /// state — see `detail`.
        let rateLimit: RateLimitSnapshot

        /// True when this row carries a usable measurement. A row without one is
        /// not evidence about the account and must never displace a snapshot.
        var hasMeasurement: Bool { !rateLimit.isEmpty }
    }

    /// One `accounts check` run.
    struct Report: Sendable {
        /// `ranked_at`, or the read instant when the daemon omitted it.
        let observedAt: Date
        /// Rows by account name.
        let readings: [String: Reading]

        /// The row for a pooled profile directory, matched on the profile's own
        /// name. An exact match first, then a case-insensitive one; anything
        /// else (a registry that renamed the account) simply has no live reading
        /// and falls back to the rollout snapshot, which is always correct and
        /// never stale-overwriting.
        func reading(forProfile profile: String) -> Reading? {
            if let exact = readings[profile] { return exact }
            let lowered = profile.lowercased()
            return readings.first { $0.key.lowercased() == lowered }?.value
        }
    }

    // MARK: - Decoding

    /// Decode one `--json` document. Pure, so `selftest` drives it offline over
    /// a captured fixture the same way `--wire <path>` drives the OpenAI client.
    ///
    /// Returns nil only when the document is not a report at all (unparseable,
    /// or no `accounts` array anywhere). A report with **zero** accounts is a
    /// valid, empty report — a host with no Codex pool is not a failure.
    static func decode(
        _ data: Data,
        fallbackObservedAt: Date = Date(),
        now: Date = Date()
    ) -> Report? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // The populated envelope nests the whole ProbeReport under `report`; the
        // empty-pool envelope puts `accounts` at the top level.
        let container = (root["report"] as? [String: Any]) ?? root
        guard let rows = container["accounts"] as? [[String: Any]] else { return nil }
        let observedAt = UsageRecord.parseISO(container["ranked_at"] as? String) ?? fallbackObservedAt
        var readings: [String: Reading] = [:]
        for row in rows {
            guard let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty else { continue }
            let session = window(
                kind: .session, fraction: row["5h_utilization"],
                reset: row["5h_reset"] as? String, now: now
            )
            let weekly = window(
                kind: .weekly, fraction: row["7d_utilization"],
                reset: row["7d_reset"] as? String, now: now
            )
            let status = (row["status"] as? String) ?? "unknown"
            readings[name] = Reading(
                name: name,
                status: status,
                detail: (row["error"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                observedAt: observedAt,
                rateLimit: RateLimitSnapshot(session: session, weekly: weekly, overallStatus: status)
            )
        }
        return Report(observedAt: observedAt, readings: readings)
    }

    /// One window, or nil when the row carries no usable figure for it.
    ///
    /// Nil covers three distinct "unknown"s that must never read as 0%: a null
    /// utilization (nothing measured), a non-finite/negative one (nonsense), and
    /// a reset that has already passed (the window rolled over, so this reading
    /// describes a window that no longer exists — dropped, never carried
    /// forward, exactly as `CodexProfiles` does).
    private static func window(
        kind: RateLimitWindowKind,
        fraction: Any?,
        reset: String?,
        now: Date
    ) -> RateLimitWindow? {
        guard let used = (fraction as? NSNumber)?.doubleValue,
              used.isFinite, used >= 0 else { return nil }
        let resetAt = UsageRecord.parseISO(reset)
        if let resetAt = resetAt, resetAt <= now { return nil }
        let percent = min(100, used * 100)
        return RateLimitWindow(
            kind: kind,
            usedPercent: percent,
            durationSeconds: nil,  // ⇒ the bucket's nominal length; see the type doc.
            resetAt: resetAt,
            status: percent >= 100 ? "rejected" : "allowed"
        )
    }

    // MARK: - Running the command

    /// How long the whole probe may take before it is abandoned. `--live` fans
    /// out one in-container `codex` probe per account, so this is generous; it
    /// exists so a wedged container runtime costs one skipped refresh instead of
    /// a stuck poll loop.
    static let defaultTimeout: TimeInterval = 120

    /// Spawn `loom-daemon accounts check --provider codex --live --json` and
    /// decode its stdout. Nil on any failure at all — missing binary, spawn
    /// error, timeout, undecodable output — because every one of those means
    /// the same thing to the caller: no live reading this cycle, keep using
    /// rollout snapshots.
    ///
    /// **The exit status deliberately does not gate decoding.** `accounts
    /// check` exits 1 when no Codex account is currently dispatchable, which is
    /// a perfectly good report about a fully-consumed pool — refusing to read it
    /// would blind this app to exactly the accounts an operator most wants to
    /// see.
    ///
    /// `nonisolated` and `async`: it runs off the main actor by construction,
    /// and the wait for the child suspends with `Task.sleep` rather than calling
    /// `Process.waitUntilExit()` (which spins a CFRunLoop and hangs when called
    /// off the main thread — the same rule `CodexAppServerClient.waitForExit`
    /// follows).
    static func run(
        binary: String,
        workspace: String,
        timeout: TimeInterval = defaultTimeout,
        now: Date = Date()
    ) async -> Report? {
        // Nothing is ever written to this child's stdin (it is wired to
        // /dev/null below), so the SIGPIPE trap does not apply here — but the
        // guard is process-wide, idempotent and free, and installing it at every
        // spawn site keeps the invariant one rule instead of a per-site
        // judgement call (#202).
        SubprocessIO.ignoreSIGPIPE()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments(workspace: workspace)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        // Both streams drained concurrently on their own threads: reading one to
        // EOF first would deadlock against a child that fills the other's 64 KiB
        // pipe buffer, and `accounts check` is chatty on stderr.
        let outDrain = PipeDrain(outPipe.fileHandleForReading)
        let errDrain = PipeDrain(errPipe.fileHandleForReading)

        do {
            try process.run()
        } catch {
            await outDrain.finishAndClose(timeout: 1)
            await errDrain.finishAndClose(timeout: 1)
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                try? await Task.sleep(nanoseconds: 500_000_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        // The child is gone (or killed), so both write ends are closed and the
        // drains are about to see EOF. Poll for that rather than blocking this
        // cooperative-pool thread on `waitForEOF()`; once `isFinished` is true
        // the accessor returns without waiting.
        await outDrain.finishAndClose(timeout: 5)
        await errDrain.finishAndClose(timeout: 5)
        guard outDrain.isFinished else { return nil }
        return decode(outDrain.waitForEOF(), fallbackObservedAt: now, now: now)
    }
}
