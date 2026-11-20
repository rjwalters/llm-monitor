import Foundation

/// The relaunch handoff of a self-update (#323) and the bookkeeping that ties
/// a recovery backup to the install that created it.
///
/// Three failure modes the Judge found in the first version, all pure logic
/// that therefore lives here (portable core, Foundation only) so `SelfTest`
/// can drive them on Linux:
///
/// 1. **The helper launched too early and nobody handled a bad launch.** The
///    detached shell used to `open` the new bundle after a bounded number of
///    polls even while the old process still held the instance lock, and once
///    the old app had quit, a failing launch left a broken install and no
///    record. `relaunchScript` now (a) never launches while the old process
///    is alive — it rolls the install back instead — and (b) when the
///    launcher fails, restores the previous bundle at the installed path,
///    relaunches it, and writes a one-line reason to a failure file that the
///    restored app reports at its next start.
/// 2. **Any running copy deleted the recovery backup.** The backup used a
///    fixed sibling name that every GUI launch removed. Each replacement now
///    has a uniquely named backup recorded in a `Pending` file in the data
///    directory, and only an app running *at the installed path, at the
///    expected version* may remove it (`backupToRemove`). A second copy
///    started from the same directory matches neither condition.
/// 3. **A launch the OS accepted was taken for a launch that worked.** The
///    helper now waits (bounded) for the new app to confirm it reached
///    startup, by writing this install's token to `update-confirmed`; with
///    no confirmation it restores and relaunches the previous bundle.
enum UpdateHandoff {

    static let pendingFileName = "update-pending.json"
    static let failureFileName = "update-failure.txt"
    static let confirmFileName = "update-confirmed"

    /// What one replacement left behind: where the new bundle was installed,
    /// the transaction token that names its backup, and the version the new
    /// bundle must report before that backup may go. The backup's location
    /// is **derived** from the installed path and the token
    /// (`backupPath(installedPath:token:)`), never stored, so a stale or
    /// malformed record cannot point deletion at an unrelated directory.
    struct Pending: Codable, Equatable {
        let installedPath: String
        let token: String
        let expectedVersion: String

        /// The backup this record names, or nil when the record is malformed.
        var backupPath: String? {
            UpdateHandoff.backupPath(installedPath: installedPath, token: token)
        }
    }

    /// A unique backup name per replacement, beside the installed bundle
    /// (same volume, so the rename is atomic).
    static func backupName(token: String) -> String { ".LLMMonitor.app.old-\(token)" }

    /// A token this code generated: exactly eight hex digits. Anything else
    /// (path separators, `..`, empty) is not a transaction identifier.
    static func isValidToken(_ token: String) -> Bool {
        token.utf8.count == 8 && token.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66)
        }
    }

    /// The sibling backup for an install, nil for an invalid token or an
    /// installed path that is not an `.app` bundle path.
    static func backupPath(installedPath: String, token: String) -> String? {
        guard isValidToken(token), installedPath.hasSuffix(".app") else { return nil }
        let installed = URL(fileURLWithPath: installedPath)
        guard !installed.lastPathComponent.isEmpty else { return nil }
        return installed.deletingLastPathComponent()
            .appendingPathComponent(backupName(token: token), isDirectory: true).path
    }

    // MARK: Pending record

    static func writePending(_ pending: Pending, to path: String) throws {
        let data = try JSONEncoder().encode(pending)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    static func readPending(at path: String) -> Pending? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(Pending.self, from: data)
    }

    static func clearPending(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// The backup this running app may delete, or nil. Only the bundle that
    /// was installed at `pending.installedPath` *and* reports
    /// `pending.expectedVersion` has confirmed the replacement worked; any
    /// other process — a second copy beside the backup, a rolled-back old
    /// version — must leave the recovery copy alone. The path is derived
    /// from the verified install location and a validated token.
    static func backupToRemove(
        pending: Pending, runningBundlePath: String, runningVersion: String
    ) -> String? {
        guard canonical(runningBundlePath) == canonical(pending.installedPath),
              runningVersion == pending.expectedVersion else { return nil }
        return pending.backupPath
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
    }

    // MARK: Startup confirmation

    /// Tell the helper this install reached startup: the file holds exactly
    /// this transaction's token, so a leftover from another install never
    /// satisfies the helper.
    static func writeConfirmation(token: String, to path: String) throws {
        try Data(token.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    // MARK: Failure file

    /// Read-and-remove the failure the helper recorded, if any. One line,
    /// whitespace-trimmed; empty reads as nothing.
    static func takeFailure(at path: String) -> String? {
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : line
    }

    // MARK: Helper script

    /// POSIX `sh` body for the detached helper. The paths travel as
    /// positional arguments, never interpolated into the text (#327):
    ///
    ///     $1 pid of the running app      $6 maximum polls
    ///     $2 installed bundle path       $7 seconds between polls
    ///     $3 backup bundle path          $8 pending-record file
    ///     $4 failure file                $9 startup-confirmation file
    ///     $5 launcher (`/usr/bin/open`)  ${10} this install's token
    ///
    /// Outcomes: the old process exits, the launcher succeeds *and* the new
    /// app writes `${10}` into `$9` within the poll budget (exit 0; the
    /// backup stays for the new app to remove); the old process never exits
    /// (nothing is launched, the previous bundle is restored, exit 1); the
    /// launcher fails, or the app it started never confirms (previous bundle
    /// restored and relaunched, exit 1). Every failure writes one line to
    /// `$4`. The pending record is dropped only when the backup it names has
    /// been moved back into place: an unrestored backup keeps its record.
    static let relaunchScript = """
        pid=$1; installed=$2; backup=$3; failure=$4; launcher=$5
        max=$6; delay=$7; pending=$8; confirm=$9; token=${10}
        restore() {
          rm -rf "$installed" && mv "$backup" "$installed"
        }
        polls=0
        while kill -0 "$pid" 2>/dev/null; do
          polls=$((polls + 1))
          if [ "$polls" -ge "$max" ]; then
            if restore; then
              printf '%s\n' 'the running app did not quit, so the update was rolled back' > "$failure"
              rm -f "$pending"
            else
              printf '%s\n' 'the running app did not quit and the previous version could not be restored; the backup is beside the installed app' > "$failure"
            fi
            exit 1
          fi
          sleep "$delay"
        done
        rm -f "$confirm"
        why='the updated app could not be launched'
        if "$launcher" "$installed"; then
          waited=0
          while [ "$(cat "$confirm" 2>/dev/null)" != "$token" ]; do
            waited=$((waited + 1))
            if [ "$waited" -ge "$max" ]; then
              why='the updated app did not finish starting'
              break
            fi
            sleep "$delay"
          done
          if [ "$(cat "$confirm" 2>/dev/null)" = "$token" ]; then
            rm -f "$confirm"
            exit 0
          fi
        fi
        if restore; then
          printf '%s; the previous version was restored\n' "$why" > "$failure"
          rm -f "$pending"
          "$launcher" "$installed"
        else
          printf '%s and the previous version could not be restored; the backup is beside the installed app\n' "$why" > "$failure"
        fi
        exit 1
        """
}
