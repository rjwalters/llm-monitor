#if os(macOS)
import AppKit
import Darwin
import Foundation

/// One-click self-install of a newer release (#323): download the
/// `LLMMonitor.zip` asset over HTTPS, verify the bytes against the release's
/// SHA-256 digest, stage the bundle, pass the signature gate — `codesign
/// --verify --deep --strict`, `spctl --assess --type execute`, and a
/// Developer ID team identifier equal to the running bundle's own (operator
/// ruling 2026-11-19: the checksum proves integrity, not origin) — validate
/// id and version, replace the installed bundle at its current path, and
/// relaunch once this instance has exited. The relaunch handoff waits for
/// this process to disappear before opening the new bundle, which is
/// strictly after `InstanceLock`'s flock releases at process exit — so the
/// new version starts cleanly, never as a rejected "already running".
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
        case signatureRefusal(SignatureGate.Refusal)
        case extractionFailed(Int32)
        case quarantineClearFailed(Int32)
        case bundleMissing
        case bundleIdentityUnexpected(identifier: String, version: String, expectedIdentifier: String, expectedVersion: String)
        case notAnInstalledBundle
        case toolTimedOut(String)
        case replaceFailed(String)
        case restoreFailed(String)
        case relaunchFailed(String)

        /// True for the one failure class that is deliberately *not* an
        /// install failure: the signature gate refused the staged bundle, so
        /// the app degrades to update-check-only (offer stays, updating
        /// happens from the release page) instead of showing a Retry that
        /// could only download and refuse again.
        var isSignatureRefusal: Bool {
            if case .signatureRefusal = self { return true }
            return false
        }

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
            case .signatureRefusal(let refusal):
                return refusal.shortReason
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
            case .toolTimedOut(let tool):
                return "a helper tool (\(tool)) timed out"
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

    /// The previous-version backup kept beside the installed bundle while a
    /// replacement settles is uniquely named per install and recorded in
    /// `UpdateHandoff.Pending`; only the new version, running at the
    /// installed path, removes it (`cleanUpAfterUpdate`) — the earliest proof
    /// it runs. No other copy's launch can delete it.
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

            // 5. Signature gate (operator ruling 2026-11-19): the checksum
            //    above proves integrity, not origin — it comes from the same
            //    release as the archive — so the staged bundle must verify
            //    with codesign, be accepted by Gatekeeper, and carry the
            //    same Developer ID team as the *running* bundle before
            //    anything is installed or de-quarantined. A refusal throws
            //    `signatureRefusal`, which the catch below maps to
            //    update-check-only (offer stays, release page opens) — never
            //    an install, never a quarantine strip.
            checker.updateInstallProgress("Verifying signature…")
            let gateInput = await Self.measureSignatureGate(staged: stagedBundle, running: installedURL)
            switch SignatureGate.decide(gateInput) {
            case .install:
                break
            case .refuse(let refusal):
                throw InstallError.signatureRefusal(refusal)
            }

            // 6. Quarantine clear — only now, on a bundle the signature gate
            //    just verified: quarantine is never stripped from an
            //    unverified bundle (ruling item 2).
            checker.updateInstallProgress("Preparing…")
            try Self.validateStagedBundle(stagedBundle, expectedVersion: info.version)
            try await Self.clearQuarantine(at: stagedBundle)

            // 7. Replace at the installed path, keeping a same-volume backup
            //    to restore from if the swap fails.
            checker.updateInstallProgress("Installing…")
            let pending = try Self.replaceInstalledBundle(
                installedURL, with: stagedBundle, expectedVersion: info.version)

            // 8. Relaunch: a detached helper waits for this process to exit —
            //    which is what releases the instance lock — then opens the
            //    new bundle. Success never returns from here.
            checker.updateInstallProgress("Relaunching…")
            do {
                try await Self.relaunchAfterExit(opening: installedURL, pending: pending)
            } catch {
                // No helper is coming: put the previous bundle back so the
                // installed app matches the version still running, then
                // surface the relaunch failure.
                Self.undoReplace(installedURL, pending: pending)
                throw error
            }

            // `terminate(_:)` exits the process; reaching this line means it
            // was refused (no delegate cancels termination today).
            throw InstallError.relaunchFailed("the app did not terminate")
        } catch {
            // A signature-gate refusal is not an install failure: nothing is
            // wrong with the machine, the release simply may not be
            // one-click installed (unsigned, wrongly signed, or Gatekeeper
            // rejected). Degrade to update-check-only — the offer stays and
            // the user updates from the release page (ruling item 2).
            if let installError = error as? InstallError, installError.isSignatureRefusal {
                let reason = installError.shortReason
                flog.warning("self-update refused by the signature gate: \(reason) — degrading to update-check-only", category: "Update")
                checker.degradeToManualUpdate(reason)
                try? FileManager.default.removeItem(atPath: stagingPath)
                inFlight = false
                return
            }
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

    /// Strip the quarantine attribute URLSession stamps on downloads. Runs
    /// **only after** the signature gate verified the bundle (ruling item 2:
    /// never strip quarantine from an unverified bundle), so the
    /// right-click→Open Gatekeeper dance this removes is one a verified,
    /// Gatekeeper-accepted bundle would have passed anyway. `xattr -c`
    /// succeeds (exit 0) when there is nothing to clear.
    private static func clearQuarantine(at bundle: URL) async throws {
        let status = try await runTool("/usr/bin/xattr", ["-r", "-c", bundle.path])
        guard status == 0 else { throw InstallError.quarantineClearFailed(status) }
    }

    // MARK: Signature gate (operator ruling 2026-11-19)

    /// Measure everything `SignatureGate.decide` needs about the staged
    /// bundle and the *running* one. A verification tool that fails to run or
    /// never exits folds into its measured answer (`false` / nil team) with a
    /// log line rather than a thrown error: the gate's contract is that any
    /// failure to verify is a refusal, never an install.
    private static func measureSignatureGate(staged: URL, running: URL) async -> SignatureGate.Input {
        var input = SignatureGate.Input()
        do {
            input.codesignVerified = try await runTool(
                "/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path],
                timeout: 120) == 0
        } catch {
            FileLogger.shared.warning("codesign --verify could not run for the staged bundle: \(error.localizedDescription)", category: "Update")
        }
        guard input.codesignVerified else { return input }
        do {
            input.gatekeeperAccepted = try await runTool(
                "/usr/sbin/spctl", ["--assess", "--type", "execute", staged.path],
                timeout: 120) == 0
        } catch {
            FileLogger.shared.warning("spctl --assess could not run for the staged bundle: \(error.localizedDescription)", category: "Update")
        }
        guard input.gatekeeperAccepted else { return input }
        input.stagedTeamIdentifier = await developerIDTeam(of: staged)
        input.runningTeamIdentifier = await developerIDTeam(of: running)
        return input
    }

    /// A team identifier alone does not establish the certificate class.
    /// Have codesign check Apple's Developer ID chain and the leaf OU on
    /// the bundle itself. Do this for both sides of the update.
    private static func developerIDTeam(of bundle: URL) async -> String? {
        guard let result = try? await runToolDetailed(
            "/usr/bin/codesign", ["-dv", "--verbose=4", bundle.path],
            timeout: 120), result.status == 0,
              let team = SignatureGate.parseTeamIdentifier(from: result.stderrText),
              let requirement = SignatureGate.developerIDRequirement(for: team) else { return nil }
        let verified = try? await runTool(
            "/usr/bin/codesign", ["--verify", "-R=\(requirement)", bundle.path], timeout: 120)
        return verified == 0 ? team : nil
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
    /// to a uniquely named backup (same volume, atomic), move the staged one
    /// in, and restore the backup if that move fails — the running binary
    /// keeps working throughout; it stays mapped even once its directory
    /// entry is renamed away. The transaction is recorded in the pending file
    /// *before* anything moves, so a crash mid-swap still leaves the record
    /// that names the backup. An earlier replacement whose backup is still on
    /// disk is **unresolved recovery data**: this retry refuses rather than
    /// delete it or drop its record. Returns the new record.
    private static func replaceInstalledBundle(
        _ installed: URL, with staged: URL, expectedVersion: String
    ) throws -> UpdateHandoff.Pending {
        let fm = FileManager.default
        let pendingPath = AppPaths.path(UpdateHandoff.pendingFileName)
        if let old = UpdateHandoff.readPending(at: pendingPath),
           let oldBackup = old.backupPath, fm.fileExists(atPath: oldBackup) {
            throw InstallError.replaceFailed(
                "an earlier update left its recovery backup beside the installed app; remove it once the app is confirmed working")
        }
        let token = String(UUID().uuidString.prefix(8))
        let pending = UpdateHandoff.Pending(
            installedPath: installed.path, token: token, expectedVersion: expectedVersion)
        guard let backupPath = pending.backupPath else {
            throw InstallError.replaceFailed("could not name a recovery backup for \(installed.lastPathComponent)")
        }
        let backup = URL(fileURLWithPath: backupPath, isDirectory: true)
        try UpdateHandoff.writePending(pending, to: pendingPath)
        // A failed rename here (e.g. no write access to /Applications) leaves
        // the installed bundle untouched — the plain `throw` is the whole
        // recovery story for the unwritable-destination case.
        do {
            try fm.moveItem(at: installed, to: backup)
        } catch {
            UpdateHandoff.clearPending(at: pendingPath)
            throw error
        }
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
            // Unrestored: the backup and its record both stay.
            if !restored { throw InstallError.restoreFailed(backup.path) }
            UpdateHandoff.clearPending(at: pendingPath)
            throw installError
        }
        return pending
    }

    /// Put the previous bundle back after a failed relaunch handoff, so the
    /// installed app matches the version still running. Best-effort: the
    /// caller has a relaunch error to report either way, and the running
    /// binary stays alive even when this fails (the new bundle at the
    /// installed path is validated, so it is still runnable by hand).
    private static func undoReplace(_ installed: URL, pending: UpdateHandoff.Pending) {
        let fm = FileManager.default
        guard let backupPath = pending.backupPath, fm.fileExists(atPath: backupPath) else { return }
        try? fm.removeItem(at: installed)
        if (try? fm.moveItem(atPath: backupPath, toPath: installed.path)) != nil {
            UpdateHandoff.clearPending(at: AppPaths.path(UpdateHandoff.pendingFileName))
        }
    }

    /// Spawn the detached handoff (`UpdateHandoff.relaunchScript`): a
    /// `/bin/sh` that waits until this pid is gone — never launching while
    /// it is alive — then `open`s the replaced bundle, and on any failure
    /// restores the backup and records why. A spawned child is not killed by
    /// its parent's exit, and the app has no controlling terminal, so no
    /// SIGHUP reaches it. Every path travels as a positional argument, never
    /// interpolated into the script body (#327).
    private static func relaunchAfterExit(opening bundle: URL, pending: UpdateHandoff.Pending) async throws {
        guard let backupPath = pending.backupPath else {
            throw InstallError.relaunchFailed("the recovery backup record is invalid")
        }
        SubprocessIO.ignoreSIGPIPE()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", UpdateHandoff.relaunchScript, "llm-monitor-relaunch",
            String(getpid()), bundle.path, backupPath,
            AppPaths.path(UpdateHandoff.failureFileName), "/usr/bin/open",
            "150", "0.2", AppPaths.path(UpdateHandoff.pendingFileName),
            AppPaths.path(UpdateHandoff.confirmFileName), pending.token,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw InstallError.relaunchFailed(error.localizedDescription)
        }
        // Let the helper start polling before this process goes away.
        try? await Task.sleep(nanoseconds: 300_000_000)
        NSApp.terminate(nil)
    }

    /// Run a short-lived child to completion and return its exit status.
    /// The house subprocess rules (#202) apply in full: SIGPIPE ignored at
    /// the spawn site (process-wide, idempotent), both pipes drained on
    /// dedicated `PipeDrain` threads, and the wait suspends via `Task.sleep`
    /// polling — never `Process.waitUntilExit()`, which spins a CFRunLoop
    /// and hangs off the main thread.
    @discardableResult
    private static func runTool(
        _ executable: String, _ arguments: [String], timeout: TimeInterval = 180
    ) async throws -> Int32 {
        try await runToolDetailed(executable, arguments, timeout: timeout).status
    }

    /// `runTool` with the child's captured output — what the signature
    /// gate's team-identifier read needs (`codesign -dv` writes to stderr).
    /// Output is snapshotted after the drains observed EOF, so nothing ever
    /// blocks the main actor on a pipe.
    private static func runToolDetailed(
        _ executable: String, _ arguments: [String], timeout: TimeInterval = 180
    ) async throws -> (status: Int32, stdoutText: String, stderrText: String) {
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
                // Give the child a bounded interval to exit before closing
                // its drains. The timeout path never reads terminationStatus.
                let exitDeadline = Date().addingTimeInterval(5)
                while process.isRunning && Date() < exitDeadline {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                await outDrain.finishAndClose(timeout: 1)
                await errDrain.finishAndClose(timeout: 1)
                // A tool can exit zero while handling SIGTERM. Its check
                // still missed the deadline and cannot authorize an install.
                throw InstallError.toolTimedOut(executable)
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        await outDrain.finishAndClose(timeout: 5)
        await errDrain.finishAndClose(timeout: 5)
        let outText = String(data: outDrain.dataSoFar, encoding: .utf8) ?? ""
        let errText = String(data: errDrain.dataSoFar, encoding: .utf8) ?? ""
        return (process.terminationStatus, outText, errText)
    }

    /// Post-update cleanup at GUI launch: drop any staging directory a
    /// failed or crashed attempt left in the data directory, remove the
    /// previous-version backup **only if this process is the confirmed new
    /// install** (`UpdateHandoff.backupToRemove`: running at the installed
    /// path, at the expected version), and return the failure the relaunch
    /// helper recorded, if any, so the caller can show it.
    @discardableResult
    static func cleanUpAfterUpdate() -> String? {
        let fm = FileManager.default
        try? fm.removeItem(atPath: AppPaths.path(stagingDirectoryName))
        let failure = UpdateHandoff.takeFailure(at: AppPaths.path(UpdateHandoff.failureFileName))
        guard Bundle.main.bundleURL.pathExtension == "app" else { return failure }
        let pendingPath = AppPaths.path(UpdateHandoff.pendingFileName)
        if let pending = UpdateHandoff.readPending(at: pendingPath),
           let backup = UpdateHandoff.backupToRemove(
               pending: pending,
               runningBundlePath: Bundle.main.bundleURL.path,
               runningVersion: AppVersion.current) {
            // Tell the helper this install started, then drop the backup.
            // A failed deletion keeps the record so the next launch retries
            // instead of orphaning the backup.
            try? UpdateHandoff.writeConfirmation(
                token: pending.token, to: AppPaths.path(UpdateHandoff.confirmFileName))
            if !fm.fileExists(atPath: backup) || (try? fm.removeItem(atPath: backup)) != nil {
                UpdateHandoff.clearPending(at: pendingPath)
            }
        }
        return failure
    }
}
#endif
