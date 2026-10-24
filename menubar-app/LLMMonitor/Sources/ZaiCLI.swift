import Foundation

/// `llm-monitor zai import|add|list` — register z.ai GLM Coding Plan keys
/// and show their quota. One-shot, no `--headless` needed, works on Linux.
///
/// Keys are read from `~/.zai/coding-plan-<label>.env` (the chezmoi-managed
/// directory; `$LLM_MONITOR_ZAI_DIR` overrides it) and from Loom's shared
/// API-key pool `~/.loom/api-keys/zai/<label>.env` (see
/// `ZaiKeyFile.directories`), one `ZAI_API_KEY=…` line per file. **A key is
/// never printed or logged** — only labels, emails, and derived percentages.
///
/// @MainActor for the same reason as `CodexCLI`: the whole CLI runs to
/// completion on the process's initial thread via `dispatchMain()`.
@MainActor
enum ZaiCLI {
    static func main(_ args: [String]) -> Never {
        guard let sub = args.first else {
            printUsage()
            exit(2)
        }
        switch sub {
        case "import":
            runImport(Array(args.dropFirst()))
        case "add":
            runAdd(Array(args.dropFirst()))
        case "list":
            runList(Array(args.dropFirst()))
        case "--help", "-h", "help":
            printUsage()
            exit(0)
        default:
            FileHandle.standardError.write(Data("Unknown 'zai' subcommand '\(sub)'\n\n".utf8))
            printUsage()
            exit(2)
        }
    }

    // MARK: - zai import

