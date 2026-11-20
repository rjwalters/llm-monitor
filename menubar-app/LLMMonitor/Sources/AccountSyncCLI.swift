import Foundation

/// `llm-monitor accounts export|import|push|pull|list|scope` — the CLI surface for
/// `AccountSync` (issue #16) and its ssh fan-out (#188), plus the read-only
/// per-provider pool summary (#297). Reachable directly on
/// both macOS and Linux without requiring `--headless` or any GUI code, so it
/// works on headless Loom hosts.
///
/// `@MainActor` for the same reason as `ZaiCLI`/`CodexCLI`: `list` reads
/// through `UsageStore`, and the whole CLI runs to completion synchronously
/// on the process's initial thread.
@MainActor
enum AccountSyncCLI {
    /// `args` is everything after the `accounts` subcommand itself.
    static func main(_ args: [String]) -> Never {
        guard let sub = args.first else {
            printUsage()
            exit(2)
        }

        switch sub {
        case "export":
            runExport(Array(args.dropFirst()))
        case "import":
            runImport(Array(args.dropFirst()))
        case "push":
            runRemote(Array(args.dropFirst()), verb: .push)
        case "pull":
            runRemote(Array(args.dropFirst()), verb: .pull)
        case "scope":
            runScope(Array(args.dropFirst()))
        case "list":
            runList(Array(args.dropFirst()))
        case "--help", "-h", "help":
            printUsage()
            exit(0)
        default:
            FileHandle.standardError.write(Data("Unknown 'accounts' subcommand '\(sub)'\n\n".utf8))
            printUsage()
            exit(2)
        }
    }

    // MARK: - export

    private static func runExport(_ args: [String]) -> Never {
        var outputPath: String?
        var pretty = true
        var includePersonal = false
        var dbPath = AccountSync.defaultDBPath

        var i = 0
        while i < args.count {
            switch CLIArgs.matchCommon(args, i) {
            case .db(let value):
                dbPath = value
                i += 1
            case .help:
                printUsage()
                exit(0)
            case .notMatched:
                switch args[i] {
                case "--output", "-o":
                    outputPath = CLIArgs.requireValue(args, i, option: "--output")
                    i += 1
                case "--include-personal":
                    includePersonal = true
                case "--compact":
                    pretty = false
                default:
                    CLIArgs.fail("Unknown option '\(args[i])' (see --help)")
                }
            }
            i += 1
        }

        do {
            let data = try AccountSync.exportJSON(pretty: pretty, dbPath: dbPath, includePersonal: includePersonal) {
                FileHandle.standardError.write(Data("\($0)\n".utf8))
            }

            FileHandle.standardError.write(Data("""
                WARNING: this export contains OAuth access/refresh tokens in \
                plaintext. Treat it as a credential: keep it off shared/world- \
                readable storage, transfer it over a trusted channel, and \
                delete it once the import completes.

                Codex/OpenAI accounts are host-local and intentionally \
                excluded from this export — register one on each host with \
                `llm-monitor codex add --home <path>` instead of syncing \
                a credential between machines.

                """.utf8))

            if let outputPath = outputPath {
                try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputPath)
                FileHandle.standardError.write(Data("Wrote \(data.count) bytes to \(outputPath) (mode 0600).\n".utf8))
            } else {
                FileHandle.standardError.write(Data("Writing to stdout — shell redirection does NOT set safe file permissions; run `chmod 600` on the result, or pass --output <path> instead.\n".utf8))
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
            exit(0)
        } catch {
            CLIArgs.fail("Export failed: \(error.localizedDescription)")
        }
    }

    // MARK: - import

