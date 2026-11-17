import Foundation

/// Format a time interval using a single unit with decreasing precision:
/// "34 min" (up to 90 min), "1.5 hrs" (half-hour granularity), "3 days" (rounded up).
///
/// Lives in the portable core (moved from `UsagePopoverView.swift`, which is
/// `#if os(macOS)`-fenced) so the popover, the provider-tab summary line, and
/// the `accounts list` CLI all speak one interval vocabulary (#297) instead of
/// three re-derivations that could drift apart.
func formatInterval(_ seconds: TimeInterval) -> String {
    if seconds <= 0 { return "now" }
    let minutes = seconds / 60
    if minutes < 90 { return "\(Int(minutes)) min" }
    let hours = seconds / 3600
    if hours < 24 {
        let rounded = (hours * 2).rounded() / 2  // nearest 0.5
        if rounded == rounded.rounded() {
            return "\(Int(rounded)) hrs"
        }
        return String(format: "%.1f hrs", rounded)
    }
    let days = Int(ceil(seconds / 86400))
    return "\(days) \(days == 1 ? "day" : "days")"
}

/// Which slice of the account pool a view is showing (#297): every account, or
/// one provider's. Lives in the portable core so `SelfTest` can pin the
/// stored-value round trip and the stale-tab fallback on both platforms.
///
/// `storedValue` is the `UserDefaults` encoding. A stored provider that no
/// longer has any account falls back to `.all` — a tab for a provider this
/// host no longer configures would otherwise show an empty table with no
/// visible way back.
enum ProviderTab: Equatable, Hashable {
    case all
    case provider(AccountProvider)

    var storedValue: String {
        switch self {
        case .all: return "all"
        case .provider(let provider): return provider.rawValue
        }
    }

    init(stored: String?) {
        guard let raw = stored, raw != "all", let provider = AccountProvider(rawValue: raw) else {
            self = .all
            return
        }
        self = .provider(provider)
    }

    /// The tab, demoted to `.all` when its provider no longer has any
    /// account — the fallback the popover applies to the persisted value at
    /// launch and whenever the provider set changes.
    func validated(among accounts: [Account]) -> ProviderTab {
        guard case .provider(let provider) = self,
              !accounts.contains(where: { $0.provider == provider }) else { return self }
        return .all
    }
}

/// One account's inputs to the provider pool tally (#297).
///
/// Both surfaces produce these from their own source: the macOS popover
/// derives `status` from the stored windows plus the in-memory token state
/// (`ProviderPoolSummary.windowStatus`), while `llm-monitor accounts list`
/// reads exactly what `ranking.json` exports
/// (`RankingExporter.statusReading`). The tally rules themselves are the one
/// shared implementation below.
struct PoolAccountInput {
    let account: Account
    /// Latest stored reading; nil = this account has never reported usage
    /// here (or its reading is suppressed as absent).
    let usage: UsageRecord?
    /// The account's `RankingExporter.mapStatus` result — `available`,
    /// `rate_limited`, `exhausted`, or `blocked`. nil = unknown (no reading).
    let status: String?
}

/// The per-provider pool tally shared by the macOS popover's provider tabs
/// and the `llm-monitor accounts list` CLI (#297): how many accounts of a
/// provider are usable right now, how many are exhausted, and when the
/// earliest of the rest comes back.
///
/// **Usable** is the one existing rule, composed from pieces the app already
/// trusts: the account is not absent (`Account.isAbsent`), its latest reading
/// is not stale (`AccountFreshness`, the cause-independent #148 backstop — a
/// frozen figure must not present as current here either), it has a reading
/// at all (an account that has never reported anything is *unknown*, never
/// "plenty of capacity" — the same principle as `headroomScore`'s nil), and
/// its status is `available`. **Exhausted** applies the same eligibility to a
/// status of `exhausted`. **nextReset** is the earliest
/// `RateLimitSnapshot.gatingWindow` reset strictly in the future among the
/// non-usable accounts — past resets are not advertised as upcoming ones.
///
/// Portable core: no AppKit / SwiftUI / Combine / os.Logger — builds on Linux.
enum ProviderPoolSummary {
    /// Counts for one pool slice (all accounts, or one provider's).
    struct Tally: Equatable {
        var usable = 0
        var exhausted = 0
        var total = 0
        /// Earliest gating reset among non-usable accounts that report one;
        /// nil when none of them does.
        var nextReset: Date? = nil
    }

