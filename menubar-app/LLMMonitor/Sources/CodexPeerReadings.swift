import Foundation
// `kill` / `SIGKILL` are POSIX, not Foundation: Linux's swift-corelibs-foundation
// does not re-export them, so the platform module has to be imported explicitly
// for the headless build (same reason `LoomAccountsCheck.swift` does).
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Codex readings mirrored from **peer hosts** over the existing ssh channel
/// (#320) — the third read-only source in `pollCodexSnapshot`'s newer-wins
/// choice, beside the local rollout snapshot (`CodexProfiles`) and Loom's live
/// check (`LoomAccountsCheck`, #230).
///
/// ### The problem this closes
///
/// A Loom Codex profile is read only from what Codex records *on the same
/// host*. When Codex stops running here and the same accounts stay active on
/// other hosts (the usual shape: the use moved to Linux workers), this host's
/// rows freeze and read as stale forever. Nothing carried the peers' fresh
/// readings back — so the one place a person looks (the menu bar) is the one
/// place the Codex pool cannot be seen.
///
/// ### What crosses the channel — and what never does
///
/// Each configured peer answers one read-only command,
/// `'claude-monitor' codex readings` (the pre-rename binary name both 1.x and
/// 2.x peers answer to, as in `AccountSyncRemote`), which prints derived
/// readings only: profile name, windows, reset instants, observed-at. **No
/// credential, no `auth.json` content, no home path, and never `accounts
/// export`'s plaintext-token bundle.** The peer reads nothing but its own
/// database; this host writes nothing anywhere. Every failure — no ssh, a
/// refused connection, a timeout, undecodable output — leaves the cache alone
/// and returns silently, because the two local sources remain a complete
/// fallback and none of these is a fault worth marking an account unhealthy
/// for.
///
/// ### Join key: the Loom profile name
///
/// Both sides key a reading on the profile's own directory name —
/// `(codex_home as NSString).lastPathComponent`, exactly the key
/// `CodexProfiles.scan()` enumerates and `loomCodexLiveReading` matches on.
/// `ranking.json` was considered and rejected: it carries an email but no
/// account id, and a Codex row's email can be NULL, so the profile name is
/// the one key present on every snapshot-mode row on both ends.
///
/// ### The newer-wins rule is #230's, unchanged
///
/// A peer reading wins only when its observation is **strictly newer** than
/// both local sources, and never when it measured nothing (`hasMeasurement`
/// is false for a row whose windows all rolled over or were never measured).
/// Rows are written with the observation's own timestamp, so the
/// cause-independent staleness backstop (`AccountFreshness`, #148) applies
/// unchanged: a peer whose own readings go stale reads as stale here too.
///
/// ### Configuration
///
/// Peers are a plain list of ssh host names, empty by default so nothing
/// changes for existing hosts. `$LLM_MONITOR_CODEX_PEERS` (comma- or
/// whitespace-separated) replaces the list; otherwise the file
/// `codex-peers.txt` beside the database supplies one host per line with `#`
/// comments — beside the database the way the account lists already are.
/// Per-host ssh tuning goes through `~/.ssh/config` aliases, as with
/// `accounts push`/`pull`.
///
/// Portable core: no AppKit / SwiftUI / Combine / os.Logger — builds on Linux.
enum CodexPeerReadings {
    /// `$LLM_MONITOR_CODEX_PEERS` — the peer list override. Present and
    /// non-empty replaces the file entirely (the same replaces-not-merges
    /// convention `$LLM_MONITOR_CLAUDE_TOKEN_DIRS` follows).
    static let peersEnvKey = "LLM_MONITOR_CODEX_PEERS"

    /// The peer list file, read beside the database when the env override is
    /// absent. One ssh host per line; `#` starts a comment; blank lines are
    /// skipped; duplicates keep their first occurrence.
    static let peersFileBaseName = "codex-peers.txt"

    /// The `usage_history.raw_data` `source` tag prefix marking a row fed by
    /// a peer. The suffix is the peer's host name, e.g. `peer:worker-3` —
    /// what `codex list` and the popover print as the reading's origin.
    static let peerSourcePrefix = "peer:"

    /// The peer wire document's `schema` field. Additive changes keep it at 1
    /// (`ranking.json`'s rule); a reshaping change bumps it.
    static let schemaVersion = 1

    /// The read-only remote argv, spelled once so the fetch, the CLI usage
    /// text, and the self-test cannot disagree. Deliberately *not* `accounts
    /// export` — that carries plaintext tokens and is exactly the channel this
    /// source must not reuse.
    static let remoteArguments = ["codex", "readings"]