    private static func runImport(_ args: [String]) -> Never {
        var path: String?
        var dryRun = false
        var dbPath = AccountSync.defaultDBPath

        var i = 0
        while i < args.count {
            switch CLIArgs.matchCommon(args, i) {
            case .db(let value):
                dbPath = value
                i += 1
            case .help:
                printUsage()
                exit(0)
            case .notMatched:
                switch args[i] {
                case "--dry-run":
                    dryRun = true
                default:
                    if path == nil, !args[i].hasPrefix("-") || args[i] == "-" {
                        path = args[i]
                    } else {
                        CLIArgs.fail("Unknown option '\(args[i])' (see --help)")
                    }
                }
            }
            i += 1
        }

        guard let path = path else {
            CLIArgs.fail("import requires a file path (or '-' for stdin)")
        }

        let data: Data
        do {
            data = (path == "-")
                ? FileHandle.standardInput.readDataToEndOfFile()
                : try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            CLIArgs.fail("Could not read '\(path)': \(error.localizedDescription)")
        }

        let bundle: AccountSync.ExportBundle
        do {
            bundle = try JSONDecoder().decode(AccountSync.ExportBundle.self, from: data)
        } catch {
            CLIArgs.fail("Could not parse import file as an accounts bundle: \(error.localizedDescription)")
        }

        if dryRun {
            print("Dry run: \(bundle.accounts.count) account(s) in bundle from '\(bundle.sourceHost)' (exported \(bundle.exportedAt)). No changes made.")
            exit(0)
        }

        do {
            let summary = try AccountSync.importBundle(bundle, dbPath: dbPath)
            for outcome in summary.outcomes {
                print("\(outcome.email ?? outcome.id): \(outcome.action.rawValue)")
            }
            print("Done: \(summary.created) created, \(summary.updated) updated, \(summary.skipped) skipped (local record was newer or equal), \(summary.excluded) excluded (host-local Codex/OpenAI account).")
            exit(0)
        } catch {
            CLIArgs.fail("Import failed: \(error.localizedDescription)")
        }
    }

    // MARK: - push / pull

    /// Both ssh verbs share one handler: they differ only in which direction
    /// the bundle travels, and `AccountSyncRemote` already owns that
    /// difference. Nothing is written to disk on either side — see
    /// `AccountSyncRemote`'s file comment.
    private static func runRemote(_ args: [String], verb: AccountSyncRemote.Verb) -> Never {
        let options: AccountSyncRemote.Options
        do {
            options = try AccountSyncRemote.parseArgs(args, verb: verb)
        } catch let error as AccountSyncRemote.ArgError {
            CLIArgs.fail(error.message)
        } catch {
            CLIArgs.fail("\(error.localizedDescription)")
        }

        if options.wantsHelp {
            printUsage()
            exit(0)
        }

        switch verb {
        case .push:
            exit(AccountSyncRemote.runPush(options))
        case .pull:
            exit(AccountSyncRemote.runPull(options))
        }
    }

    // MARK: - scope

    private static func runScope(_ args: [String]) -> Never {
        var dbPath = AccountSync.defaultDBPath
        var positional: [String] = []
        var i = 0
        while i < args.count {
            switch CLIArgs.matchCommon(args, i) {
            case .db(let path):
                dbPath = path
                i += 1
            case .help:
                printUsage()
                exit(0)
            case .notMatched:
                guard !args[i].hasPrefix("-") else { CLIArgs.fail("Unknown option '\(args[i])'") }
                positional.append(args[i])
            }
            i += 1
        }
        guard positional.count == 2, !positional[0].isEmpty, let scope = AccountScope(rawValue: positional[1]) else {
            CLIArgs.fail("Expected accounts scope <email-or-id> personal|work")
        }
        let selector = positional[0]
        guard FileManager.default.fileExists(atPath: dbPath) else {
            CLIArgs.fail("No database found at \(dbPath)")
        }
        do {
            let db = try openDatabase(dbPath)
            // Resolve and update under the same lock so a concurrent import cannot
            // add another account with this email between the check and the write.
            try db.execute("BEGIN IMMEDIATE")
            let match = "id = ? OR email = ? COLLATE NOCASE"
            let count = try db.scalar("SELECT COUNT(*) FROM accounts WHERE \(match)", selector, selector) as? Int64
            guard count != 0 else { CLIArgs.fail("Unknown account '\(selector)'") }
            guard count == 1 else {
                let ids = try db.scalar("SELECT group_concat(id, ', ') FROM accounts WHERE \(match)", selector, selector)
                CLIArgs.fail("Ambiguous account '\(selector)'. Use one of these ids: \(ids as? String ?? "")")
            }
            UsageStore.addAccountScopeColumn(db)
            try db.run("UPDATE accounts SET scope = ? WHERE \(match)", scope.rawValue, selector, selector)
            try db.execute("COMMIT")
            print("\(selector): \(scope.rawValue)")
            exit(0)
        } catch {
            CLIArgs.fail("Could not set account scope: \(error.localizedDescription)")
        }
    }

    // MARK: - list (#297)

