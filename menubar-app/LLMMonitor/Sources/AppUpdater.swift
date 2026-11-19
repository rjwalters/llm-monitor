#if os(macOS)
import AppKit
import Darwin
import Foundation

/// One-click self-install of a newer release (#323): download the
/// `LLMMonitor.zip` asset over HTTPS, verify the bytes against the release's
/// SHA-256 digest, stage and validate the bundle, replace the installed
/// bundle at its current path, and relaunch once this instance has exited.
/// The relaunch handoff waits for this process to disappear before opening
/// the new bundle, which is strictly after `InstanceLock`'s flock releases
/// at process exit — so the new version starts cleanly, never as a rejected
/// "already running".
///
/// Nothing here runs unless the user clicks "Update now"; the periodic check
/// is read-only (`UpdateChecker.checkForUpdates`). Every failure path leaves
/// the running version in place — a failed replace restores the previous
/// bundle from its same-volume backup — and reports a short reason through
/// `UpdateChecker.installState`, which is what the popover strip and the
/// chart overlay render.
///
/// `@MainActor`: driven by popover/chart clicks on the app's one main-thread
/// UI path, and mutates `UpdateChecker` state. The blocking child waits
/// (`ditto`, `xattr`) suspend via `Task.sleep` polling on the pattern
/// `LoomAccountsCheck.run` established — never `Process.waitUntilExit()`,
/// which spins a CFRunLoop and hangs off the main thread.
@MainActor
final class AppUpdater {

    enum InstallError: Error {
        case notHTTPS
        case downloadFailed(String)
        case digestMismatch
        case extractionFailed(Int32)
        case quarantineClearFailed(Int32)
        case bundleMissing
        case bundleIdentityUnexpected(identifier: String, version: String, expectedIdentifier: String, expectedVersion: String)
        case notAnInstalledBundle
        case replaceFailed(String)
        case restoreFailed(String)
        case relaunchFailed(String)

        /// The one-line reason every surface shows. Deliberately short: the
        /// popover has one caption-height line for it, and the actionable
        /// detail is in `debug.log`.
        var shortReason: String {
            switch self {
            case .notHTTPS:
                return "the download URL is not HTTPS"
            case .downloadFailed(let why):
                return "download failed (\(why))"
            case .digestMismatch:
                return "the downloaded archive did not match the release checksum"
            case .extractionFailed(let status):
                return "could not extract the downloaded archive (ditto exit \(status))"
            case .quarantineClearFailed(let status):
                return "could not prepare the downloaded app (xattr exit \(status))"
            case .bundleMissing:
                return "the archive did not contain LLMMonitor.app"
            case .bundleIdentityUnexpected:
                return "the archive is not this app (bundle identifier or version mismatch)"
            case .notAnInstalledBundle:
                return "this is not an installed app bundle — reinstall from LLMMonitor.zip to self-update"
            case .replaceFailed(let why):
                return "could not replace the installed app (\(why))"
            case .restoreFailed(let backupPath):
                return "could not restore the previous app; backup kept at \(backupPath)"
            case .relaunchFailed(let why):
                return "installed, but could not relaunch (\(why))"
            }
        }
    }

    static let shared = AppUpdater()

    /// Name of the previous-version backup kept beside the installed bundle
    /// while a replacement settles; the *new* version removes it at launch
    /// (`cleanUpAfterUpdate`), which is the earliest proof it runs.
    static let backupBundleName = ".LLMMonitor.app.old"
    static let stagingDirectoryName = "update-staging"

    private var inFlight = false
    private let flog = FileLogger.shared

    var stagingPath: String { AppPaths.path(Self.stagingDirectoryName) }

    /// The entry point both surfaces' "Update now" buttons call.
    func installLatest(from checker: UpdateChecker) {
        guard let info = checker.updateAvailable else { return }
        install(info, checker: checker)
    }

    /// One install at a time: a second click while an install is running is
    /// ignored, not queued (#323: repeated clicks cannot start overlapping
    /// installs). `inFlight` stays true across the relaunch handoff, and is
    /// reset only on failure — a successful install ends the process.
    func install(_ info: UpdateInfo, checker: UpdateChecker = .shared) {
        guard !inFlight else { return }
        inFlight = true
        checker.beginInstall()
        Task { await run(info, checker: checker) }
    }