    /// Wall-clock ceiling on one peer's ssh child. Bounded where
    /// `AccountSyncRemote`'s push child deliberately is not: a bundle push may
    /// legitimately take as long as its link allows, but a peer refresh rides
    /// the poll loop — a wedged peer must cost one skipped refresh, not a
    /// stuck cycle. `~/.ssh/config` `ConnectTimeout` still applies underneath.
    static let defaultTimeout: TimeInterval = 30

    // MARK: - Peer list

    /// The configured peers: the env override when present, else the file
    /// beside the database. Empty (never an error) when neither exists.
    static func resolveHosts(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        dbDirectory: String?
    ) -> [String] {
        if let raw = environment[peersEnvKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return dedupe(raw.split { ", \t\n\r".contains($0) }.map(String.init))
        }
        guard let directory = dbDirectory?.trimmingCharacters(in: .whitespaces),
              !directory.isEmpty else { return [] }
        let path = (directory as NSString).appendingPathComponent(peersFileBaseName)
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return dedupe(text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        })
    }

    /// First occurrence wins, order preserved — a host listed twice is fetched
    /// once, and the operator's order is the fetch order.
    private static func dedupe(_ hosts: [String]) -> [String] {
        var seen = Set<String>()
        return hosts.filter { seen.insert($0).inserted }
    }

    // MARK: - Wire

    /// The remote command string handed to ssh as its final argument. The
    /// binary name is POSIX-quoted (`AccountSyncRemote.shellQuote`) because a
    /// non-interactive ssh shell joins trailing arguments with spaces and
    /// hands the result to the remote shell.
    static func remoteReadingsCommand(remoteBinary: String) -> String {
        AccountSyncRemote.shellQuote(remoteBinary) + " " + remoteArguments.joined(separator: " ")
    }

    /// One peer's reading for one profile, already filed into the shared
    /// window model.
    struct Reading: Sendable {
        /// The Loom profile name — the join key, never a path.
        let profile: String
        /// The peer this was fetched from. Not on the wire (the fetcher
        /// tags it); it is what the row's `source` raw field records.
        var host: String = ""
        /// When the peer observed the reading. This is the figure the
        /// newer-wins comparison turns on and the timestamp any row written
        /// from it carries.
        let observedAt: Date
        let plan: String?
        let rateLimit: RateLimitSnapshot

        /// True when this row carries a usable measurement. A row whose
        /// windows are absent or all rolled over is **not** evidence about the
        /// account and must never displace a local reading.
        var hasMeasurement: Bool { !rateLimit.isEmpty }
    }

    /// One peer's decoded document.
    struct Document: Sendable {
        let generatedAt: Date
        let readings: [Reading]
    }

    /// Merge one document's measured readings into a per-profile cache,
    /// newest-wins: a candidate displaces the incumbent only when strictly
    /// newer (an equal timestamp keeps it), and a row that measured nothing
    /// never enters at all. Pure — the poller's cache is just this fold over
    /// every peer's document, so `selftest` drives the exact merge the fetch
    /// loop runs.
    static func merging(
        _ document: Document, into cache: [String: Reading]
    ) -> [String: Reading] {
        var merged = cache
        for reading in document.readings where reading.hasMeasurement {
            if let current = merged[reading.profile], current.observedAt >= reading.observedAt {
                continue
            }
            merged[reading.profile] = reading
        }
        return merged
    }

    /// Encode the document the `codex readings` verb prints. Windows carry
    /// their `duration_seconds` so the receiving side re-derives the kind from
    /// the length — the rule the whole codebase insists on — with `kind`
    /// alongside for readability only.
    static func encodeDocument(readings: [Reading], generatedAt: Date) -> Data {
        let iso = ISO8601DateFormatter()
        let rows: [[String: Any]] = readings.map { reading in
            var row: [String: Any] = [
                "profile": reading.profile,
                "observed_at": iso.string(from: reading.observedAt),
            ]
            if let plan = reading.plan { row["plan"] = plan }
            row["windows"] = [reading.rateLimit.session, reading.rateLimit.weekly]
                .compactMap { $0 }
                .map { window -> [String: Any] in
                    var json: [String: Any] = [
                        "kind": window.kind.key,
                        "used_percent": window.usedPercent,
                    ]
                    if let duration = window.durationSeconds { json["duration_seconds"] = duration }
                    if let reset = window.resetAt { json["reset_at"] = iso.string(from: reset) }
                    return json
                }
            return row
        }
        let document: [String: Any] = [
            "schema": schemaVersion,
            "generated_at": iso.string(from: generatedAt),
            "readings": rows,
        ]
        // `sortedKeys` so a capture diff between two runs of the same host is
        // stable. Encoding a dictionary this shape builds cannot fail, but a
        // non-throwing fallback keeps the verb total.
        return (try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])) ?? Data()
    }

    /// Decode one peer document. Pure, so `selftest` drives it offline.
    ///
    /// Returns nil only when the payload is not a document at all (unparseable,
    /// or no `readings` array). A document with **zero** readings is valid — a
    /// peer with no Codex accounts is a normal answer, not a failure.
    static func decode(
        _ data: Data,
        host: String,
        now: Date = Date()
    ) -> Document? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["readings"] as? [[String: Any]] else { return nil }
        let generatedAt = UsageRecord.parseISO(root["generated_at"] as? String) ?? now
        var readings: [Reading] = []
        for row in rows {
            guard let profile = (row["profile"] as? String)?
                .trimmingCharacters(in: .whitespaces), !profile.isEmpty else { continue }
            let observedAt = UsageRecord.parseISO(row["observed_at"] as? String) ?? generatedAt
            let plan = (row["plan"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let windows = ((row["windows"] as? [[String: Any]]) ?? [])
                .compactMap { parseWindow($0, now: now) }
            readings.append(Reading(
                profile: profile, host: host, observedAt: observedAt, plan: plan,
                rateLimit: RateLimitSnapshot(windows: windows)
            ))
        }
        return Document(generatedAt: generatedAt, readings: readings)
    }

    /// One wire window, or nil when it carries no usable figure. The drop
    /// rules mirror `CodexProfiles` and `LoomAccountsCheck` exactly: a
    /// non-finite or negative percentage is nonsense, and a window whose
    /// reset has already passed describes a window that no longer exists —
    /// dropped, never carried forward.
    private static func parseWindow(_ json: [String: Any], now: Date) -> RateLimitWindow? {
        guard let used = (json["used_percent"] as? NSNumber)?.doubleValue,
              used.isFinite, used >= 0 else { return nil }
        // The length drives the kind when the wire carries one; the kind key
        // is the fallback for a document that named only the bucket.
        let duration = (json["duration_seconds"] as? NSNumber).map { $0.doubleValue }
        let kind = duration.map { RateLimitWindow.kind(forDuration: $0) }
            ?? kind(forKey: (json["kind"] as? String) ?? "")
        let resetAt = UsageRecord.parseISO(json["reset_at"] as? String)
        if let resetAt = resetAt, resetAt <= now { return nil }
        let percent = min(100, used)
        return RateLimitWindow(
            kind: kind, usedPercent: percent, durationSeconds: duration,
            resetAt: resetAt, status: percent >= 100 ? "rejected" : "allowed"
        )
    }

    /// The kind a `kind` key names. `5h`/`7d` are `RateLimitWindowKind.key`'s
    /// spellings (and what every verified document carries); anything else is
    /// parsed back from the key where possible and `unknown` otherwise —
    /// never guessed into a named bucket.
    static func kind(forKey key: String) -> RateLimitWindowKind {
        switch key {
        case "5h": return .session
        case "7d": return .weekly
        case "unknown": return .unknown
        default:
            if key.hasSuffix("s"), let seconds = TimeInterval(key.dropLast()) {
                return .other(seconds)
            }
            return .unknown
        }
    }

    // MARK: - Running the command

    /// Spawn `ssh <host> '<binary>' codex readings` and decode its stdout.
    /// Nil on any failure at all — missing ssh, spawn error, timeout,
    /// undecodable output — because every one of those means the same thing to
    /// the caller: no peer reading this cycle, keep using local sources.
    ///
    /// The exit status deliberately does not gate decoding, the same way
    /// `LoomAccountsCheck.run` does not: what matters is whether stdout parses
    /// as a document, and ssh's own diagnostics are noise a decode of garbage
    /// already survives. Nothing is ever written to this child's stdin (it is
    /// wired to /dev/null below), so the SIGPIPE trap cannot fire — but the
    /// guard is process-wide, idempotent and free, and installing it at every
    /// spawn site keeps the invariant one rule instead of a per-site judgement
    /// call (#202).
    ///
    /// `async` with `Task.sleep` waits (never `Process.waitUntilExit()`, which
    /// spins a CFRunLoop and hangs off the main thread — the same rule
    /// `LoomAccountsCheck.run` and `CodexAppServerClient` follow).
    static func run(
        host: String,
        sshBinary: String,
        sshOptions: [String] = AccountSyncRemote.defaultSSHOptions,
        remoteBinary: String = AccountSyncRemote.defaultRemoteBinary,
        timeout: TimeInterval = defaultTimeout,
        now: Date = Date()
    ) async -> Document? {
        SubprocessIO.ignoreSIGPIPE()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshBinary)
        process.arguments = sshOptions + [host, remoteReadingsCommand(remoteBinary: remoteBinary)]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

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

        await outDrain.finishAndClose(timeout: 5)
        await errDrain.finishAndClose(timeout: 5)
        guard outDrain.isFinished else { return nil }
        return decode(outDrain.waitForEOF(), host: host, now: now)
    }
}
