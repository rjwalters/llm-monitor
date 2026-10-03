import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Single-instance guard for the long-running modes (#238): the menubar app
/// and the headless poll loop.
///
/// Two pollers on one data directory ping every account twice and interleave
/// `usage_history` / synthetic reset rows, so the lock lives **in the data
/// directory** (`AppPaths.path("instance.lock")`), not per-binary: an installed
/// app and a debug build share `~/.llm-monitor` and therefore exclude each
/// other. It is an advisory `flock(2)` on an open file descriptor, which the
/// kernel releases when the holder dies for any reason, so a crashed instance
/// can never wedge it and nothing ever scrubs a stale lock. The PID written
/// into the file is diagnostic only; it is never consulted to decide anything.
///
/// One-shot paths (`--version`, `--help`, `selftest`, the `accounts`/`codex`/
/// `claude`/`zai`/`tokens`/`calibrate` CLIs) must never call this.
///
/// Portable core: no AppKit / SwiftUI / Combine / os.Logger.
final class InstanceLock: @unchecked Sendable {
    enum Outcome {
        case acquired(InstanceLock)
        /// Another live process holds the lock; `pid` is its self-reported id
        /// when the file could be read.
        case alreadyRunning(pid: Int32?)
        /// The lock could not be taken for a reason other than contention
        /// (unwritable directory, exotic filesystem). Callers fail **open**: a
        /// guard that cannot work must not stop the app from running.
        case unavailable(errno: Int32)
    }

    let path: String
    private var fd: Int32

    private init(path: String, fd: Int32) {
        self.path = path
        self.fd = fd
    }

    deinit { release() }

    /// Non-blocking attempt to become the single instance for `path`.
    static func acquire(at path: String) -> Outcome {
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        // O_CLOEXEC: a child we spawn (ssh, codex) must not inherit the
        // descriptor, or it would keep the lock alive after we exit.
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return .unavailable(errno: errno) }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let err = errno
            // Read the holder's pid before closing; best effort, diagnostic.
            let pid = readPID(fd: fd)
            close(fd)
            return err == EWOULDBLOCK ? .alreadyRunning(pid: pid) : .unavailable(errno: err)
        }

        // We own it: replace the previous holder's pid with ours.
        if ftruncate(fd, 0) == 0 {
            let line = "\(getpid())\n"
            _ = line.withCString { pwrite(fd, $0, strlen($0), 0) }
        }
        return .acquired(InstanceLock(path: path, fd: fd))
    }

    /// Releases the lock (also happens at process exit, or on `deinit`).
    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    private static func readPID(fd: Int32) -> Int32? {
        var buffer = [UInt8](repeating: 0, count: 32)
        let n = pread(fd, &buffer, buffer.count, 0)
        guard n > 0 else { return nil }
        let text = String(decoding: buffer[0..<n], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Int32(text)
    }

    // MARK: - Process-wide guard

    /// The lock this process holds, kept for its lifetime. Only touched from
    /// `enforceSingleInstance`, called once on the entry point's main thread
    /// before anything else starts.
    private nonisolated(unsafe) static var held: InstanceLock?

    static var lockPath: String { AppPaths.path("instance.lock") }

    static func alreadyRunningMessage(pid: Int32?, mode: String) -> String {
        let who = pid.map { " (pid \($0))" } ?? ""
        return "llm-monitor: already running\(who) against \(AppPaths.dataDirectory); "
            + "not starting a second \(mode)\n"
    }

    /// Takes the process-wide lock or exits 0 with a stderr message. Exit 0, not
    /// an error: a supervisor (systemd, launchd) or a double-clicked app that
    /// finds the job already done has nothing to retry or report.
    static func enforceSingleInstance(mode: String) {
        switch acquire(at: lockPath) {
        case .acquired(let lock):
            held = lock
        case .alreadyRunning(let pid):
            FileHandle.standardError.write(Data(alreadyRunningMessage(pid: pid, mode: mode).utf8))
            exit(0)
        case .unavailable(let code):
            FileHandle.standardError.write(Data(
                "llm-monitor: warning: could not take instance lock (errno \(code)); continuing without it\n".utf8))
        }
    }
}
