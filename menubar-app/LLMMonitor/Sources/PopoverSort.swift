import Foundation

// MARK: - Sorting vocabulary
//
// `SummarySort`, `SortDirection`, `extraUsageUrgency` and `tokenStatusRank`
// used to live in the macOS-only popover. They are pure value logic with no
// AppKit/SwiftUI dependency, and #333 moves the sort pipeline itself into the
// portable core so it compiles — and is directly covered by `selftest` — on
// every platform, not just where the popover renders.

/// The column the summary table can be sorted by.
enum SummarySort: String {
    case account, headroom, sessionPercent, sessionReset, weeklyPercent, weeklyReset, fablePercent, extraUsage, fresh, token

    /// First-click direction for this column — "best first" intuition.
    var defaultDirection: SortDirection {
        switch self {
        case .headroom: return .desc   // higher score = better, show first
        default: return .asc           // lower % / sooner reset / fresher / better-status first
        }
    }
}

enum SortDirection: String {
    case asc, desc
    func toggled() -> SortDirection { self == .asc ? .desc : .asc }
}

/// Sort key for the Extra-usage column. Lower = more attention needed.
/// nil (no probe yet) sorts last.
func extraUsageUrgency(_ usage: UsageRecord?) -> Double? {
    guard let usage = usage else { return nil }
    switch usage.extraUsageState {
    case .unknown:        return nil
    case .empty:          return 0            // depleted — needs a recharge
    case .percent(let r): return 1 + r        // metered: lower remaining sorts first
    case .active:         return 200          // drawing (unmetered/unlimited) — fine
    case .ready:          return 300          // available, unused
    case .off:            return 400          // not configured
    }
}

/// Lower rank = "better" status (valid first, missing last).
func tokenStatusRank(_ status: TokenStatus) -> Int {
    switch status {
    case .valid: return 0
    case .refreshing: return 1
    case .expired: return 2
    case .revoked: return 3
    case .error: return 4
    case .drifted: return 5
    case .missing: return 6
    }
}

// MARK: - Popover sort pipeline (#333)

/// Sorts the summary-table rows, one call per render.
///
/// The popover's former comparator (`compareRows`) re-derived work that is
/// fixed for the duration of a single sort: `effectiveSortBy` rebuilt the
/// provider set up to three times per comparison, window columns constructed
/// `UsageRecord.rateLimit` — parsing up to two ISO-8601 stamps — on every
/// comparison plus again in the Headroom recovery tiebreak, the Token column
/// rebuilt its lookup dictionary per comparison, and reset keys took
/// `timeIntervalSinceNow` at a different instant per comparison, so rows with
/// byte-identical reset timestamps could order nondeterministically instead of
/// reaching the name tiebreak (#333).
///
/// The shape here is decorate-sort-undecorate, following #330/#331:
///
/// - Column visibility is resolved **once per sort** from the caller's
///   `SummaryColumns.shows` answers — hidden Premium/Extra selections fall
///   back to Headroom exactly as before (#227's rule).
/// - Each populated row's sort key is computed **once**, from **one**
///   `rateLimit` snapshot for the window-based columns; Headroom reuses that
///   snapshot for both its score and its gating-reset recovery tiebreak, and
///   columns that need no snapshot skip the work entirely.
/// - Reset/fresh keys and the recovery tiebreak are measured against a
///   **single reference instant** (`now`), so identical timestamps compare
///   exactly equal and reach the deterministic name tiebreak instead of being
///   split by clock skew mid-sort.
/// - The comparator compares prepared values with the current direction and
///   tie rules; rows without data still sort last in both directions, and the
///   total `stableTiebreak` keeps the order stable.
///
/// Ordering is preserved byte-for-byte from the former comparator (pinned by
/// `SelfTest`'s PopoverSort cases and the store-side
/// `testSortedAccountsForPopoverTieBreak`); the provider-tab filter upstream
/// still runs after the sort and stays order-preserving.
enum PopoverSort {
    /// A row prepared for sorting: the account, its latest reading (nil = no
    /// data), the selected column's key, and — for Headroom only — the
    /// recovery instant its gating reset implies.
    struct PreparedRow {
        let account: Account
        let usage: UsageRecord?
        let key: Double?
        let recovery: TimeInterval?
    }

    /// The sort actually applied: a column hidden by #227 cannot be the sort
    /// key the user sees selected, so it falls back to the default.
    static func effectiveSort(
        sortBy: SummarySort, premiumColumnShown: Bool, extraColumnShown: Bool
    ) -> SummarySort {
        switch sortBy {
        case .fablePercent where !premiumColumnShown,
             .extraUsage where !extraColumnShown:
            return .headroom
        default:
            return sortBy
        }
    }

