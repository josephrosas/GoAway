import Darwin
import Foundation
import os

public enum FullDiskAccess {
    public enum Status: Sendable, Equatable {
        case granted
        /// macOS refused a privacy-gated path. `reason` names the path and errno.
        case denied(reason: String)
        /// No probe could decide (e.g. the paths do not exist). `reason` says why.
        case unknown(reason: String)

        public var isGranted: Bool {
            if case .granted = self { return true }
            return false
        }

        public var reason: String? {
            switch self {
            case .granted: return nil
            case .denied(let reason), .unknown(let reason): return reason
            }
        }
    }

    static let log = Logger(subsystem: "com.unga.GoAway", category: "permission")

    public static func isGranted(fileManager: FileManager = .default) -> Bool {
        status(fileManager: fileManager).isGranted
    }

    /// Decides by doing what the app actually needs: list the user's Trash. The
    /// probes use `opendir`/`open` and inspect errno; `access(2)` is avoided
    /// because it answers from POSIX permissions, not the privacy gate.
    public static func status(fileManager: FileManager = .default) -> Status {
        let home = fileManager.homeDirectoryForCurrentUser
        let trash = home.appendingPathComponent(".Trash", isDirectory: true).path

        switch probeDirectory(trash) {
        case .readable:
            log.info("Full Disk Access granted (listed \(trash, privacy: .public))")
            return .granted
        case .denied(let errno):
            let reason = "\(abbreviate(trash, home: home.path)): \(describe(errno))"
            log.error("Full Disk Access denied: \(reason, privacy: .public)")
            return .denied(reason: reason)
        case .other(let errno):
            log.notice("Trash probe inconclusive: \(trash, privacy: .public) \(describe(errno), privacy: .public)")
        }

        // Trash is missing or unreadable for a non-privacy reason. Fall back to
        // other paths behind the same gate.
        let fallbacks: [(path: String, isDirectory: Bool)] = [
            (home.appendingPathComponent("Library/Safari", isDirectory: true).path, true),
            ("/Library/Application Support/com.apple.TCC/TCC.db", false),
            (home.appendingPathComponent("Library/Mail", isDirectory: true).path, true)
        ]
        var notes: [String] = []
        for probe in fallbacks {
            let outcome = probe.isDirectory ? probeDirectory(probe.path) : probeFile(probe.path)
            switch outcome {
            case .readable:
                log.info("Full Disk Access granted (read \(probe.path, privacy: .public))")
                return .granted
            case .denied(let errno):
                let reason = "\(abbreviate(probe.path, home: home.path)): \(describe(errno))"
                log.error("Full Disk Access denied: \(reason, privacy: .public)")
                return .denied(reason: reason)
            case .other(let errno):
                notes.append("\(abbreviate(probe.path, home: home.path)): \(describe(errno))")
            }
        }

        let reason = notes.joined(separator: "; ")
        log.error("Full Disk Access status unknown: \(reason, privacy: .public)")
        return .unknown(reason: reason)
    }

    public static let settingsURLs: [URL] = [
        URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!,
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    ]

    // MARK: - Probes

    public enum ProbeOutcome: Equatable, Sendable {
        case readable
        case denied(Int32)
        case other(Int32)
    }

    /// True for the errno values the privacy gate produces.
    public static func isPrivacyDenial(_ errno: Int32) -> Bool {
        errno == EPERM || errno == EACCES
    }

    /// True for Foundation errors that wrap a privacy denial.
    public static func isPrivacyDenial(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return isPrivacyDenial(Int32(nsError.code))
        }
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileReadNoPermissionError || nsError.code == NSFileWriteNoPermissionError {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPrivacyDenial(underlying as Error)
        }
        return false
    }

    public static func probeDirectory(_ path: String) -> ProbeOutcome {
        guard let dir = opendir(path) else {
            let code = errno
            return isPrivacyDenial(code) ? .denied(code) : .other(code)
        }
        closedir(dir)
        return .readable
    }

    public static func probeFile(_ path: String) -> ProbeOutcome {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            let code = errno
            return isPrivacyDenial(code) ? .denied(code) : .other(code)
        }
        close(fd)
        return .readable
    }

    static func describe(_ errno: Int32) -> String {
        let name: String
        switch errno {
        case EPERM: name = "EPERM"
        case EACCES: name = "EACCES"
        case ENOENT: name = "ENOENT"
        case ENOTDIR: name = "ENOTDIR"
        default: name = "errno \(errno)"
        }
        return "\(name) (\(String(cString: strerror(errno))))"
    }

    static func abbreviate(_ path: String, home: String) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
