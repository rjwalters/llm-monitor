import Foundation

/// The signature gate over a staged self-update (#323, operator ruling
/// 2026-11-19): a release archive's SHA-256 checksum proves *integrity*, not
/// *origin* — the digest is fetched from the same GitHub release as the
/// archive, so anyone who can publish a release could ship code this app
/// would otherwise install in one click with quarantine stripped. Before
/// anything replaces the installed bundle, the staged bundle must therefore
/// (1) pass `codesign --verify --deep --strict`, (2) be accepted by Gatekeeper
/// (`spctl --assess --type execute`), and (3) carry a Developer ID **team
/// identifier** equal to the *running* bundle's own — read from the running
/// bundle, never from the release, because provenance continuity is the
/// property being checked.
///
/// Any refusal degrades to update-check-only: the offer stays visible and the
/// user updates from the release page instead. Quarantine is never stripped
/// from an unverified bundle.
///
/// The measurements (`codesign`/`spctl` exits, parsed team identifiers) are
/// taken by `AppUpdater` on macOS; the decision over them is pure and lives
/// here so `SelfTest` can pin every refusal branch offline.
///
/// Portable core: Foundation only, no UI, no subprocesses.
enum SignatureGate {

    /// Everything `decide` needs, already measured by the caller. Team
    /// identifiers are `nil` when the bundle is unsigned, ad-hoc signed, or
    /// its signature could not be read.
    struct Input: Equatable {
        var codesignVerified = false
        var gatekeeperAccepted = false
        var stagedTeamIdentifier: String?
        var runningTeamIdentifier: String?
    }

    /// Why a staged bundle must not be installed — one case per refusal
    /// branch the operator ruling names. `shortReason` is the one-line
    /// explanation the degraded offer shows.
    enum Refusal: Equatable {
        /// `codesign --verify --deep --strict` exited non-zero (or could not
        /// run): the bundle is unsigned, or its signature does not match its
        /// own bytes.
        case codesignVerifyFailed
        /// `spctl --assess --type execute` rejected the bundle: Gatekeeper
        /// would not run it as-is (e.g. Developer ID signed but not
        /// notarized).
        case gatekeeperRejected
        /// The release carries no Developer ID team identifier (unsigned or
        /// ad-hoc): there is no origin to hold accountable, so it is never
        /// one-click installed.
        case releaseNotDeveloperIDSigned
        /// The release is signed, but by a different team than the running
        /// app (`running` nil = the running app itself is unsigned, so no
        /// provenance to continue).
        case teamMismatch(staged: String, running: String?)

        var shortReason: String {
            switch self {
            case .codesignVerifyFailed:
                return "the update failed code-signature verification"
            case .gatekeeperRejected:
                return "macOS Gatekeeper rejected the update"
            case .releaseNotDeveloperIDSigned:
                return "the release is not Developer ID signed"
            case .teamMismatch:
                return "the update's signing team does not match this app's"
            }
        }
    }

    /// The gate's answer: install, or refuse with the branch that fired.
    enum Verdict: Equatable {
        case install
        case refuse(Refusal)
    }

    /// The one rule, in the order the ruling states it: signature verifies,
    /// Gatekeeper accepts, the release is Developer ID signed, and its team
    /// equals the running app's. Anything else refuses — and a refusal is
    /// *not* an install failure: the caller degrades to update-check-only.
    static func decide(_ input: Input) -> Verdict {
        guard input.codesignVerified else { return .refuse(.codesignVerifyFailed) }
        guard input.gatekeeperAccepted else { return .refuse(.gatekeeperRejected) }
        guard let stagedTeam = normalized(input.stagedTeamIdentifier) else {
            return .refuse(.releaseNotDeveloperIDSigned)
        }
        // The running app's team is read from the running bundle; a nil there
        // (this app is unsigned) cannot equal any team, so a signed release
        // still refuses — the one-time update to a signed build happens from
        // the release page, after which self-update works signed-to-signed.
        guard normalized(input.runningTeamIdentifier) == stagedTeam else {
            return .refuse(.teamMismatch(staged: stagedTeam, running: normalized(input.runningTeamIdentifier)))
        }
        return .install
    }

    /// Pull the `TeamIdentifier=` line out of `codesign -dv` output (which the
    /// tool writes to stderr). `not set` — what ad-hoc signatures report —
    /// and anything unparsable yield nil: "no team", never a guessed one.
    static func parseTeamIdentifier(from codesignOutput: String) -> String? {
        for rawLine in codesignOutput.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("TeamIdentifier=") else { continue }
            let value = line.dropFirst("TeamIdentifier=".count).trimmingCharacters(in: .whitespaces)
            return normalized(value)
        }
        return nil
    }

    /// A team identifier is a non-empty string that is not codesign's
    /// "not set" placeholder. Whitespace-only and placeholder values are nil.
    private static func normalized(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if value.caseInsensitiveCompare("not set") == .orderedSame { return nil }
        return value
    }
}
