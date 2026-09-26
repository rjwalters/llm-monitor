import Foundation

/// Claude OAuth tokens delivered as one file per account, read at launch and
/// on every poll tick so a rolled token is picked up without a restart.
///
/// ### Why a directory, not this app's own store
///
/// After the 2026-09-26 leak response, the pool is minted and distributed
/// **outside** this app (`2am/scripts/claude-oauth-roll.py`): each new token
/// lands in chezmoi (`~/.claude-oauth/<name>.token` on operator Macs), in SSM
/// for the Linux workers, and in every host's Loom pool (`~/.loom/tokens/`,
/// which the workers fill from SSM and the other Macs fill with `pool-sync`).
/// This app is a **reader** of those tokens, not their source. Reading the
/// directories keeps it free of an AWS dependency while still reaching SSM's
/// values on the workers, through the pool.
///
/// ### Directories, in precedence order
///
/// `$LLM_MONITOR_CLAUDE_TOKEN_DIRS` (colon-separated) replaces the default:
///
/// 1. `~/.claude-oauth` — the chezmoi-delivered copy (operator Macs).
/// 2. The Loom shared pool — `$LOOM_SHARED_TOKENS_DIR` (an explicitly empty
///    value disables it, as in loom-daemon), else `~/.loom/tokens`.
///
/// The first directory that holds a given `<name>.token` wins.
///
/// ### Identity
///
/// A token file does not name its account. **The account is always the org id
/// the token itself reports** when pinged; that is the only identity this app
/// keys Claude rows on. The email, when known, comes from the Loom pool's
/// `index.json` (`accounts[].file` → `accounts[].email`) and is used only as a
/// fallback to find an existing row whose stored id is wrong (see
/// `ClaudeTokenFiles.resolveTarget`).
///
/// **No token is ever logged or printed** — only file names and org-id
/// prefixes.
///
/// Portable core: no AppKit / SwiftUI / Combine / os.Logger — builds on Linux.
struct ClaudeTokenFile: Equatable {
    /// File stem, e.g. `agent18-2amlogic`.
    let name: String
    /// From the pool index, when the name is listed there.
    let email: String?
    let token: String
}