    /// Read-only per-provider pool summary: one table per provider, each with
    /// the same usable/exhausted/next-reset tally the macOS popover's provider
    /// tabs show (`ProviderPoolSummary`). Status comes from
    /// `RankingExporter.statusReading` — exactly what `ranking.json` exports —
    /// so "usable" means the same thing on both surfaces.
    private static func runList(_ args: [String]) -> Never {
        var providerFilter: AccountProvider?
        var dbPath = AccountSync.defaultDBPath

        var i = 0
        while i < args.count {
            switch CLIArgs.matchCommon(args, i) {
            case .db(let value):
                dbPath = value
                i += 1
            case .help:
                printUsage()
                exit(0)
            case .notMatched:
                switch args[i] {
                case "--provider":
                    providerFilter = parseProviderFilter(CLIArgs.requireValue(args, i, option: "--provider"))
                    i += 1
                default:
                    CLIArgs.fail("Unknown option '\(args[i])' (see --help)")
                }
            }
            i += 1
        }

        guard FileManager.default.fileExists(atPath: dbPath) else {
            print("No accounts registered yet (no database at \(dbPath)).")
            exit(0)
        }

        let store = UsageStore(dbPath: dbPath)
        store.loadFromDatabase()

        let db: Connection
        do {
            db = try openDatabase(dbPath, readonly: true)
        } catch {
            CLIArgs.fail("Could not open '\(dbPath)': \(error.localizedDescription)")
        }

        // Status (and only status) comes from `RankingExporter.statusReading`
        // — exactly what `ranking.json` exports — so "usable" means the same
        // thing on both surfaces. The usage figures and reset credits both
        // come from `store.latestUsage`'s own row (#305), so one advice call
        // never mixes two `usage_history` rows.
        let inputs = store.accounts.map { account -> PoolAccountInput in
            PoolAccountInput(
                account: account,
                usage: store.latestUsage[account.id],
                status: RankingExporter.statusReading(db: db, accountId: account.id).status
            )
        }

        var providers = AccountProvider.allCases.filter { provider in
            inputs.contains { $0.account.provider == provider }
        }
        if let filter = providerFilter {
            providers = providers.filter { $0 == filter }
        }
        guard !providers.isEmpty else {
            if let filter = providerFilter {
                print("No accounts for provider \(filter.displayName).")
            } else {
                print("No accounts registered.")
            }
            exit(0)
        }

        for provider in providers {
            let rows = inputs.filter { $0.account.provider == provider }
            let tally = ProviderPoolSummary.tally(rows)
            print("")
            print("\(provider.displayName) — \(ProviderPoolSummary.summaryLine(tally)) (\(tally.total) configured)")
            print("  " + pad("ACCOUNT", 26) + pad("SCOPE", 10) + pad("STATUS", 13) + pad("HEADROOM", 9) + pad("NEXT RESET", 27) + "RESET ADVICE")
            for input in rows {
                print("  " + listRow(input, poolTally: tally))
            }
        }
        print("")
        exit(0)
    }

    /// `--provider` accepts the operator vocabulary — `claude`/`codex`/`zai`,
    /// the names the sibling `claude`/`codex`/`zai` CLIs already answer to —
    /// plus the stored raw values (`anthropic`/`openai`).
    private static func parseProviderFilter(_ value: String) -> AccountProvider {
        switch value.lowercased() {
        case "claude", "anthropic": return .anthropic
        case "codex", "openai": return .openai
        case "zai": return .zai
        default:
            CLIArgs.fail("Unknown provider '\(value)' (expected claude, codex, or zai)")
        }
    }

    /// One table row. Absent identities, never-polled accounts, and stale
    /// readings are named for what they are rather than passing silently as
    /// their last exported status.
    private static func listRow(
        _ input: PoolAccountInput,
        poolTally: ProviderPoolSummary.Tally
    ) -> String {
        let identity = pad(input.account.displayName, 26) + pad(input.account.scope.rawValue, 10)
        if input.account.isAbsent {
            return identity + pad(CodexCLI.absentLabel, 13) + pad("—", 9)
                + pad("—", 27) + "—"
        }
        guard let usage = input.usage else {
            return identity + pad("no reading", 13) + pad("—", 9)
                + pad("—", 27) + "—"
        }
        let stale = AccountFreshness.isStale(lastUpdated: usage.timestamp, pollInterval: 600)
        let status = stale ? "stale" : (input.status ?? "unknown")
        let headroom = usage.rateLimit.headroomScore.map { String(format: "%.0f%%", $0) } ?? "—"
        let reset = usage.rateLimit.gatingWindow?.resetAt.map { formatReset($0) } ?? "—"
        // #303: the shared advisor's verdict for this account, against its
        // provider's pool tally — the record-based entry point the popover
        // tooltip and menubar marker also use (#305), so reset credits come
        // from this same row (`usage.resetCredits`). An unknown reading (e.g.
        // an `app-server` or rollout Codex reading, or a provider whose feed
        // has not landed) says "resets: unknown" — never 0, never silence
        // that reads as 0.
        let advice = ResetAdvisor.displayLine(record: usage, poolTally: poolTally, now: Date()) ?? "—"
        return identity + pad(status, 13) + pad(headroom, 9)
            + pad(reset, 27) + advice
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s + " " : s + String(repeating: " ", count: width - s.count)
    }