    private func run(_ info: UpdateInfo, checker: UpdateChecker) async {
        do {
            let fm = FileManager.default
            // Fresh staging under the data directory; a crashed attempt's
            // leftovers are dropped here and again at the next launch.
            try? fm.removeItem(atPath: stagingPath)
            try fm.createDirectory(atPath: stagingPath, withIntermediateDirectories: true)

            let installedURL = try requireInstalledBundle()

            // 1. Download — HTTPS only, defense-in-depth on top of the
            //    selection rule that already refused non-https URLs.
            guard let archiveURL = URL(string: info.archiveURL),
                  archiveURL.scheme?.lowercased() == "https" else {
                throw InstallError.notHTTPS
            }
            let (data, response) = try await URLSession.shared.data(from: archiveURL)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw InstallError.downloadFailed("HTTP \(http.statusCode)")
            }
            let archivePath = (stagingPath as NSString).appendingPathComponent(ReleaseFeed.macOSAssetName)
            try data.write(to: URL(fileURLWithPath: archivePath))

            // 2. Verify the exact bytes against the release's digest before
            //    anything looks inside the archive.
            checker.updateInstallProgress("Verifying…")
            let actualDigest = SHA256.hex(data)
            guard actualDigest == info.sha256.lowercased() else {
                throw InstallError.digestMismatch
            }

            // 3. Extract. `ditto` preserves executable bits and permissions
            //    that a generic unzip pipeline can drop.
            checker.updateInstallProgress("Extracting…")
            let extractPath = (stagingPath as NSString).appendingPathComponent("extracted")
            try fm.createDirectory(atPath: extractPath, withIntermediateDirectories: true)
            let extractStatus = try await Self.runTool("/usr/bin/ditto", ["-x", "-k", archivePath, extractPath])
            guard extractStatus == 0 else { throw InstallError.extractionFailed(extractStatus) }

            // 4. Validate: exactly this app, exactly the offered version — a
            //    mis-published archive must never replace a running install.
            let stagedBundle = URL(fileURLWithPath: extractPath)
                .appendingPathComponent("LLMMonitor.app", isDirectory: true)
            guard fm.fileExists(atPath: stagedBundle.path) else { throw InstallError.bundleMissing }
            checker.updateInstallProgress("Preparing…")
            try await Self.clearQuarantine(at: stagedBundle)
            try Self.validateStagedBundle(stagedBundle, expectedVersion: info.version)

            // 5. Replace at the installed path, keeping a same-volume backup
            //    to restore from if the swap fails.
            checker.updateInstallProgress("Installing…")
            try Self.replaceInstalledBundle(installedURL, with: stagedBundle)

            // 6. Relaunch: a detached helper waits for this process to exit —
            //    which is what releases the instance lock — then opens the
            //    new bundle. Success never returns from here.
            checker.updateInstallProgress("Relaunching…")
            do {
                try await Self.relaunchAfterExit(opening: installedURL)
            } catch {
                // No helper is coming: put the previous bundle back so the
                // installed app matches the version still running, then
                // surface the relaunch failure.
                Self.undoReplace(installedURL)
                throw error
            }

            // `terminate(_:)` exits the process; reaching this line means it
            // was refused (no delegate cancels termination today).
            throw InstallError.relaunchFailed("the app did not terminate")
        } catch {
            let reason = (error as? InstallError)?.shortReason ?? error.localizedDescription
            flog.warning("self-update failed: \(reason)", category: "Update")
            checker.failInstall(reason)
            try? FileManager.default.removeItem(atPath: stagingPath)
            inFlight = false
        }
    }

    /// The installed app bundle this process runs from. Debug builds
    /// (`.build/debug/LLMMonitor`) are not `.app` bundles at all — replacing
    /// one makes no sense, so it is a typed refusal, not a best-effort.
    private func requireInstalledBundle() throws -> URL {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app" else { throw InstallError.notAnInstalledBundle }
        return url
    }

    /// Strip the quarantine attribute URLSession stamps on downloads. This
    /// app ships unsigned, so a quarantined replacement would put the user
    /// back into the right-click→Open Gatekeeper dance the updater exists to
    /// remove — this step is required, not cosmetic. `xattr -c` succeeds
    /// (exit 0) when there is nothing to clear; there are no signatures or
    /// other attributes worth preserving on an unsigned bundle.
    private static func clearQuarantine(at bundle: URL) async throws {
        let status = try await runTool("/usr/bin/xattr", ["-r", "-c", bundle.path])
        guard status == 0 else { throw InstallError.quarantineClearFailed(status) }
    }

    /// The staged bundle must advertise this app's bundle identifier and the
    /// exact version the feed offered. This is also what catches a release
    /// whose `Info.plist` version was never bumped alongside its tag.
    private static func validateStagedBundle(_ bundle: URL, expectedVersion: String) throws {
        let plistPath = bundle.appendingPathComponent("Contents/Info.plist").path
        let plistData = FileManager.default.contents(atPath: plistPath)
        let plist: [String: Any]? = plistData.flatMap { data in
            guard let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return nil }
            return value as? [String: Any]
        }
        let identifier = plist?["CFBundleIdentifier"] as? String ?? "(missing)"
        let version = plist?["CFBundleShortVersionString"] as? String ?? "(missing)"
        let expectedIdentifier = Bundle.main.bundleIdentifier ?? "com.llm-monitor.app"
        guard identifier == expectedIdentifier, version == expectedVersion else {
            throw InstallError.bundleIdentityUnexpected(
                identifier: identifier, version: version,
                expectedIdentifier: expectedIdentifier, expectedVersion: expectedVersion)
        }
    }

    /// Swap `staged` into `installed`'s path: rename the running bundle aside
    /// (same volume, atomic), move the staged one in, and restore the backup
    /// if that move fails — the running binary keeps working throughout; it
    /// stays mapped even once its directory entry is renamed away.
    private static func replaceInstalledBundle(_ installed: URL, with staged: URL) throws {
        let fm = FileManager.default
        let backup = installed.deletingLastPathComponent()
            .appendingPathComponent(AppUpdater.backupBundleName, isDirectory: true)
        try? fm.removeItem(at: backup)
        // A failed rename here (e.g. no write access to /Applications) leaves
        // the installed bundle untouched — the plain `throw` is the whole
        // recovery story for the unwritable-destination case.
        try fm.moveItem(at: installed, to: backup)
        do {
            try fm.moveItem(at: staged, to: installed)
        } catch let installError {
            var restored = false
            do {
                try fm.moveItem(at: backup, to: installed)
                restored = fm.fileExists(atPath: installed.path)
            } catch {
                restored = false
            }
            if !restored { throw InstallError.restoreFailed(backup.path) }
            throw installError
        }
    }

    /// Put the previous bundle back after a failed relaunch handoff, so the
    /// installed app matches the version still running. Best-effort: the
    /// caller has a relaunch error to report either way, and the running
    /// binary stays alive even when this fails (the new bundle at the
    /// installed path is validated, so it is still runnable by hand).
    private static func undoReplace(_ installed: URL) {
        let fm = FileManager.default
        let backup = installed.deletingLastPathComponent()
            .appendingPathComponent(AppUpdater.backupBundleName, isDirectory: true)
        guard fm.fileExists(atPath: backup.path) else { return }
        try? fm.removeItem(at: installed)
        try? fm.moveItem(at: backup, to: installed)
    }

    /// Spawn the detached handoff: a `/bin/sh` that waits until this pid is
    /// gone (bounding the wait, then opening regardless), then `open`s the
    /// replaced bundle. A spawned child is not killed by its parent's exit,
    /// and the app has no controlling terminal, so no SIGHUP reaches it.
    private static func relaunchAfterExit(opening bundle: URL) async throws {
        let pid = getpid()
        let script = """
        for i in $(seq 1 100); do
          kill -0 \(pid) 2>/dev/null || break
          sleep 0.2
        done
        exec /usr/bin/open "\(bundle.path)"
        """
        SubprocessIO.ignoreSIGPIPE()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw InstallError.relaunchFailed(error.localizedDescription)
        }
        // Let the helper exec before this process goes away.
        try? await Task.sleep(nanoseconds: 300_000_000)
        NSApp.terminate(nil)
    }

    /// Run a short-lived child to completion and return its exit status.
    /// The house subprocess rules (#202) apply in full: SIGPIPE ignored at
    /// the spawn site (process-wide, idempotent), both pipes drained on
    /// dedicated `PipeDrain` threads, and the wait suspends via `Task.sleep`
    /// polling — never `Process.waitUntilExit()`, which spins a CFRunLoop
    /// and hangs off the main thread.
    private static func runTool(
        _ executable: String, _ arguments: [String], timeout: TimeInterval = 180
    ) async throws -> Int32 {
        SubprocessIO.ignoreSIGPIPE()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        let outDrain = PipeDrain(outPipe.fileHandleForReading)
        let errDrain = PipeDrain(errPipe.fileHandleForReading)
        do {
            try process.run()
        } catch {
            await outDrain.finishAndClose(timeout: 1)
            await errDrain.finishAndClose(timeout: 1)
            throw error
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                try? await Task.sleep(nanoseconds: 500_000_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        await outDrain.finishAndClose(timeout: 5)
        await errDrain.finishAndClose(timeout: 5)
        return process.terminationStatus
    }

    /// Post-update cleanup at GUI launch: drop any staging directory a
    /// failed or crashed attempt left in the data directory, and the
    /// previous-version backup beside the installed bundle — its retention
    /// period was "until the new version runs", which is now.
    static func cleanUpAfterUpdate() {
        let fm = FileManager.default
        try? fm.removeItem(atPath: AppPaths.path(stagingDirectoryName))
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let backup = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent(backupBundleName, isDirectory: true)
        try? fm.removeItem(at: backup)
    }
}
#endif