    /// The popover's status rule: no stored status blob exists on the display
    /// side, so exhaustion is derived from the window percentages themselves
    /// (`RateLimitWindow.isExhausted` reads both a `rejected` status and the
    /// 100% cap) and fed through the same `RankingExporter.mapStatus` decision
    /// table the export path uses. nil when there is no reading — unknown,
    /// never "available".
    static func windowStatus(for usage: UsageRecord?, credentialBlocked: Bool) -> String? {
        guard let usage = usage else { return nil }
        let windows = usage.rateLimit
        let session = windows.session.map { $0.isExhausted ? "rejected" : "allowed" }
        let weekly = windows.weekly.map { $0.isExhausted ? "rejected" : "allowed" }
        return RankingExporter.mapStatus(
            overallStatus: nil,
            sessionStatus: session,
            weeklyStatus: weekly,
            credentialActive: !credentialBlocked,
            credentialRejected: false
        )
    }

    /// Tally one pool slice. `pollInterval` feeds the staleness threshold
    /// exactly as the popover's freshness dot derives it (#148); the CLI uses
    /// the same 600 s default the poll loop ships with.
    static func tally(
        _ inputs: [PoolAccountInput],
        pollInterval: TimeInterval = 600,
        now: Date = Date()
    ) -> Tally {
        var result = Tally()
        result.total = inputs.count
        for input in inputs {
            let stale = AccountFreshness.isStale(
                lastUpdated: input.usage?.timestamp,
                pollInterval: pollInterval,
                now: now
            )
            // Eligibility: a frozen reading (stale) and a placeholder row
            // (absent) are presented as current by neither bucket; no reading
            // at all is unknown, not capacity.
            let eligible = !input.account.isAbsent && !stale && input.usage != nil
            if eligible, input.status == "available" {
                result.usable += 1
            } else {
                if eligible, input.status == "exhausted" {
                    result.exhausted += 1
                }
                // Every non-usable account's gating reset is a candidate —
                // including an eligible-but-rate-limited one, which is
                // exactly the "comes back soon" case the line exists for.
                // Past resets are not advertised as upcoming ones.
                if let reset = input.usage?.rateLimit.gatingWindow?.resetAt,
                   reset > now,
                   result.nextReset == nil || reset < result.nextReset! {
                    result.nextReset = reset
                }
            }
        }
        return result
    }

    /// Per-provider tallies. A provider with no accounts has no entry — that
    /// absence *is* the empty-provider answer, and is what keeps a persisted
    /// tab for a departed provider falling back to `All`.
    static func tallyByProvider(
        _ inputs: [PoolAccountInput],
        pollInterval: TimeInterval = 600,
        now: Date = Date()
    ) -> [AccountProvider: Tally] {
        var grouped: [AccountProvider: [PoolAccountInput]] = [:]
        for input in inputs {
            grouped[input.account.provider, default: []].append(input)
        }
        var result: [AccountProvider: Tally] = [:]
        for (provider, inputs) in grouped {
            result[provider] = tally(inputs, pollInterval: pollInterval, now: now)
        }
        return result
    }

    /// The shared summary line: "14 usable · 3 exhausted · next reset in 2 hrs".
    /// Exhausted and reset segments are omitted when they have nothing to say,
    /// so a fully-idle provider reads as a bare usable count.
    static func summaryLine(_ tally: Tally, now: Date = Date()) -> String {
        var parts: [String] = ["\(tally.usable) usable"]
        if tally.exhausted > 0 { parts.append("\(tally.exhausted) exhausted") }
        if let reset = tally.nextReset {
            parts.append("next reset \(formatInterval(reset.timeIntervalSince(now)))")
        }
        return parts.joined(separator: " · ")
    }
}