enum ClaudeTokenFiles {
    static func directories(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        func expand(_ p: String) -> String { (p as NSString).expandingTildeInPath }
        if let raw = AppPaths.environment("CLAUDE_TOKEN_DIRS", in: environment) {
            return raw.split(separator: ":").map { expand(String($0).trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = [(home as NSString).appendingPathComponent(".claude-oauth")]
        if let pool = environment["LOOM_SHARED_TOKENS_DIR"] {
            let trimmed = pool.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { dirs.append(expand(trimmed)) }
        } else {
            dirs.append((home as NSString).appendingPathComponent(".loom/tokens"))
        }
        return dirs
    }

    /// A token file's content, or nil unless it is a single Claude OAuth token.
    /// Whitespace anywhere is stripped (a token never contains any, and a
    /// copy-pasted file may carry a trailing newline or a wrapped line).
    static func parseToken(_ content: String) -> String? {
        let token = content.filter { !$0.isWhitespace }
        guard token.hasPrefix("sk-ant-"), token.count >= 40 else { return nil }
        return token
    }

    /// `name → email` from every directory's `index.json` (Loom pool shape:
    /// `{"accounts":[{"name":…,"file":…,"email":…}]}`). Earlier directories
    /// win on conflict.
    static func emailIndex(directories: [String]) -> [String: String] {
        var map: [String: String] = [:]
        for dir in directories {
            let path = (dir as NSString).appendingPathComponent("index.json")
            guard let data = FileManager.default.contents(atPath: path),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accounts = root["accounts"] as? [[String: Any]] else { continue }
            for entry in accounts {
                guard let email = (entry["email"] as? String)?.trimmingCharacters(in: .whitespaces),
                      email.contains("@") else { continue }
                var keys: [String] = []
                if let name = entry["name"] as? String { keys.append(name) }
                if let file = entry["file"] as? String, file.hasSuffix(".token") {
                    keys.append(String(file.dropLast(".token".count)))
                }
                for key in keys where map[key] == nil { map[key] = email }
            }
        }
        return map
    }

    /// Every usable `<name>.token` across `directories`, first directory
    /// winning per name, sorted by name. Hidden files and unreadable or
    /// malformed files are skipped.
    static func scan(directories: [String] = directories()) -> [ClaudeTokenFile] {
        let emails = emailIndex(directories: directories)
        var seen = Set<String>()
        var files: [ClaudeTokenFile] = []
        for dir in directories {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for entry in names.sorted() where entry.hasSuffix(".token") && !entry.hasPrefix(".") {
                let name = String(entry.dropLast(".token".count))
                guard !name.isEmpty, !seen.contains(name) else { continue }
                let path = (dir as NSString).appendingPathComponent(entry)
                guard let content = try? String(contentsOfFile: path, encoding: .utf8),
                      let token = parseToken(content) else { continue }
                seen.insert(name)
                files.append(ClaudeTokenFile(name: name, email: emails[name], token: token))
            }
        }
        return files.sorted { $0.name < $1.name }
    }

    // MARK: - Mapping a token onto an account

    enum Target: Equatable {
        /// The reported org already has a row: roll its credential in place
        /// (history is keyed on the id, so it is kept automatically).
        case roll(accountId: String)
        /// No row has the reported org, but the file's email names an existing
        /// Claude row stored under a different id: that stored id is wrong.
        /// Move the row, and all its history, to the id the token reports.
        case rekey(from: String, to: String)
        /// A new account.
        case create(accountId: String)
    }

    /// Where a token that reports `reportedOrg` belongs. Pure, so the one rule
    /// that decides whether history is kept is testable offline.
    static func resolveTarget(
        reportedOrg: String, fileEmail: String?,
        existingIds: Set<String>, claudeIdByEmail: [String: String]
    ) -> Target {
        if existingIds.contains(reportedOrg) { return .roll(accountId: reportedOrg) }
        if let email = fileEmail?.lowercased(), let stored = claudeIdByEmail[email], stored != reportedOrg {
            return .rekey(from: stored, to: reportedOrg)
        }
        return .create(accountId: reportedOrg)
    }

    // MARK: - accounts.env

    /// Rewrite `ACCOUNT_KEY_N` for every `ACCOUNT_EMAIL_N` in `keysByEmail`,
    /// leaving every other line (comments, order, other providers' entries)
    /// untouched. Returns nil when nothing changed. Pure, for the self-test.
    ///
    /// Exists because loom-daemon's `tokens bootstrap` ranks this app's
    /// `accounts.env` first on a Mac: a file still holding revoked tokens would
    /// be copied back over a freshly rolled pool.
    static func rewriteAccountsEnv(_ content: String, keysByEmail: [String: String]) -> (content: String, replaced: Int)? {
        let wanted = Dictionary(uniqueKeysWithValues: keysByEmail.map { ($0.key.lowercased(), $0.value) })
        var emailByIndex: [String: String] = [:]
        var nonAnthropic = Set<String>()
        let lines = content.components(separatedBy: "\n")
        func field(_ t: String, _ prefix: String) -> (index: String, value: String)? {
            guard t.hasPrefix(prefix), let eq = t.firstIndex(of: "=") else { return nil }
            return (String(t[t.index(t.startIndex, offsetBy: prefix.count)..<eq]),
                    String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces))
        }
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let f = field(t, "ACCOUNT_EMAIL_") { emailByIndex[f.index] = f.value.lowercased() }
            // One email can be both a Claude account and another provider's
            // entry (robb@ is a z.ai key too): only Anthropic entries — no
            // provider line, or `anthropic` — may receive a Claude token.
            if let f = field(t, "ACCOUNT_PROVIDER_"),
               AccountProvider(stored: f.value) != .anthropic { nonAnthropic.insert(f.index) }
        }
        var replaced = 0
        let out = lines.map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("ACCOUNT_KEY_"), let eq = t.firstIndex(of: "=") else { return line }
            let idx = String(t[t.index(t.startIndex, offsetBy: "ACCOUNT_KEY_".count)..<eq])
            guard !nonAnthropic.contains(idx), let email = emailByIndex[idx], let key = wanted[email] else { return line }
            let current = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard current != key else { return line }
            replaced += 1
            return "ACCOUNT_KEY_\(idx)=\(key)"
        }
        return replaced > 0 ? (out.joined(separator: "\n"), replaced) : nil
    }
}
