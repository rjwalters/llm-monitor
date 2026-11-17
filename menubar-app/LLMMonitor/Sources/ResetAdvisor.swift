import Foundation

/// Flags which account should spend a stored limit reset, read-only (#303).
/// The operator spends resets by hand (operator, 2026-11-17: "it is probably
/// fine for us to manually trigger resets; for now we just want to flag when
/// resets should be used") — nothing in this file or its callers makes any
/// network call at all; every input is a value already stored by the poller.
///
/// The policy is the one approved for Z.ai on 2026-11-16, generalised. Flag
/// "use a reset" for an account holding an unused reset that is usable now,
/// and either:
///
/// 1. **Spent and far from recovery** — the weekly window is at least 97%
///    used, the natural reset is more than 24 h away, and the provider's pool
///    is short (fewer than 75% of that provider's accounts usable); or
/// 2. **Expiring** — the reset expires within 14 days and the weekly window
///    is at least 97% used (pool shortage not required).
///
/// Never a flag to clear only a 5-hour block: every rule gates on the weekly
/// window, and a full session window alone enters no rule. Separately, a
/// quieter "expires soon, unused" notice fires for a reset within 48 h of its
/// expiry regardless of usage, so nothing lapses unseen.
///
/// Unknown stays unknown: a nil input means "this reading did not report it",
/// never 0 — an account whose credential cannot read reset data (e.g. a
/// Claude token rejected on scope, #285) advises nothing and surfaces read
/// "resets: unknown". Codex carries no expiry (#298), so until the Claude
/// feed lands only rule 1 can fire from live data.
///
/// Portable core: Foundation only, no AppKit / SwiftUI / Combine / os.Logger
/// — builds and tests on Linux.
enum ResetAdvisor {
    /// The thresholds, in one place — the operator tuned these once, so no
    /// surface may restate them as literals.
    enum ResetPolicy {
        /// Rule gate: the weekly window is at least this used (percent, 0–100).
        static let weeklyUsedPercent: Double = 97.0
        /// Rule 1: the natural weekly reset is strictly more than this far away.
        static let recoveryHorizon: TimeInterval = 24 * 3600
        /// Rule 1: the provider pool is short when strictly fewer than this
        /// fraction of its accounts are usable (`ProviderPoolSummary.Tally`).
        static let poolShortFraction: Double = 0.75
        /// Rule 2: the reset expires within this horizon.
        static let expiringHorizon: TimeInterval = 14 * 86400
        /// The quiet notice: a held reset expires within this horizon.
        static let noticeHorizon: TimeInterval = 48 * 3600
    }

    /// The reset state one account's latest reading reports. Every field nil
    /// means **unknown** — the reading carried no reset data — never 0. The
    /// Codex feed (#298) fills `usableNow`/`count`; `endsAt` awaits the
    /// Claude `cedar_ember` feed (#285), which will only have to fill this
    /// same struct.
    struct Resets: Sendable, Equatable {
        /// An applicable reset could be spent right now
        /// (`applicable_available_count > 0`).
        var usableNow: Bool?
        /// How many unused resets the account holds (`available_count`).
        var count: Int?
        /// When the stored reset lapses. nil for Codex (the endpoint reports
        /// no expiry), populated by the Claude feed.
        var endsAt: Date?

        /// False only when the reading reported *nothing* about resets at
        /// all — the "resets: unknown" case.
        var isKnown: Bool { usableNow != nil || count != nil }

        /// Whether at least one unused reset is held: a known positive count,
        /// or usability implying at least one exists.
        var holdsUnused: Bool { (count ?? 0) > 0 || usableNow == true }
    }

    /// The window state the rules gate on, from one account's latest reading.
    /// Percents are 0–100, as stored in `usage_history`.
    struct Usage: Sendable, Equatable {
        /// The weekly window's used percent. The gate for both rules.
        var weeklyUsedPercent: Double?
        /// When the weekly window recovers on its own (rule 1's horizon).
        var weeklyResetsAt: Date?
        /// The 5-hour window's used percent, carried **only** so the exclusion
        /// is expressible: a full 5h block never justifies a reset, and no
        /// rule below consults this field. The unit test pins that.
        var sessionUsedPercent: Double?
    }

    /// The provider pool's state: what fraction of that provider's accounts
    /// are usable right now (`ProviderPoolSummary.Tally` — reused, never
    /// recounted). nil when the pool is empty or unmeasured.
    struct Pool: Sendable, Equatable {
        var usableFraction: Double?

        init(usableFraction: Double?) {
            self.usableFraction = usableFraction
        }

        /// From the shared pool tally (#297). A tally with no accounts yields
        /// nil — an unmeasured pool never reads as "not short".
        init(tally: ProviderPoolSummary.Tally?) {
            guard let tally = tally, tally.total > 0 else {
                self.usableFraction = nil
                return
            }
            self.usableFraction = Double(tally.usable) / Double(tally.total)
        }
    }

    enum State: Sendable, Equatable {
        case none
        /// Rule 1: spend one because the pool is short and the window is far
        /// from recovering.
        case useNow
        /// Rule 2: spend one because it lapses soon.
        case expiring
        /// The quiet 48 h notice — nothing lapses unseen.
        case expiresSoon

        /// `ranking.json`'s `reset_advice.state` spelling.
        var jsonKey: String {
            switch self {
            case .none: return "none"
            case .useNow: return "use_now"
            case .expiring: return "expiring"
            case .expiresSoon: return "expires_soon"
            }
        }
    }

