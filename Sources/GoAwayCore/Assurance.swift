import Foundation

/// Something that can still hold the erased data after GoAway is done.
public enum AssuranceWarning: Sendable, Equatable, Hashable {
    /// APFS local snapshots on this volume still reference the old blocks.
    case localSnapshots(count: Int, mountPoint: String)
    /// Freed blocks are plaintext until FileVault is on.
    case fileVaultOff
    /// Informational: Time Machine backups may hold copies. Not actionable here.
    case timeMachineConfigured

    /// Warnings that keep the window open; informational ones do not.
    public var blocksAutoQuit: Bool {
        switch self {
        case .localSnapshots, .fileVaultOff: return true
        case .timeMachineConfigured: return false
        }
    }
}

/// Honest per-volume account of what the wipe achieved.
public struct VolumeAssurance: Sendable, Equatable, Identifiable {
    public var volume: VolumeClass
    public var inPlaceOverwrite: Bool
    public var freeSpaceScrubbed: Bool
    public var scrubbedBytes: Int64
    public var localSnapshots: [String]
    public var timeMachineConfigured: Bool
    /// nil when unknown (fdesetup unavailable).
    public var fileVaultOn: Bool?

    public var id: String { volume.mountPoint }

    public init(
        volume: VolumeClass,
        inPlaceOverwrite: Bool,
        freeSpaceScrubbed: Bool,
        scrubbedBytes: Int64 = 0,
        localSnapshots: [String] = [],
        timeMachineConfigured: Bool = false,
        fileVaultOn: Bool? = nil
    ) {
        self.volume = volume
        self.inPlaceOverwrite = inPlaceOverwrite
        self.freeSpaceScrubbed = freeSpaceScrubbed
        self.scrubbedBytes = scrubbedBytes
        self.localSnapshots = localSnapshots
        self.timeMachineConfigured = timeMachineConfigured
        self.fileVaultOn = fileVaultOn
    }

    public var warnings: [AssuranceWarning] {
        var list: [AssuranceWarning] = []
        if !localSnapshots.isEmpty {
            list.append(.localSnapshots(count: localSnapshots.count, mountPoint: volume.mountPoint))
        }
        if isHomeVolume, fileVaultOn == false {
            list.append(.fileVaultOff)
        }
        if timeMachineConfigured {
            list.append(.timeMachineConfigured)
        }
        return list
    }

    private var isHomeVolume: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let prefix = volume.mountPoint.hasSuffix("/") ? volume.mountPoint : volume.mountPoint + "/"
        return volume.mountPoint == "/" || home.hasPrefix(prefix) || volume.mountPoint == "/System/Volumes/Data"
    }

    /// One-line summary of how the data was handled on this volume.
    public var summary: String {
        var parts: [String] = []
        if volume.isNetwork {
            parts.append("unlinked only (network volume)")
        } else if inPlaceOverwrite {
            parts.append("overwritten in place")
        } else {
            parts.append("unlinked (APFS is copy-on-write)")
        }
        if freeSpaceScrubbed {
            parts.append("free space scrubbed")
        }
        if let fileVaultOn, isHomeVolume {
            parts.append(fileVaultOn ? "FileVault on" : "FileVault off")
        } else if volume.isEncrypted {
            parts.append("encrypted")
        }
        return parts.joined(separator: ", ")
    }

    public var isClean: Bool {
        !warnings.contains { $0.blocksAutoQuit }
    }
}

public protocol AssuranceInspecting: Sendable {
    /// Local APFS snapshot dates (e.g. "2026-10-07-221500") for the volume at `mountPoint`.
    func localSnapshots(mountPoint: String) -> [String]
    func isTimeMachineConfigured() -> Bool
    /// nil when the answer cannot be determined.
    func isFileVaultOn() -> Bool?
}

public struct FixedAssuranceInspector: AssuranceInspecting {
    public var snapshots: [String]
    public var timeMachine: Bool
    public var fileVault: Bool?

    public init(snapshots: [String] = [], timeMachine: Bool = false, fileVault: Bool? = true) {
        self.snapshots = snapshots
        self.timeMachine = timeMachine
        self.fileVault = fileVault
    }

