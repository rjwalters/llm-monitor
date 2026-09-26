import Foundation

/// `llm-monitor claude sync` — map rolled Claude tokens from the token
/// directories (`ClaudeTokenFiles`) onto their accounts, right now, instead of
/// waiting for the app's next poll tick. The same code path the app and the
/// headless daemon run. Prints file names, emails, and org-id prefixes;
/// **never a token**.
///
/// @MainActor for the same reason as `CodexCLI`: the whole CLI runs to
/// completion on the process's initial thread via `dispatchMain()`.
@MainActor
enum ClaudeCLI {
    static func main(_ args: [String]) -> Never {
        guard args.first == "sync" else {
            if let first = args.first, !["--help", "-h", "help"].contains(first) {
                FileHandle.standardError.write(Data("Unknown 'claude' subcommand '\(first)'\n\n".utf8))
                printUsage()
                exit(2)
            }
            printUsage()
            exit(args.isEmpty ? 2 : 0)
        }
        var dbPath: String?
        var dirs: [String] = []
        let rest = Array(args.dropFirst())
        var i = 0
        while i < rest.count {
            switch CLIArgs.matchCommon(rest, i) {
            case .db(let value):
                dbPath = value
                i += 1
            case .help:
                printUsage()
                exit(0)
            case .notMatched:
                guard rest[i] == "--dir" else { CLIArgs.fail("Unknown option '\(rest[i])' (see --help)") }
                dirs.append((CLIArgs.requireValue(rest, i, option: "--dir") as NSString).expandingTildeInPath)
                i += 1
            }
            i += 1
        }
        let directories = dirs.isEmpty ? ClaudeTokenFiles.directories() : dirs
        let files = ClaudeTokenFiles.scan(directories: directories)
        // `abbreviatingWithTildeInPath` is macOS-only; a home path names a user,
        // so it is collapsed to `~` either way.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func tilde(_ p: String) -> String { p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }
        print("Token directories: \(directories.map(tilde).joined(separator: ", "))")
        print("Token files found: \(files.count)")

        let storePath = dbPath
        let store = UsageStore(dbPath: storePath)
        store.ensureDatabase()
        let poller = OAuthPoller(dbPath: storePath)

        Task {
            let results = await poller.syncClaudeTokenFiles(directories: directories)
            if results.isEmpty {
                print("Every token file is already current. Nothing to do.")
            }
            for r in results {
                print("  \(r.success ? "ok  " : "FAIL") \(r.email)\(r.error.map { " — \($0)" } ?? "")")
            }
            let failed = results.filter { !$0.success }.count
            print("Synced \(results.count - failed)/\(results.count) changed token file(s).")
            if let storePath = storePath {
                RankingExporter.exportNow(
                    dbPath: storePath,
                    outputPath: (storePath as NSString).deletingLastPathComponent + "/ranking.json")
            } else {
                RankingExporter.exportNow()
            }
            exit(failed == 0 ? 0 : 1)
        }
        dispatchMain()
    }

    private static func printUsage() {
        print("""
            Usage: llm-monitor claude sync [--dir <path>]... [--db <path>]

            Map rolled Claude OAuth tokens onto their accounts now. Reads every
            <name>.token in the token directories (default: ~/.claude-oauth, then the
            Loom pool ~/.loom/tokens; override with LLM_MONITOR_CLAUDE_TOKEN_DIRS or
            --dir). Each changed token is pinged and stored on the account whose org id
            it reports, keeping history; a row stored under the wrong id is re-keyed.
            accounts.env entries for rolled accounts are updated. The app and the
            headless daemon do this automatically on every poll tick.

            Options:
              --dir <path>   Token directory (repeatable; replaces the default list)
              --db <path>    Use this database instead of ~/.llm-monitor/usage.db
              -h, --help     Show this help
            """)
    }
}