    private static func formatReset(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM d HH:mm"
        let interval = date.timeIntervalSinceNow
        // A past reset (a stale row's frozen date) is shown as passed rather
        // than as an imminent "now"/interval, which would read as good news.
        let rel = interval <= 0 ? "passed" : formatInterval(interval)
        return "\(formatter.string(from: date)) (\(rel))"
    }

    private static func printUsage() {
        print("""
            llm-monitor accounts — converge account records + OAuth
            credentials across hosts (see README "Multi-Host Sync").

            Usage:
              llm-monitor accounts push <HOST...> [--dry-run] [--then-loom] [--include-personal]
                                          [--remote-bin <path>] [--ssh-option <opt>] [--db <path>]
              llm-monitor accounts pull <HOST> [--dry-run] [--then-loom] [--include-personal]
                                          [--remote-bin <path>] [--ssh-option <opt>] [--db <path>]
              llm-monitor accounts export [--output <path>] [--compact] [--include-personal] [--db <path>]
              llm-monitor accounts import <path|-> [--dry-run] [--db <path>]
              llm-monitor accounts scope <email-or-id> personal|work [--db <path>]
              llm-monitor accounts list [--provider claude|codex|zai] [--db <path>]

            push is the primary path: it exports this host's bundle in memory
            and streams it over ssh straight into `accounts import -` on each
            HOST. No file containing tokens is created on either side, and
            there is nothing to remember to delete. Every HOST is attempted
            even if an earlier one fails; the exit status is non-zero if any
            host failed.

            pull is the same channel in reverse, for a fresh host bootstrapping
            from a peer: it runs `accounts export` on HOST and imports the
            result here. Exactly one HOST.

            scope sets an account's sharing preference on this host. The default
              is work. Personal accounts still appear locally and are skipped by
              Copy, export, push, and the source of a pull. Pass --include-personal
              to export, push, or pull to include eligible personal accounts.

            --dry-run (push and pull) only checks that each host is reachable
              and that llm-monitor resolves there, reporting its version.
              No bundle is transferred and nothing is written anywhere.
            --then-loom runs `loom-daemon tokens import-from-monitor --shared`
              on whichever host received the bundle, after a successful import
              (the remote host for push, this one for pull).
            --remote-bin <path> names llm-monitor on the far side. Worth
              reaching for first on a "command not found" (exit 127): a
              non-interactive ssh shell does not source the profile that puts
              ~/.local/bin on PATH.
            --ssh-option <opt> is appended to the ssh command line (repeatable),
              e.g. --ssh-option -p --ssh-option 2222. ssh runs with
              BatchMode=yes, so key/agent authentication is required.

            export writes an accounts.json bundle (account records + OAuth
            credentials) to stdout by default, or to --output <path> (written
            with 0600 permissions). The bundle contains plaintext OAuth
            tokens — treat it as a secret. Codex/OpenAI accounts are
            host-local and are never included — register one on each host
            with `llm-monitor codex add --home <path>` instead.

            import upserts accounts by email (falling back to id when email
            is absent), skipping any account whose local last_updated is
            newer than or equal to the imported record — safe to re-run.
            A Codex/OpenAI account present in a bundle from an older version
            is skipped (not an error); it never round-tripped safely.
            Reads from stdin when the path is '-'. Creates
            ~/.llm-monitor/usage.db (and its schema) when the host has
            none yet, so a fresh worker can be converged before it has ever
            polled.

            list prints a read-only per-provider pool summary — usable,
            exhausted, and earliest next reset per provider, one table per
            provider, from the last stored readings. Each row also carries a
            RESET ADVICE column (#303): when the account should spend a stored
            limit reset (the operator triggers resets by hand; the app never
            spends one), a quiet notice when a held reset expires soon, or
            "resets: unknown" when the reading carries no reset data.
            --provider narrows to
            one provider (claude|codex|zai; anthropic/openai accepted too).
            Nothing is polled and nothing is written.

            --db <path> overrides ~/.llm-monitor/usage.db (mainly for
            testing/scripting against an alternate database).
            """)
    }
}
