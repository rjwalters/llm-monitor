import Foundation

/// Claude limit resets (#285): the `cedar_ember` object the claude.ai usage
/// call returns (`GET /api/organizations/{org}/usage?cedar_ember=1`, or
/// `api.anthropic.com/api/oauth/usage?cedar_ember=1` for a full-login
/// token). **Undocumented and unverified against a claude.ai-route reply**;
/// the shape is from the operator's 2026-11-17 OAuth test.
///
/// Read-only and offline by design (operator ruling 2026-11-18): the app makes
/// no call to claude.ai or the OAuth route and stores no web session. The only
/// input is a JSON body an operator pastes into `llm-monitor claude resets
/// import`. Only the grant fields below are kept — never an org id, token, or
/// any other identity field from the body.
///
/// Every field is optional: a missing field is *unknown*, never 0. A `null`
/// (or absent) `cedar_ember` is "no reset data", not "zero resets".
///
/// Portable core: Foundation only.
enum ClaudeResetCredits {
    struct Grant: Codable, Equatable, Sendable {
        var id: String?
        var label: String?
        /// `weekly` | `full` as observed; kept verbatim.
        var type: String?
        var resetsLeft: Int?
        var resetsTotal: Int?
        /// ISO 8601 expiry, verbatim from the body.
        var endsAt: String?
        var usableNow: Bool?
        /// Windows the grant clears (e.g. `five_hour`, `seven_day`).
        var clears: [String]?

        enum CodingKeys: String, CodingKey {
            case id, label, type, clears
            case resetsLeft = "resets_left"
            case resetsTotal = "resets_total"
            case endsAt = "ends_at"
            case usableNow = "usable_now"
        }

        var endsAtDate: Date? { UsageRecord.parseISO(endsAt) }
    }

    /// The latest stored reading for one account.
    struct Reading: Equatable, Sendable {
        var grants: [Grant]
        var observedAt: Date
    }

    enum ParseResult: Equatable {
        /// `cedar_ember` was null or absent: the body carried no reset data.
        case noResetData
        case grants([Grant])
    }

    enum ParseError: Error, Equatable {
        case notJSON
    }

    /// Accepts either the whole usage body (with a `cedar_ember` key) or the
    /// `cedar_ember` object itself (recognised by its `grants` array).
    static func parse(_ data: Data) throws -> ParseResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.notJSON
        }
        let object: [String: Any]
        if let nested = root["cedar_ember"] as? [String: Any] {
            object = nested
        } else if root["cedar_ember"] == nil, root["grants"] is [Any] {
            object = root
        } else {
            return .noResetData
        }
        guard let rawGrants = object["grants"] as? [Any] else { return .noResetData }
        var grants: [Grant] = []
        for case let g as [String: Any] in rawGrants {
            grants.append(Grant(
                id: g["id"] as? String,
                label: g["label"] as? String,
                type: g["type"] as? String,
                resetsLeft: intValue(g["resets_left"]),
                resetsTotal: intValue(g["resets_total"]),
                endsAt: g["ends_at"] as? String,
                usableNow: g["usable_now"] as? Bool,
                clears: (g["clears"] as? [Any])?.compactMap { $0 as? String }
            ))
        }
        return .grants(grants)
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double, d == d.rounded() { return Int(d) }
        return nil
    }

    // MARK: - Storage encoding (the trimmed JSON kept in the table)

    static func encode(_ grants: [Grant]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(grants) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ json: String?) -> [Grant]? {
        guard let json = json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([Grant].self, from: data)
    }

    // MARK: - Advisor mapping

    /// The `ResetAdvisor.Resets` a stored reading reports. nil reading =
    /// all-unknown. `count` is the sum of `resets_left` over grants that
    /// report it (nil if none does); `usableNow` is true when any grant has
    /// `resets_left > 0 && usable_now`, false when something was reported but
    /// nothing qualifies, nil when nothing was reported; `endsAt` is the
    /// earliest expiry among grants still holding a reset.
    static func resets(from reading: Reading?) -> ResetAdvisor.Resets {
        guard let reading = reading else { return ResetAdvisor.Resets() }
        let counted = reading.grants.compactMap { $0.resetsLeft }
        let count: Int? = counted.isEmpty ? (reading.grants.isEmpty ? 0 : nil) : counted.reduce(0, +)
        let anyUsable = reading.grants.contains { ($0.resetsLeft ?? 0) > 0 && $0.usableNow == true }
        let anyReported = reading.grants.isEmpty
            || reading.grants.contains { $0.resetsLeft != nil || $0.usableNow != nil }
        let endsAt = reading.grants
            .filter { ($0.resetsLeft ?? 0) > 0 }
            .compactMap { $0.endsAtDate }
            .min()
        return ResetAdvisor.Resets(
            usableNow: anyUsable ? true : (anyReported ? false : nil),
            count: count,
            endsAt: endsAt
        )
    }

    /// True when the pasted reading is too old to present as current.
    static func isStale(_ reading: Reading, now: Date = Date()) -> Bool {
        AccountFreshness.isStale(lastUpdated: reading.observedAt, pollInterval: 600, now: now)
    }

    /// One line for `accounts list`/tooltips: count, scope and expiry, with the
    /// reading's age (labelled stale when old). "resets: unknown" for nil.
    static func summaryLine(_ reading: Reading?, now: Date = Date()) -> String {
        guard let reading = reading else { return "resets: unknown" }
        let held = reading.grants.filter { ($0.resetsLeft ?? 0) > 0 }
        var text: String
        if held.isEmpty {
            text = reading.grants.contains { $0.resetsLeft != nil } || reading.grants.isEmpty
                ? "resets: 0 held" : "resets: unknown"
        } else {
            let parts = held.map { g -> String in
                var s = "\(g.resetsLeft ?? 0) \(g.type ?? "reset")"
                if let ends = g.endsAtDate, ends > now {
                    s += " (expires in \(formatInterval(ends.timeIntervalSince(now))))"
                } else if g.endsAtDate != nil {
                    s += " (expired)"
                }
                return s
            }
            text = "resets: " + parts.joined(separator: ", ")
        }
        let age = max(0, now.timeIntervalSince(reading.observedAt))
        text += isStale(reading, now: now)
            ? " [stale: pasted \(formatInterval(age)) ago]"
            : " [pasted \(formatInterval(age)) ago]"
        return text
    }
}