    struct Advice: Sendable, Equatable {
        let state: State
        /// Operator-readable cause; nil only for `.none`.
        let reason: String?
        /// The reset's own expiry when the reading reports one (Claude only,
        /// today); nil for Codex, which reports none.
        let expiresAt: Date?

        static let none = Advice(state: .none, reason: nil, expiresAt: nil)
    }

    /// The Codex mapping (#298), spelled once so the >0 rule cannot drift
    /// between surfaces. nil credits (an `app-server`/rollout reading, a
    /// non-OpenAI account) map to the all-unknown struct.
    static func resets(from credits: OpenAIUsageResponse.ResetCredits?) -> Resets {
        Resets(
            usableNow: credits?.applicableAvailableCount.map { $0 > 0 },
            count: credits?.availableCount,
            endsAt: nil
        )
    }

    /// The one rule. Pure: same inputs, same advice, no clock reads.
    static func advise(usage: Usage, resets: Resets, pool: Pool, now: Date) -> Advice {
        guard resets.isKnown else { return .none }

        // A reset whose expiry has already passed is gone — it cannot be
        // spent, and it is not "expiring soon" either. Advise nothing.
        if let endsAt = resets.endsAt, endsAt <= now { return .none }

        // Rule 2 — expiring (checked before rule 1: when both hold, the
        // expiry is the binding urgency, since the reset is gone entirely
        // after `ends_at`).
        if let endsAt = resets.endsAt {
            let until = endsAt.timeIntervalSince(now)
            if until > 0, until <= ResetPolicy.expiringHorizon,
               resets.usableNow == true,
               let weekly = usage.weeklyUsedPercent,
               weekly >= ResetPolicy.weeklyUsedPercent {
                return Advice(
                    state: .expiring,
                    reason: "weekly \(percentText(weekly))% used — stored reset expires in \(formatInterval(until))",
                    expiresAt: endsAt
                )
            }
        }

        // Rule 1 — spent, far from recovery, pool short.
        if resets.usableNow == true,
           let weekly = usage.weeklyUsedPercent,
           weekly >= ResetPolicy.weeklyUsedPercent,
           let resetAt = usage.weeklyResetsAt,
           resetAt.timeIntervalSince(now) > ResetPolicy.recoveryHorizon,
           let fraction = pool.usableFraction,
           fraction < ResetPolicy.poolShortFraction {
            return Advice(
                state: .useNow,
                reason: "weekly \(percentText(weekly))% used, window recovers in \(formatInterval(resetAt.timeIntervalSince(now))), pool \(poolPercentText(fraction))% usable — spend a stored reset",
                expiresAt: resets.endsAt
            )
        }

        // The quiet notice — regardless of usage, so a held reset never
        // lapses unseen. Fires only when no rule above already said "use it":
        // a flagged reset is by definition not lapsing silently.
        if let endsAt = resets.endsAt {
            let until = endsAt.timeIntervalSince(now)
            if until > 0, until <= ResetPolicy.noticeHorizon, resets.holdsUnused {
                return Advice(
                    state: .expiresSoon,
                    reason: "unused stored reset expires in \(formatInterval(until))",
                    expiresAt: endsAt
                )
            }
        }

        return .none
    }

    /// What a surface should say about one account's resets, or nil for
    /// nothing at all. The shared wording for the CLI column and the popover
    /// tooltip; surfaces that render state (badge colour, marker) switch on
    /// `advise` directly.
    static func displayLine(usage: Usage, resets: Resets, pool: Pool, now: Date) -> String? {
        guard resets.isKnown else { return "resets: unknown" }
        let advice = advise(usage: usage, resets: resets, pool: pool, now: now)
        return advice.state == .none ? nil : advice.reason
    }

    /// Advisor inputs from one stored reading plus its provider's tally — the
    /// wiring every surface repeats otherwise (#303).
    static func advise(record: UsageRecord, poolTally: ProviderPoolSummary.Tally?, now: Date) -> Advice {
        let inputs = recordInputs(record, poolTally: poolTally)
        return advise(usage: inputs.usage, resets: inputs.resets, pool: inputs.pool, now: now)
    }

    /// The record-based `displayLine` — the same shared wording, over the same
    /// single row's figures, that the popover tooltip, the menubar marker and
    /// `accounts list`'s advice column all render (#305). Reset credits come
    /// from the record itself (`record.resetCredits`), so one `advise` call
    /// never mixes figures from two `usage_history` rows.
    static func displayLine(record: UsageRecord, poolTally: ProviderPoolSummary.Tally?, now: Date) -> String? {
        let inputs = recordInputs(record, poolTally: poolTally)
        return displayLine(usage: inputs.usage, resets: inputs.resets, pool: inputs.pool, now: now)
    }

    private static func recordInputs(
        _ record: UsageRecord,
        poolTally: ProviderPoolSummary.Tally?
    ) -> (usage: Usage, resets: Resets, pool: Pool) {
        (
            usage: Usage(
                weeklyUsedPercent: record.weeklyAllPercent,
                weeklyResetsAt: UsageRecord.parseISO(record.weeklyReset),
                sessionUsedPercent: record.sessionPercent
            ),
            resets: resets(from: record.resetCredits),
            pool: Pool(tally: poolTally)
        )
    }

    private static func percentText(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    private static func poolPercentText(_ fraction: Double) -> String {
        String(Int((fraction * 100).rounded()))
    }
}