    public func localSnapshots(mountPoint: String) -> [String] { snapshots }
    public func isTimeMachineConfigured() -> Bool { timeMachine }
    public func isFileVaultOn() -> Bool? { fileVault }
}

/// Shells out to `tmutil` and `fdesetup`. Both are read-only queries that need
/// Full Disk Access, which GoAway already requires.
public struct SystemAssuranceInspector: AssuranceInspecting {
    public init() {}

    public func localSnapshots(mountPoint: String) -> [String] {
        guard let output = CommandRunner.run("/usr/bin/tmutil", ["listlocalsnapshots", mountPoint], timeout: 8) else {
            return []
        }
        return SnapshotParser.dates(in: output.stdout)
    }

    public func isTimeMachineConfigured() -> Bool {
        guard let output = CommandRunner.run("/usr/bin/tmutil", ["destinationinfo"], timeout: 8) else {
            return false
        }
        return output.status == 0 && output.stdout.contains("Name")
    }

    public func isFileVaultOn() -> Bool? {
        guard let output = CommandRunner.run("/usr/bin/fdesetup", ["status"], timeout: 8) else {
            return nil
        }
        let text = output.stdout.lowercased()
        if text.contains("filevault is on") { return true }
        if text.contains("filevault is off") { return false }
        return nil
    }
}

public enum SnapshotParser {
    /// Pulls snapshot dates out of `tmutil listlocalsnapshots` output, e.g.
    /// `com.apple.TimeMachine.2026-10-07-221500.local` -> `2026-10-07-221500`.
    public static func dates(in output: String) -> [String] {
        var dates: [String] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("com.apple.TimeMachine."), line.hasSuffix(".local") else { continue }
            let start = line.index(line.startIndex, offsetBy: "com.apple.TimeMachine.".count)
            let end = line.index(line.endIndex, offsetBy: -".local".count)
            guard start < end else { continue }
            let date = String(line[start..<end])
            if isValidDate(date) { dates.append(date) }
        }
        return dates
    }

    /// `YYYY-MM-DD-HHMMSS`, digits and dashes only. Anything else never reaches a shell.
    public static func isValidDate(_ date: String) -> Bool {
        guard date.count == 17 else { return false }
        for (index, scalar) in date.unicodeScalars.enumerated() {
            let dash = index == 4 || index == 7 || index == 10
            if dash {
                if scalar != "-" { return false }
            } else if !(scalar.value >= 48 && scalar.value <= 57) {
                return false
            }
        }
        return true
    }
}

public enum SnapshotDeleter {
    public enum DeleteError: Error, LocalizedError {
        case invalidDate(String)
        case declined
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidDate(let date): return "Unexpected snapshot name \(date)"
            case .declined: return "Administrator approval was declined"
            case .failed(let message): return message
            }
        }
    }

    /// Deletes local snapshots through an administrator prompt. `tmutil
    /// deletelocalsnapshots` requires root, so this goes through osascript's
    /// `with administrator privileges`, which shows the standard macOS dialog.
    public static func deleteLocalSnapshots(dates: [String]) throws {
        for date in dates where !SnapshotParser.isValidDate(date) {
            throw DeleteError.invalidDate(date)
        }
        guard !dates.isEmpty else { return }

        let commands = dates
            .map { "/usr/bin/tmutil deletelocalsnapshots \($0)" }
            .joined(separator: "; ")
        let script = "do shell script \"\(commands)\" with administrator privileges"

        guard let output = CommandRunner.run("/usr/bin/osascript", ["-e", script], timeout: 120) else {
            throw DeleteError.failed("osascript did not finish")
        }
        if output.status != 0 {
            if output.stderr.contains("-128") {
                throw DeleteError.declined
            }
            throw DeleteError.failed(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

enum CommandRunner {
    struct Output {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    static func run(_ launchPath: String, _ arguments: [String], timeout: TimeInterval) -> Output? {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Drain pipes on background threads so a chatty command cannot deadlock us.
        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            stdoutBox.data = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            stderrBox.data = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        group.wait()

        return Output(
            status: process.terminationStatus,
            stdout: String(decoding: stdoutBox.data, as: UTF8.self),
            stderr: String(decoding: stderrBox.data, as: UTF8.self)
        )
    }

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = Data()
        var data: Data {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }
}