    /// Final tiebreak when a column's primary comparison is exactly equal
    /// (common for freshly-added or idle accounts that all read 0%): order by
    /// natural display name instead of falling through to arbitrary
    /// insertion/UUID order, and only fall back to account id when even the
    /// display names are indistinguishable, so the order stays total and
    /// stable.
    static func stableTiebreak(_ a: Account, _ b: Account) -> Bool {
        let cmp = NaturalSort.compare(a.displayName, b.displayName)
        if cmp != .orderedSame { return cmp == .orderedAscending }
        return a.id < b.id
    }

    static func sortedRows(
        accounts: [Account],
        latestUsage: [String: UsageRecord],
        sortBy: SummarySort,
        direction: SortDirection,
        premiumColumnShown: Bool,
        extraColumnShown: Bool,
        tokenStatusByAccount: [String: TokenStatus],
        now: Date = Date()
    ) -> [(account: Account, usage: UsageRecord?)] {
        let effective = effectiveSort(
            sortBy: sortBy, premiumColumnShown: premiumColumnShown, extraColumnShown: extraColumnShown)

        var prepared: [PreparedRow] = []
        prepared.reserveCapacity(accounts.count)
        for account in accounts {
            let usage = latestUsage[account.id]
            var key: Double?
            var recovery: TimeInterval?
            switch effective {
            case .headroom:
                // The one snapshot per populated row: score and gating reset
                // both read it, so the ISO-8601 parses happen once, not per
                // comparison.
                let snapshot = usage?.rateLimit
                key = snapshot?.headroomScore
                recovery = snapshot?.gatingWindow?.resetAt?.timeIntervalSince(now)
            case .sessionPercent:
                // Read through the shared window model: a provider that reports no
                // session window yields nil here and sorts last, rather than
                // pretending to be at 0%.
                key = usage?.rateLimit.session?.usedPercent
            case .weeklyPercent:
                key = usage?.rateLimit.weekly?.usedPercent
            case .sessionReset:
                if let reset = usage?.rateLimit.session?.resetAt { key = reset.timeIntervalSince(now) }
            case .weeklyReset:
                if let reset = usage?.rateLimit.weekly?.resetAt { key = reset.timeIntervalSince(now) }
            case .fresh:
                // Data age in seconds (lower = fresher). nil usage → nil → sorts last.
                key = usage.map { -$0.timestamp.timeIntervalSince(now) }
            case .fablePercent:
                // Sort by Fable used (asc = most remaining last, matching other % columns).
                key = usage?.fablePercent
            case .extraUsage:
                // Ascending = "needs attention first": empty → low balance → in use → ready → off.
                key = extraUsageUrgency(usage)
            case .token:
                key = Double(tokenStatusRank(tokenStatusByAccount[account.id] ?? .missing))
            case .account:
                break  // no numeric key; the comparator sorts by name directly
            }
            prepared.append(PreparedRow(account: account, usage: usage, key: key, recovery: recovery))
        }

        prepared.sort { a, b in
            // Account name sorts naturally: digit runs compare by value, so
            // agent-10 follows agent-9 instead of landing next to agent-1.
            if effective == .account {
                let cmp = NaturalSort.compare(a.account.displayName, b.account.displayName)
                if cmp == .orderedSame { return stableTiebreak(a.account, b.account) }
                return direction == .asc
                    ? (cmp == .orderedAscending)
                    : (cmp == .orderedDescending)
            }

            switch (a.key, b.key) {
            case (nil, nil): return stableTiebreak(a.account, b.account)
            case (nil, _):   return false          // nil rows go last
            case (_, nil):   return true
            case let (.some(x), .some(y)):
                if x != y { return direction == .asc ? (x < y) : (x > y) }
                // Tiebreak for the Headroom column. Equal scores are the norm at
                // the bottom of the table, where every capped account reads 0 —
                // so order those by how soon they come back. The gating reset is
                // the weekly one once the week is spent, and the session one
                // otherwise; a session window rolling over in minutes means
                // nothing to an account that is out for the week.
                if effective == .headroom {
                    switch (a.recovery, b.recovery) {
                    case (nil, nil): break
                    case (nil, _):   return false      // unknown recovery goes last
                    case (_, nil):   return true
                    case let (.some(xRec), .some(yRec)):
                        if xRec == yRec { break }
                        // Coming back sooner is the better row, so it leads under
                        // the "best first" direction and trails when flipped.
                        return direction == .desc ? (xRec < yRec) : (xRec > yRec)
                    }
                }
                return stableTiebreak(a.account, b.account)
            }
        }
        return prepared.map { ($0.account, $0.usage) }
    }
}
