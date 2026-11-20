import Foundation

/// The relaunch handoff of a self-update (#323) and the bookkeeping that ties
/// a recovery backup to the install that created it.
///
/// Two failure modes the Judge found in the first version, both pure logic
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
enum UpdateHandoff {

    static let pendingFileName = "update-pending.json"
    static let failureFileName = "update-failure.txt"

    /// What one replacement left behind: where the new bundle was installed,
    /// the backup of what it replaced, and the version the new bundle must
    /// report before that backup may go.
    struct Pending: Codable, Equatable {
        let installedPath: String
        let backupPath: String
        let expectedVersion: String
    }

    /// A unique backup name per replacement, beside the installed bundle
    /// (same volume, so the rename is atomic).
    static func backupName(token: String) -> String { ".LLMMonitor.app.old-\(token)" }

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
    /// version — must leave the recovery copy alone.
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
    ///     $1 pid of the running app      $5 launcher (`/usr/bin/open`)
    ///     $2 installed bundle path       $6 maximum polls
    ///     $3 backup bundle path          $7 seconds between polls
    ///     $4 failure file                $8 pending-record file
    ///
    /// Outcomes: the old process exits and the launcher succeeds (exit 0, the
    /// backup stays until the new app confirms it); the old process never
    /// exits (nothing is launched, the previous bundle is restored, exit 1);
    /// the launcher fails (previous bundle restored and relaunched, exit 1).
    /// Both failures write one line to `$4` and drop the pending record,
    /// since the backup it names has been moved back into place.
    static let relaunchScript = """
        restore() {
          rm -rf "$1" && mv "$2" "$1"
        }
        polls=0
        while kill -0 "$1" 2>/dev/null; do
          polls=$((polls + 1))
          if [ "$polls" -ge "$6" ]; then
            if restore "$2" "$3"; then
              printf '%s\\n' 'the running app did not quit, so the update was rolled back' > "$4"
            else
              printf '%s\\n' 'the running app did not quit and the previous version could not be restored; the backup is beside the installed app' > "$4"
            fi
            rm -f "$8"
            exit 1
          fi
          sleep "$7"
        done
        if "$5" "$2"; then
          exit 0
        fi
        if restore "$2" "$3"; then
          printf '%s\\n' 'the updated app could not be launched; the previous version was restored' > "$4"
          rm -f "$8"
          "$5" "$2"
        else
          printf '%s\\n' 'the updated app could not be launched and the previous version could not be restored; the backup is beside the installed app' > "$4"
        fi
        exit 1
        """
}
