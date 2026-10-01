import Foundation
// `kill` / `SIGKILL` are POSIX, not Foundation: Linux's
// swift-corelibs-foundation does not re-export them, so the platform module has
// to be imported explicitly for the headless build.
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// `llm-monitor accounts push|pull` — ssh fan-out built on the existing
/// `AccountSync` export/import plumbing (#188).
///
/// **The whole point is that the bundle never becomes a file.** `export` →
/// `import` converges two hosts today, but only via a plaintext-token file that
/// has to be written, `scp`'d, and remembered-to-delete on both ends. Here the
/// bundle is serialized into memory, written to the ssh child's **stdin**, and
/// read by `accounts import -` on the destination straight into SQLite. There
/// is no `write(to:)` anywhere on either side of the channel, and nothing but
/// the already-encrypted ssh stream carries it.
///
/// Portable core: no AppKit/SwiftUI, so `push`/`pull` work identically from a
/// headless Linux worker and from a Mac. `Process.waitUntilExit()` is used here
/// and that is safe *because* both CLI entry points (`main.swift`,
/// `HeadlessMain.swift`) dispatch `accounts` synchronously on the process's
/// initial thread — see CLAUDE.md on never calling it off the main thread.
enum AccountSyncRemote {
    /// What the destination is expected to answer to. Overridable with
    /// `--remote-bin`, which matters more often than it looks: a
    /// non-interactive `ssh HOST <command>` shell does **not** source the
    /// profile that usually puts `~/.local/bin` on `PATH`.
    ///
    /// Deliberately still the **pre-rename** name: every 2.x install keeps a
    /// `claude-monitor` alias, and a peer still on 1.x has only that name, so
    /// it is the one spelling that resolves on both. Switch to `llm-monitor`
    /// once the fleet is past 1.x (tracked with the `~/.claude-monitor`
    /// symlink removal).
    static let defaultRemoteBinary = "claude-monitor"

    /// The follow-on step `--then-loom` runs on whichever host received the
    /// bundle. Always the next thing an operator types on a Loom host, so it is
    /// spelled once, here.
    static let loomImportCommand = "loom-daemon tokens import-from-monitor --shared"

    /// Options every invocation gets, before the caller's `--ssh-option`s.
    ///
    /// `BatchMode=yes` is deliberate: for `push`, the child's stdin *is* the
    /// bundle, so ssh could not read a password prompt from it even if it
    /// wanted to. Failing immediately with ssh's own diagnostic beats hanging
    /// on a prompt nobody can answer. Key/agent auth is therefore required —
    /// `--ssh-option` can undo this for an operator who knows better.
    static let defaultSSHOptions = ["-o", "BatchMode=yes"]

    enum Verb: String {
        case push
        case pull
    }

    // MARK: - Options

    struct Options {
        var hosts: [String] = []
        var dryRun = false
        var thenLoom = false
        var wantsHelp = false
        var dbPath = AccountSync.defaultDBPath
        var remoteBinary = defaultRemoteBinary
        /// Extra arguments spliced in ahead of the host. `--ssh-option` carries
        /// exactly **one argv element per flag**, so an option that takes a
        /// value needs the flag twice: `--ssh-option -p --ssh-option 2222`,
        /// `--ssh-option -i --ssh-option ~/.ssh/fleet`. (Passing `-p 2222` as a
        /// single value would hand ssh one argument containing a space, which it
        /// rejects.)
        var sshOptions: [String] = []
    }

    enum ArgError: Error {
        case unknownOption(String)
        case missingValue(String)
        case noHost(Verb)
        case tooManyHosts(Verb, [String])

        var message: String {
            switch self {
            case .unknownOption(let option):
                return "Unknown option '\(option)' (see --help)"
            case .missingValue(let option):
                return "\(option) requires a value"
            case .noHost(let verb):
                return "\(verb.rawValue) requires at least one HOST (e.g. `accounts \(verb.rawValue) worker1`)"
            case .tooManyHosts(let verb, let hosts):
                return """
                    \(verb.rawValue) takes exactly one HOST (got \(hosts.count)) — a pull \
                    converges this host from one peer; run it again for another peer
                    """
            }
        }
    }

