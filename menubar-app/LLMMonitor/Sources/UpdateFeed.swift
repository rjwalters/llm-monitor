import Foundation

/// Pure selection of an in-app update candidate (#323) from a GitHub
/// Releases payload, plus the version arithmetic behind "strictly newer".
/// Everything here is offline and deterministic: it turns bytes from
/// `api.github.com/repos/2AMLogic/llm-monitor/releases/latest` (or a fixture
/// in `SelfTest`) into at most one offer, and every rule it applies is one
/// the curated scope pinned:
///
/// * **Stable only** — prerelease/draft flags suppress the offer, and so does
///   a prerelease-*shaped* tag (`v2.11.0-rc1`) even when mis-flagged stable,
///   because `Version.parse` rejects anything that is not plain dot-separated
///   nonnegative integers.
/// * **Strictly newer** — equal or older releases clear the offer
///   (`.uptodate`), never re-offer it.
/// * **Verifiable** — the `LLMMonitor.zip` asset must exist and carry a
///   `sha256:<64 hex>` digest, or there is nothing to offer: the updater
///   refuses to install bytes it cannot check.
/// * **HTTPS only** — a non-https `browser_download_url` is not an offer.
///
/// A feed that cannot be read at all is `.failed` (a short reason for the
/// popover), which is deliberately distinct from `.uptodate`: a failed
/// re-check must not clear an offer a previous check already validated.
///
/// Portable core: Foundation only, no UI, no network.
enum ReleaseFeed {
    /// The one macOS archive asset the updater consumes — the same artifact
    /// Quick Install hands out (both Linux binaries are ignored; they serve
    /// `install-linux.sh --from-release`, which is out of scope for the
    /// in-app updater).
    static let macOSAssetName = "LLMMonitor.zip"

    enum Outcome: Equatable {
        /// A strictly newer stable release with a verifiable macOS archive.
        case offer(UpdateInfo)
        /// The feed was read and there is nothing to offer; any standing
        /// offer should be cleared.
        case uptodate
        /// The check itself failed (network, HTTP, unreadable payload). Any
        /// standing offer stays; `reason` is the short popover line.
        case failed(String)
    }

    /// Select the update candidate for `currentVersion` from one GitHub
    /// release object. `payload`/`errorText` are the raw results of the feed
    /// request, so callers (and fixtures) never pre-parse anything.
    static func selection(currentVersion: String, payload: Data?, errorText: String?) -> Outcome {
        if let errorText, !errorText.isEmpty {
            return .failed("check failed — \(errorText)")
        }
        guard let payload else { return .failed("no response from the release feed") }
        guard let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
            return .failed("unreadable release feed")
        }
        guard let tagName = json["tag_name"] as? String, !tagName.isEmpty else {
            // A tagless body is what GitHub answers for a missing release
            // (e.g. the 404 of a repo with no releases at all) — a check
            // failure to report, not "up to date".
            return .failed("release feed has no version tag")
        }
        // Malformed or non-stable tags offer nothing (and clear any standing
        // offer): never guess what "release-2026" or "2.11.0-rc1" means.
        guard let version = strippedTag(tagName) else { return .uptodate }
        guard (json["prerelease"] as? Bool) != true, (json["draft"] as? Bool) != true else {
            return .uptodate
        }
        guard let assets = json["assets"] as? [[String: Any]] else { return .uptodate }
        guard let asset = assets.first(where: { ($0["name"] as? String) == macOSAssetName }) else {
            return .uptodate
        }
        guard let digest = parseDigest(asset["digest"] as? String) else { return .uptodate }
        guard let download = asset["browser_download_url"] as? String,
              let url = URL(string: download), url.scheme?.lowercased() == "https" else {
            return .uptodate
        }
        guard Version.isNewer(version, than: currentVersion) else { return .uptodate }
        // A refused update must open the release notes, even if html_url
        // is missing. The validated stable tag is safe as a path component.
        let page = "https://github.com/\(AppVersion.repoOwner)/\(AppVersion.repoName)/releases/tag/\(tagName)"
        return .offer(UpdateInfo(
            version: version,
            releaseURL: page,
            archiveURL: download,
            sha256: digest
        ))
    }

    /// `v2.10.0` → `2.10.0`, nil when the tag is not version-shaped. Only a
    /// single leading `v`/`V` is stripped; `release-2.10.0` stays malformed.
    static func strippedTag(_ tag: String) -> String? {
        var text = tag
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        return Version.parse(text) != nil ? text : nil
    }

    /// GitHub writes asset digests as `sha256:<64 hex>`. Returns the lowercase
    /// hex part, or nil for anything else — a missing digest, a different
    /// algorithm (`md5:…`), or a wrong length. Callers treat nil as
    /// "unverifiable, so not an offer".
    static func parseDigest(_ text: String?) -> String? {
        guard let text else { return nil }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].lowercased() == "sha256" else { return nil }
        let hex = parts[1].lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return hex
    }
}

/// Strict semantic version parsing for release tags. A version here is plain
/// dot-separated nonnegative integers (`2.10.0`); anything else — suffixes,
/// signs, whitespace, letter components — is malformed and yields nil, so no
/// caller can accidentally rank `2.1.0-rc1` as `2.1.0` (the failure mode of
/// `compactMap { Int($0) }`, which silently drops the junk component).
enum Version {
    static func parse(_ text: String) -> [Int]? {
        guard !text.isEmpty else { return nil }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var components: [Int] = []
        components.reserveCapacity(parts.count)
        for part in parts {
            // ASCII-only digits before Int(): keeps localized digit shapes
            // and signs out, and Int's own nil-on-overflow rejects absurdly
            // long components rather than trapping.
            guard part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part), value >= 0 else { return nil }
            components.append(value)
        }
        return components
    }

    /// True when `candidate` is strictly newer than `current`, compared
    /// component-wise with zero padding (`2.10` > `2.9.9`; `2.2` == `2.2.0`).
    /// Malformed input on either side is never newer.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let new = parse(candidate), let old = parse(current) else { return false }
        let count = max(new.count, old.count)
        for i in 0..<count {
            let a = i < new.count ? new[i] : 0
            let b = i < old.count ? old[i] : 0
            if a != b { return a > b }
        }
        return false
    }
}