    private static func runImport(_ args: [String]) -> Never {
        var dbPath: String?
        var directories = ZaiKeyFile.directories()
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
                guard args[i] == "--dir" else { CLIArgs.fail("Unknown option '\(args[i])' (see --help)") }
                directories = [CLIArgs.requireValue(args, i, option: "--dir")]
                i += 1
            }
            i += 1
        }

        let files = ZaiKeyFile.scan(directories: directories)
        guard !files.isEmpty else {
            CLIArgs.fail("No z.ai key files (coding-plan-<label>.env or <label>.env with a ZAI_API_KEY line) in "
                         + directories.joined(separator: ", "))
        }

        let storePath = dbPath
        let store = UsageStore(dbPath: storePath)
        store.ensureDatabase()
        let poller = OAuthPoller(dbPath: storePath)

        Task {
            var failed = 0
            for file in files {
                let (_, error) = await poller.addZaiAccount(apiKey: file.apiKey, email: file.email, label: file.label)
                if let error = error {
                    failed += 1
                    FileHandle.standardError.write(Data("  \(file.label): \(error)\n".utf8))
                } else {
                    print(importLine(file))
                }
            }
            print("Registered \(files.count - failed)/\(files.count) z.ai account(s).")
            exportRanking(storePath)
            printTable(storePath)
            exit(failed == 0 ? 0 : 1)
        }
        dispatchMain()
    }

    // MARK: - zai add

    private static func runAdd(_ args: [String]) -> Never {
        var dbPath: String?
        var label: String?
        var email: String?
        var keyFile: String?
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
                case "--email":
                    email = CLIArgs.requireValue(args, i, option: "--email")
                    i += 1
                case "--key-file":
                    keyFile = CLIArgs.requireValue(args, i, option: "--key-file")
                    i += 1
                default:
                    guard label == nil, !args[i].hasPrefix("-") else {
                        CLIArgs.fail("Unknown option '\(args[i])' (see --help)")
                    }
                    label = args[i]
                }
            }
            i += 1
        }
        guard let label = label else { CLIArgs.fail("zai add needs a <label> (see --help)") }

        // The key comes from a file or stdin, never argv (argv is visible in `ps`).
        let content: String
        if let keyFile = keyFile, keyFile != "-" {
            guard let text = try? String(contentsOfFile: keyFile, encoding: .utf8) else {
                CLIArgs.fail("Could not read \(keyFile)")
            }
            content = text
        } else {
            content = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        }
        // Accept either a `ZAI_API_KEY=…` env file or a bare key.
        let parsed = ZaiKeyFile.parse(content, label: label)
        let bare = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let apiKey = parsed?.apiKey ?? (bare.contains("\n") || bare.contains("=") ? nil : bare),
              !apiKey.isEmpty else {
            CLIArgs.fail("No ZAI_API_KEY line (or bare key) found in the input")
        }
        let resolvedEmail = email ?? parsed?.email

        let storePath = dbPath
        let store = UsageStore(dbPath: storePath)
        store.ensureDatabase()
        let poller = OAuthPoller(dbPath: storePath)

        Task {
            let (_, error) = await poller.addZaiAccount(apiKey: apiKey, email: resolvedEmail, label: label)
            if let error = error { CLIArgs.fail(error) }
            print("Registered z.ai account \(label)\(resolvedEmail.map { " (\($0))" } ?? "").")
            exportRanking(storePath)
            printTable(storePath)
            exit(0)
        }
        dispatchMain()
    }

    // MARK: - zai list

    private static func runList(_ args: [String]) -> Never {
        var dbPath: String?
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
                CLIArgs.fail("Unknown option '\(args[i])' (see --help)")
            }
            i += 1
        }
        let store = UsageStore(dbPath: dbPath)
        store.ensureDatabase()
        printTable(dbPath)
        exit(0)
    }

    // MARK: - Output

    /// The last stored reading for every z.ai account. Reads the database
    /// rather than the network, so it shows what the poll loop last saw.
    private static func printTable(_ storePath: String?) {
        let store = UsageStore(dbPath: storePath)
        store.loadFromDatabase()
        let accounts = store.accounts.filter { $0.provider == .zai }
        guard !accounts.isEmpty else {
            print("No z.ai accounts registered. Add them with: llm-monitor zai import")
            return
        }
        // One decimal under 10%, so a seat that has spent 150 of 140k weekly
        // credits reads 0.1%, not an idle-looking 0% (#249).
        func pct(_ value: Double?) -> String { value.map(UsagePercentText.string) ?? "—" }
        print("")
        print(pad("ACCOUNT", 16) + pad("EMAIL", 26) + pad("PLAN", 6) + pad("5H", 7) + pad("WEEK", 7) + "WEEK RESETS")
        for account in accounts {
            let usage = store.latestUsage[account.id]
            let windows = usage?.rateLimit
            let reset = windows?.weekly?.resetAt.map { formatReset($0) } ?? "—"
            print(pad(account.accountName ?? account.id, 16) + pad(account.email ?? "—", 26)
                  + pad(account.plan ?? "—", 6) + pad(pct(windows?.session?.usedPercent), 7)
                  + pad(pct(windows?.weekly?.usedPercent), 7) + reset)
        }
    }

    /// One `zai import` progress line: label and email only, never the key.
    static func importLine(_ file: ZaiKeyFile) -> String {
        "  \(file.label)  \(file.email ?? "(no email)")  registered"
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s + " " : s + String(repeating: " ", count: width - s.count)
    }

    private static func formatReset(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM d HH:mm"
        let hours = date.timeIntervalSinceNow / 3600
        let rel = hours <= 0 ? "now" : hours < 48 ? String(format: "in %.0fh", hours) : String(format: "in %.1fd", hours / 24)
        return "\(formatter.string(from: date)) (\(rel))"
    }

    private static func exportRanking(_ storePath: String?) {
        if let storePath = storePath {
            RankingExporter.exportNow(
                dbPath: storePath,
                outputPath: (storePath as NSString).deletingLastPathComponent + "/ranking.json"
            )
        } else {
            RankingExporter.exportNow()
        }
    }

    private static func printUsage() {
        print("""
            Usage: llm-monitor zai <subcommand> [options]

            Register z.ai (GLM Coding Plan) API keys and show their quota.

            Subcommands:
              import [--dir <path>]     Register every z.ai key file found in, in order:
                                          ~/.zai/coding-plan-<label>.env ($LLM_MONITOR_ZAI_DIR)
                                          Loom's pool ~/.loom/api-keys/zai/<label>.env
                                            ($LOOM_SHARED_API_KEYS_DIR; empty disables it)
                                        $LLM_MONITOR_ZAI_DIRS (colon-separated) or --dir
                                        replaces that list. Each file holds one
                                        ZAI_API_KEY=… line; an "(account: <email>)" header
                                        comment names the account. A label in the pool's
                                        .disabled is skipped; the same key in two places
                                        is one account. The app also does this at launch.
              add <label> [--key-file <path>|-] [--email <addr>]
                                        Register one key, read from a file or stdin
                                        (never from the command line).
              list                      Show each z.ai account's last stored 5h / weekly usage.

            Common options:
              --db <path>               Use this database instead of ~/.llm-monitor/usage.db
              -h, --help                Show this help
            """)
    }
}