    /// Pure argument parsing, exercised directly by `selftest`. `--db` and
    /// `--help` go through `CLIArgs.matchCommon` so the two options every
    /// subcommand shares keep exactly one spelling (#176).
    static func parseArgs(_ args: [String], verb: Verb) throws -> Options {
        var options = Options()
        var i = 0
        while i < args.count {
            switch CLIArgs.matchCommon(args, i) {
            case .db(let value):
                options.dbPath = value
                i += 1
            case .help:
                options.wantsHelp = true
            case .notMatched:
                switch args[i] {
                case "--dry-run":
                    options.dryRun = true
                case "--then-loom":
                    options.thenLoom = true
                case "--remote-bin":
                    guard i + 1 < args.count else { throw ArgError.missingValue("--remote-bin") }
                    options.remoteBinary = args[i + 1]
                    i += 1
                case "--ssh-option":
                    guard i + 1 < args.count else { throw ArgError.missingValue("--ssh-option") }
                    options.sshOptions.append(args[i + 1])
                    i += 1
                default:
                    guard !args[i].hasPrefix("-") else { throw ArgError.unknownOption(args[i]) }
                    options.hosts.append(args[i])
                }
            }
            i += 1
        }

        if options.wantsHelp { return options }
        guard !options.hosts.isEmpty else { throw ArgError.noHost(verb) }
        if verb == .pull, options.hosts.count > 1 {
            throw ArgError.tooManyHosts(verb, options.hosts)
        }
        return options
    }

    // MARK: - Remote command construction

    /// POSIX single-quoting, for the one value that reaches the destination's
    /// shell: the remote binary path. `ssh HOST <words…>` joins its trailing
    /// arguments with spaces and hands the result to the remote *shell*, so a
    /// path with a space (or anything else the shell would reinterpret) has to
    /// arrive quoted.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The destination side of a `push`: read the bundle from stdin, upsert it,
    /// and — with `--then-loom` — hand the refreshed store to the Loom daemon.
    /// `&&` and not `;` on purpose: a failed import must not be followed by a
    /// token re-import that would re-publish the *old* credentials as if the
    /// push had succeeded.
    static func remoteImportCommand(remoteBinary: String, thenLoom: Bool) -> String {
        var command = "\(shellQuote(remoteBinary)) accounts import -"
        if thenLoom { command += " && \(loomImportCommand)" }
        return command
    }

    /// The source side of a `pull`. `--compact` because nothing reads this by
    /// eye — it goes straight into a decoder on this host.
    static func remoteExportCommand(remoteBinary: String) -> String {
        "\(shellQuote(remoteBinary)) accounts export --compact"
    }

    /// What `--dry-run` runs instead of shipping anything: proves the host is
    /// reachable and that `llm-monitor` resolves there, while putting **no
    /// credential on the wire** for a mere preview.
    static func remoteProbeCommand(remoteBinary: String) -> String {
        "\(shellQuote(remoteBinary)) --version"
    }

    static func sshArguments(host: String, sshOptions: [String], remoteCommand: String) -> [String] {
        defaultSSHOptions + sshOptions + [host, remoteCommand]
    }

    // MARK: - ssh binary resolution

    /// Explicit override, and the seam `selftest` points at a stub `ssh`.
    static let sshOverrideEnvKey = "LLM_MONITOR_SSH_BIN"

    /// First executable `ssh` among: the override, each `PATH` entry, then the
    /// absolute locations ssh ships in. Mirrors `CodexBinary.resolve` — a
    /// Finder-launched bundle inherits launchd's minimal `PATH`, and while
    /// `push`/`pull` are CLI-only today, resolving an absolute path costs
    /// nothing and removes the class of bug outright.
    static func resolveSSHBinary(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        if let override = AppPaths.environment("SSH_BIN", in: environment)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            // A broken override is a configuration mistake worth failing on,
            // not something to paper over with PATH.
            return fileManager.isExecutableFile(atPath: override) ? override : nil
        }
        let pathDirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in pathDirs + ["/usr/bin", "/bin", "/usr/local/bin", "/opt/homebrew/bin"] {
            guard !directory.isEmpty else { continue }
            let candidate = (directory as NSString).appendingPathComponent("ssh")
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: - Subprocess timeout

    /// Wall-clock ceiling on a single ssh child, in seconds.
    ///
    /// **Unset means unbounded, and that is the production default on purpose.**
    /// A fleet-sized bundle over a slow link legitimately takes as long as it
    /// takes, and guillotining a half-delivered push at a number nobody chose
    /// would turn a slow host into a corrupted one. The flip side is that a child
    /// which never exits wedges the caller forever — tolerable for an operator
    /// watching a terminal, *not* tolerable for `selftest`, where it showed up as
    /// a 600-deep process chain that sat for 19 hours and took the host's swap
    /// with it (#234). So this is the seam that bounds it: the suite sets the
    /// override, the fleet does not.
    static let processTimeoutEnvKey = "LLM_MONITOR_SUBPROCESS_TIMEOUT_SECS"

    /// How long a killed child's pipes get to reach EOF before the drains are
    /// abandoned. Needed because a *grandchild* inherits the same write ends, so
    /// reaping the direct child does not necessarily close them.
    static let drainGraceAfterTimeout: TimeInterval = 2

    /// Parses `processTimeoutEnvKey`; nil (unbounded) for an absent, unparseable,
    /// or non-positive value. A garbage value is deliberately *not* an error —
    /// this is a backstop, and failing a push over a mistyped backstop would be
    /// worse than running without one.
    static func resolveProcessTimeout(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TimeInterval? {
        guard let raw = AppPaths.environment("SUBPROCESS_TIMEOUT_SECS", in: environment)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let seconds = TimeInterval(raw), seconds > 0 else { return nil }
        return seconds
    }

    // MARK: - Output sink

    /// Where progress lines go. Defaulted to stdout/stderr; `selftest` swaps in
    /// collectors so a check can assert on the summary without spraying the
    /// test log.
    struct Output {
        var info: (String) -> Void = { print($0) }
        var error: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

        func relay(_ data: Data, host: String, asError: Bool = false) {
            guard let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let message = "\(host): \(line)"
                if asError { error(message) } else { info(message) }
            }
        }
    }

    // MARK: - Subprocess plumbing

    struct RemoteResult {
        let status: Int32
        let stdout: Data
        let stderr: Data
        /// True when `input` could not be handed to the child in full — i.e. the
        /// child stopped reading (EPIPE) before the whole bundle was written.
        /// Kept separate from `status` because the two answer different
        /// questions: a fast-failing ssh reports *why* it failed in its own exit
        /// code, and the broken pipe is merely the downstream symptom.
        var inputWriteFailed: Bool = false
        /// True when the child outlived `runProcess`'s timeout and was killed.
        /// Its own exit status then says only how it died (signal 9), so this is
        /// the field that carries *why* — and `stdout`/`stderr` are whatever had
        /// arrived by then, which is why a caller must not read them as complete.
        var timedOut: Bool = false
    }

    /// Sentinel status for a child still reported as running after SIGKILL —
    /// `Process.terminationStatus` is only defined once the process has exited,
    /// so it is never read in that state. `timedOut` is the field that matters
    /// here; this merely keeps the status non-zero so no caller mistakes a
    /// killed child for a successful one.
    static let killedStatus: Int32 = -1

    /// Runs `executable arguments…`, optionally feeding `input` to its stdin,
    /// and returns both captured streams plus the exit status.
    ///
    /// `input` is written after the drains are armed, so a bundle larger than a
    /// pipe buffer cannot wedge against output the child has already produced.
    /// A child that exits *without* reading its stdin (ssh failing fast on a
    /// refused connection, a missing remote binary) is likewise survivable: the
    /// EPIPE is reported in `RemoteResult.inputWriteFailed` instead of killing
    /// this process, and the child's own status and stderr are still collected.
    ///
    /// `timeout` (nil = unbounded, the production default — see
    /// `processTimeoutEnvKey`) bounds the whole wait: a child still running at
    /// the deadline takes SIGTERM, then SIGKILL, and the result comes back with
    /// `timedOut` set and whatever output had arrived. `Thread.sleep` is the
    /// right wait here, unlike the `Task.sleep` the poll-path spawners use: both
    /// CLI entry points dispatch `accounts` synchronously on the process's
    /// initial thread (see this file's header), so there is no cooperative-pool
    /// thread to starve.
    static func runProcess(
        executable: String, arguments: [String], input: Data? = nil,
        timeout: TimeInterval? = nil
    ) throws -> RemoteResult {
        // SIGPIPE's default disposition kills the **whole process**, which on a
        // fan-out means the first fast-failing host takes every remaining host
        // with it — silently, with exit 141 and no diagnostic at all. That is
        // exactly what real ssh does against a refused port: it exits before
        // reading its stdin, so any bundle larger than the pipe buffer (~64 KiB,
        // i.e. roughly a fleet's worth of accounts) blocks mid-write and then
        // takes EPIPE. Shared with the other subprocess call site (#202) rather
        // than owned here, because `CodexAppServerClient` writes to a child's
        // stdin too and had no guard at all.
        SubprocessIO.ignoreSIGPIPE()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let inPipe = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : inPipe

        // Both streams are drained *concurrently* rather than read in sequence:
        // reading stdout to EOF first would deadlock any child that fills the
        // 64 KiB stderr pipe buffer before finishing (an ssh banner, a chatty
        // remote).
        let outDrain = PipeDrain(outPipe.fileHandleForReading)
        let errDrain = PipeDrain(errPipe.fileHandleForReading)

        try process.run()

        var inputWriteFailed = false
        if let input = input {
            // The one and only place the bundle leaves this process: a pipe to
            // the ssh child. It is never handed to `Data.write(to:)`.
            //
            // The *throwing* `write(contentsOf:)`, not the non-throwing
            // `write(_:)`: with SIGPIPE ignored above, a child that has already
            // gone away makes this return EPIPE, and only the throwing spelling
            // surfaces that as a catchable Swift error. Swallowing it here (and
            // falling through to the wait below) is deliberate — the child's own
            // exit status and stderr are the actionable diagnostic, and they are
            // still on their way.
            do {
                try inPipe.fileHandleForWriting.write(contentsOf: input)
            } catch {
                inputWriteFailed = true
            }
            try? inPipe.fileHandleForWriting.close()
        }

        var timedOut = false
        if let timeout = timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                if Date() >= deadline {
                    timedOut = true
                    process.terminate()
                    Thread.sleep(forTimeInterval: 0.5)
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        let out: Data
        let err: Data
        if timedOut {
            // Bounded, because killing the child is not enough on its own: a
            // grandchild holds the inherited write ends, so these pipes can
            // outlive the process we just killed and the unbounded wait below
            // would hang exactly where the timeout was supposed to help.
            out = outDrain.waitForEOF(timeout: drainGraceAfterTimeout).data
            err = errDrain.waitForEOF(timeout: drainGraceAfterTimeout).data
            // SIGKILL cannot be refused, so this is a short reap, not a wait on
            // the child's own cooperation — and `waitUntilExit()` is avoided
            // precisely because a pathological child must not be able to pin it.
            let reapDeadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < reapDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
        } else {
            out = outDrain.waitForEOF()
            err = errDrain.waitForEOF()
            process.waitUntilExit()
        }

        return RemoteResult(
            status: process.isRunning ? killedStatus : process.terminationStatus,
            stdout: out, stderr: err,
            inputWriteFailed: inputWriteFailed, timedOut: timedOut
        )
    }

    // MARK: - push

    /// Exports this host's bundle once and streams it to every host. Returns
    /// the process exit code: non-zero if **any** host failed, having still
    /// attempted every other host (a fleet converges as far as it can; one
    /// unreachable worker does not strand the rest).
    static func runPush(
        _ options: Options,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        output: Output = Output()
    ) -> Int32 {
        guard let ssh = resolveSSHBinary(environment: environment) else {
            output.error("Error: no `ssh` executable found on PATH (set \(sshOverrideEnvKey) to override)")
            return 1
        }

        let timeout = resolveProcessTimeout(environment: environment)

        if options.dryRun {
            return probeHosts(options, verb: .push, ssh: ssh, timeout: timeout, output: output)
        }

        let bundle: AccountSync.ExportBundle
        let data: Data
        do {
            bundle = try AccountSync.exportBundle(dbPath: options.dbPath)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(bundle)
        } catch {
            output.error("Error: export failed: \(error.localizedDescription)")
            return 1
        }

        output.error("""
            Streaming \(bundle.accounts.count) account record(s) to \(options.hosts.count) host(s) \
            over ssh. The bundle carries plaintext OAuth tokens but is never written to disk on \
            either side — it exists only in memory here and in the ssh channel.
            """)

        let remoteCommand = remoteImportCommand(remoteBinary: options.remoteBinary, thenLoom: options.thenLoom)
        var failed: [String] = []
        for host in options.hosts {
            do {
                let result = try runProcess(
                    executable: ssh,
                    arguments: sshArguments(host: host, sshOptions: options.sshOptions, remoteCommand: remoteCommand),
                    input: data,
                    timeout: timeout
                )
                // Stream fidelity is preserved across the hop: what the
                // destination said on stdout stays on stdout here (it is the
                // created/updated/skipped report a script may parse), and its
                // stderr stays on stderr whether or not the host succeeded.
                output.relay(result.stdout, host: host)
                output.relay(result.stderr, host: host, asError: true)
                if let reason = failureDescription(result) {
                    failed.append(host)
                    output.error("\(host): FAILED (\(reason))")
                }
            } catch {
                failed.append(host)
                output.error("\(host): FAILED (could not launch ssh: \(error.localizedDescription))")
            }
        }

        return reportFanOutResult(verb: .push, hosts: options.hosts, failed: failed, output: output)
    }

    // MARK: - pull

    /// Converges *this* host from one peer — the bootstrap direction, for a
    /// fresh worker that has nothing to push. Same channel, opposite way round:
    /// the peer's `accounts export` writes to its stdout, ssh carries it, and
    /// it is decoded and imported here without ever landing in a file.
    static func runPull(
        _ options: Options,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        output: Output = Output()
    ) -> Int32 {
        guard let ssh = resolveSSHBinary(environment: environment) else {
            output.error("Error: no `ssh` executable found on PATH (set \(sshOverrideEnvKey) to override)")
            return 1
        }
        guard let host = options.hosts.first else {
            output.error("Error: \(ArgError.noHost(.pull).message)")
            return 1
        }

        let timeout = resolveProcessTimeout(environment: environment)

        if options.dryRun {
            return probeHosts(options, verb: .pull, ssh: ssh, timeout: timeout, output: output)
        }

        let result: RemoteResult
        do {
            result = try runProcess(
                executable: ssh,
                arguments: sshArguments(
                    host: host,
                    sshOptions: options.sshOptions,
                    remoteCommand: remoteExportCommand(remoteBinary: options.remoteBinary)
                ),
                timeout: timeout
            )
        } catch {
            output.error("Error: could not launch ssh: \(error.localizedDescription)")
            return 1
        }

        // `failureDescription` rather than a bare status check, so a child that
        // was killed on the timeout is reported as such instead of having its
        // truncated stdout handed to the decoder below.
        if let reason = failureDescription(result) {
            output.relay(result.stderr, host: host, asError: true)
            output.error("Error: \(host): remote export failed (\(reason))")
            return 1
        }

        let bundle: AccountSync.ExportBundle
        do {
            bundle = try JSONDecoder().decode(AccountSync.ExportBundle.self, from: result.stdout)
        } catch {
            // Deliberately reports only the size: the body is a credential, and
            // a decode failure is exactly when it would be tempting to dump it.
            output.relay(result.stderr, host: host, asError: true)
            output.error("""
                Error: \(host): could not parse the remote bundle (\(result.stdout.count) byte(s)). \
                Check that `\(options.remoteBinary) accounts export` runs cleanly there and prints \
                nothing extra on stdout.
                """)
            return 1
        }

        do {
            let summary = try AccountSync.importBundle(bundle, dbPath: options.dbPath)
            for outcome in summary.outcomes {
                output.info("\(outcome.email ?? outcome.id): \(outcome.action.rawValue)")
            }
            output.info("""
                Done: \(summary.created) created, \(summary.updated) updated, \
                \(summary.skipped) skipped (local record was newer or equal), \
                \(summary.excluded) excluded (host-local Codex/OpenAI account).
                """)
        } catch {
            output.error("Error: import failed: \(error.localizedDescription)")
            return 1
        }

        if options.thenLoom {
            return runLoomImportLocally(output: output)
        }
        return 0
    }

    /// `--then-loom` on the receiving host. For `pull` that host is this one, so
    /// the command runs locally through `/bin/sh` (it is a fixed literal, not
    /// user input) with its output relayed.
    private static func runLoomImportLocally(output: Output) -> Int32 {
        do {
            let result = try runProcess(executable: "/bin/sh", arguments: ["-c", loomImportCommand])
            output.relay(result.stdout, host: "local")
            output.relay(result.stderr, host: "local", asError: true)
            if result.status != 0 {
                output.error("Error: `\(loomImportCommand)` failed (\(exitDescription(result.status)))")
                return 1
            }
        } catch {
            output.error("Error: could not run `\(loomImportCommand)`: \(error.localizedDescription)")
            return 1
        }
        return 0
    }

    // MARK: - Shared helpers

    /// `--dry-run` for both verbs: reachability plus "is `llm-monitor`
    /// actually on this host's non-interactive PATH", which is the failure that
    /// bites a fan-out in practice. No bundle is produced and nothing is
    /// written on either side.
    private static func probeHosts(
        _ options: Options, verb: Verb, ssh: String, timeout: TimeInterval? = nil, output: Output
    ) -> Int32 {
        let command = remoteProbeCommand(remoteBinary: options.remoteBinary)
        var failed: [String] = []
        for host in options.hosts {
            do {
                let result = try runProcess(
                    executable: ssh,
                    arguments: sshArguments(host: host, sshOptions: options.sshOptions, remoteCommand: command),
                    timeout: timeout
                )
                if let reason = failureDescription(result) {
                    failed.append(host)
                    output.relay(result.stderr, host: host, asError: true)
                    output.error("\(host): FAILED (\(reason))")
                } else {
                    let version = String(data: result.stdout, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    output.info("\(host): OK — \(options.remoteBinary) \(version.isEmpty ? "(no version reported)" : version)")
                }
            } catch {
                failed.append(host)
                output.error("\(host): FAILED (could not launch ssh: \(error.localizedDescription))")
            }
        }
        output.info("Dry run: no bundle was transferred and nothing was written on any host.")
        return reportFanOutResult(verb: verb, hosts: options.hosts, failed: failed, output: output)
    }

    private static func reportFanOutResult(
        verb: Verb, hosts: [String], failed: [String], output: Output
    ) -> Int32 {
        let ok = hosts.count - failed.count
        if failed.isEmpty {
            output.info("\(verb.rawValue): \(ok)/\(hosts.count) host(s) succeeded.")
            return 0
        }
        output.error("\(verb.rawValue): \(ok)/\(hosts.count) host(s) succeeded; failed: \(failed.joined(separator: ", "))")
        return 1
    }

    /// Why one host failed, or `nil` if it did not — both halves of the
    /// evidence in one place: what the child exited with, and whether the bundle
    /// actually reached it.
    ///
    /// A non-zero status wins even when the write also broke, because the
    /// broken pipe is the *symptom*: ssh died first (255 for a refused
    /// connection, 127 for a missing remote binary) and the blocked write took
    /// EPIPE afterwards. Reporting the pipe would hide the one line the operator
    /// can act on. A clean exit with a truncated bundle is the remaining case —
    /// the remote command stopped reading early, so nothing can be assumed to
    /// have landed.
    static func failureDescription(_ result: RemoteResult) -> String? {
        // Ahead of the status, because a killed child's status says only how it
        // died — and a child that handled SIGTERM and exited 0 would otherwise
        // read as a success that never finished.
        if result.timedOut {
            return "timed out and was killed (raise or unset \(processTimeoutEnvKey))"
        }
        if result.status != 0 { return exitDescription(result.status) }
        if result.inputWriteFailed {
            return "the remote command stopped reading before the whole bundle was sent"
        }
        return nil
    }

    /// ssh's own conventions, spelled out — `255` is ssh itself failing (auth,
    /// DNS, refused connection), anything else came from the remote command.
    static func exitDescription(_ status: Int32) -> String {
        switch status {
        case 255: return "exit 255 — ssh itself failed: authentication, host key, or connection"
        case 127: return "exit 127 — command not found on the remote host; try --remote-bin <absolute path>"
        default: return "exit \(status)"
        }
    }
}
