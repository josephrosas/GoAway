import Darwin
import Foundation
import GoAwayCore

/// Answers "can the erased data be read back?" at the logical-block level.
///
/// Each case writes a file full of a unique random marker onto a throwaway disk
/// image, detaches and reattaches so the data is really on the image, erases it,
/// detaches again, and searches the raw image bytes for the marker. A control
/// file deleted the ordinary way proves the search can see leftovers at all.
/// SSD wear-leveling below the block layer is out of reach of any such test.
enum Forensic {
    enum Filesystem: String, CaseIterable {
        case apfs = "APFS"
        case hfs = "HFS+"
        case exfat = "ExFAT"

        var code: String {
            switch self {
            case .apfs: return "A"
            case .hfs: return "H"
            case .exfat: return "X"
            }
        }
    }

    enum Expectation: String {
        /// Control: the marker must still be on the image.
        case present
        case gone
        /// Recorded, not judged.
        case report
    }

    struct Finding: CustomStringConvertible {
        var filesystem: Filesystem
        var label: String
        var expectation: Expectation
        var dataHits: Int
        var nameHits: Int
        /// False when the control for this image found nothing, so absence proves nothing.
        var conclusive: Bool
        var note: String = ""

        var description: String { "\(filesystem.rawValue) \(label)" }

        var passed: Bool {
            guard conclusive else { return true }
            switch expectation {
            case .present: return dataHits > 0
            case .gone: return dataHits == 0
            case .report: return true
            }
        }
    }

    struct SetupError: Error, CustomStringConvertible {
        var description: String
    }

    static let fileSize = 2 * 1024 * 1024
    static let imageSize = "64m"
    static let scrubHeadroom: Int64 = 4 * 1024 * 1024

    /// Runs every case on every filesystem and returns one finding per case.
    static func run(filesystems: [Filesystem] = Filesystem.allCases) throws -> [Finding] {
        var findings: [Finding] = []
        for filesystem in filesystems {
            findings += try plainWipe(on: filesystem)
            findings += try scrubbedWipe(on: filesystem)
        }
        return findings
    }

    static func printReport(_ findings: [Finding]) {
        print("forensic: marker search on raw disk images (data hits = marker copies still readable)")
        for finding in findings {
            let verdict: String
            if !finding.conclusive {
                verdict = "INCONCLUSIVE (control not found)"
            } else if finding.expectation == .report {
                verdict = finding.dataHits == 0 ? "gone (report only)" : "STILL READABLE (report only)"
            } else {
                verdict = finding.passed ? "ok" : "FAIL"
            }
            let label = finding.label.padding(toLength: 30, withPad: " ", startingAt: 0)
            let fs = finding.filesystem.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)
            let note = finding.note.isEmpty ? "" : "  [\(finding.note)]"
            print("  \(fs) \(label) data=\(finding.dataHits) name=\(finding.nameHits) expect=\(finding.expectation.rawValue) -> \(verdict)\(note)")
        }
    }

    // MARK: - Cases

    /// Control outside Trash, a plain file in Trash, and a read-only file in a
    /// folder in Trash. Erased with one pass and no scrub.
    private static func plainWipe(on filesystem: Filesystem) throws -> [Finding] {
        let image = try DiskImage(filesystem: filesystem)
        defer { image.destroy() }

        let control = Planted(label: "control (normal delete)")
        let plain = Planted(label: "wipe")
        let readOnly = Planted(label: "wipe read-only file")
        let cloned = Planted(label: "wipe APFS clone pair")

        try image.attach()
        let trash = try image.makeTrash()
        try control.write(in: image.mountPoint)
        try plain.write(in: trash)
        let lockedFolder = trash.appendingPathComponent("folder-\(readOnly.token)", isDirectory: true)
        try FileManager.default.createDirectory(at: lockedFolder, withIntermediateDirectories: false)
        let lockedFile = try readOnly.write(in: lockedFolder)
        chmod(lockedFile.path, 0o444)
        if filesystem == .apfs {
            // Both halves of a clone in Trash: the first overwrite copies-on-write,
            // the second must then land on the blocks they used to share.
            let source = try cloned.write(in: trash)
            let copy = trash.appendingPathComponent("copy-\(cloned.fileName)")
            guard clonefile(source.path, copy.path, 0) == 0 else {
                throw SetupError(description: "clonefile failed: errno \(errno)")
            }
        }
        try image.detach()

        try image.attach()
        let result = erase(trash: image.trashURL, scrub: false)
        // Deleted after the wipe so no copy-on-write during the wipe can reuse its blocks.
        try FileManager.default.removeItem(at: image.mountPoint.appendingPathComponent(control.fileName))
        try image.detach()

        let bytes = try image.contents()
        let controlHits = bytes.occurrences(of: control.marker)
        let conclusive = controlHits > 0
        let failureNote = result.failures.isEmpty ? "" : "\(result.failures.count) failure(s): \(result.failures.map(\.kind.reason).joined(separator: ", "))"

        var findings = [
            Finding(filesystem: filesystem, label: control.label, expectation: .present,
                    dataHits: controlHits, nameHits: bytes.nameHits(control.token), conclusive: true),
            Finding(filesystem: filesystem, label: plain.label, expectation: .gone,
                    dataHits: bytes.occurrences(of: plain.marker), nameHits: bytes.nameHits(plain.token),
                    conclusive: conclusive),
            Finding(filesystem: filesystem, label: readOnly.label, expectation: .gone,
                    dataHits: bytes.occurrences(of: readOnly.marker), nameHits: bytes.nameHits(readOnly.token),
                    conclusive: conclusive, note: failureNote)
        ]
        if filesystem == .apfs {
            findings.append(Finding(filesystem: filesystem, label: cloned.label, expectation: .gone,
                                    dataHits: bytes.occurrences(of: cloned.marker), nameHits: bytes.nameHits(cloned.token),
                                    conclusive: conclusive))
        }
        return findings
    }

    /// A file deleted the ordinary way before the run, then a wipe with the
    /// free-space scrub on. Both markers should be overwritten.
    private static func scrubbedWipe(on filesystem: Filesystem) throws -> [Finding] {
        let image = try DiskImage(filesystem: filesystem)
        defer { image.destroy() }

        let earlier = Planted(label: "scrub: earlier normal delete")
        let wiped = Planted(label: "scrub: wipe")
        let control = Planted(label: "scrub: control (kept)")

        try image.attach()
        let trash = try image.makeTrash()
        try earlier.write(in: image.mountPoint)
        try control.write(in: image.mountPoint)
        try wiped.write(in: trash)
        try image.detach()

        try image.attach()
        try FileManager.default.removeItem(at: image.mountPoint.appendingPathComponent(earlier.fileName))
        let result = erase(trash: image.trashURL, scrub: true)
        try image.detach()

        let bytes = try image.contents()
        let conclusive = bytes.occurrences(of: control.marker) > 0
        let scrubbed = result.assurances.first?.freeSpaceScrubbed == true
        let note = scrubbed ? "" : "scrub did not run"
        // The scrub leaves its headroom free, so blocks there can survive.
        return [
            Finding(filesystem: filesystem, label: earlier.label, expectation: .report,
                    dataHits: bytes.occurrences(of: earlier.marker), nameHits: bytes.nameHits(earlier.token),
                    conclusive: conclusive, note: note),
            Finding(filesystem: filesystem, label: wiped.label, expectation: .gone,
                    dataHits: bytes.occurrences(of: wiped.marker), nameHits: bytes.nameHits(wiped.token),
                    conclusive: conclusive, note: note)
        ]
    }

    private static func erase(trash: URL, scrub: Bool) -> WipeResult {
        let request = WipeRequest(
            roots: [trash],
            level: .simple,
            respectSSD: true,
            scrubFreeSpace: scrub,
            scrubHeadroom: scrubHeadroom,
            probe: SystemVolumeProbe(),
            inspector: FixedAssuranceInspector(snapshots: [], timeMachine: false, fileVault: true)
        )
        return WipeRunner.run(request, cancel: CancelFlag()) { _ in }
    }

    // MARK: - Planted files

    private struct Planted {
        let label: String
        let marker: [UInt8]
        let token: String

        init(label: String) {
            self.label = label
            var bytes = [UInt8](repeating: 0, count: 32)
            arc4random_buf(&bytes, bytes.count)
            marker = bytes
            token = SecureEraser.randomName()
        }

        var fileName: String { "goaway-\(token).bin" }

        @discardableResult
        func write(in directory: URL) throws -> URL {
            let url = directory.appendingPathComponent(fileName)
            var payload = [UInt8]()
            payload.reserveCapacity(Forensic.fileSize)
            while payload.count < Forensic.fileSize { payload += marker }
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            guard fd >= 0 else { throw SetupError(description: "create \(url.path): errno \(errno)") }
            defer { close(fd) }
            let written = payload.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            guard written == payload.count else { throw SetupError(description: "write \(url.path)") }
            _ = fcntl(fd, F_FULLFSYNC)
            return url
        }
    }

    // MARK: - Disk image

    private final class DiskImage {
        let filesystem: Filesystem
        let path: URL
        let volumeName: String
        var mountPoint: URL { URL(fileURLWithPath: "/Volumes/\(volumeName)", isDirectory: true) }
        var trashURL: URL {
            mountPoint.appendingPathComponent(".Trashes/\(getuid())", isDirectory: true)
        }
        private var attached = false

        init(filesystem: Filesystem) throws {
            self.filesystem = filesystem
            volumeName = "GAF\(filesystem.code)\(Int.random(in: 10000...99999))"
            path = FileManager.default.temporaryDirectory
                .appendingPathComponent("GoAway-forensic-\(volumeName).dmg")
            let status = GoAwayCheck.shell("/usr/bin/hdiutil", [
                "create", "-quiet", "-size", Forensic.imageSize, "-type", "UDIF",
                "-fs", filesystem.rawValue, "-volname", volumeName, path.path
            ])
            guard status == 0 else {
                throw SetupError(description: "hdiutil create \(filesystem.rawValue) failed (\(status))")
            }
        }

        func attach() throws {
            let status = GoAwayCheck.shell("/usr/bin/hdiutil", [
                "attach", "-quiet", "-nobrowse", "-noverify", "-noautoopen", path.path
            ])
            guard status == 0 else { throw SetupError(description: "hdiutil attach failed (\(status))") }
            attached = true
            // Keep Spotlight from reading the planted files.
            FileManager.default.createFile(
                atPath: mountPoint.appendingPathComponent(".metadata_never_index").path,
                contents: nil
            )
        }

        func detach() throws {
            guard attached else { return }
            var status: Int32 = -1
            for _ in 0..<5 {
                status = GoAwayCheck.shell("/usr/bin/hdiutil", ["detach", "-quiet", mountPoint.path])
                if status == 0 { break }
                Thread.sleep(forTimeInterval: 0.5)
            }
            if status != 0 {
                status = GoAwayCheck.shell("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mountPoint.path])
            }
            guard status == 0 else { throw SetupError(description: "hdiutil detach failed (\(status))") }
            attached = false
        }

        func makeTrash() throws -> URL {
            try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
            return trashURL
        }

        func contents() throws -> Data {
            try Data(contentsOf: path, options: .alwaysMapped)
        }

        func destroy() {
            try? detach()
            try? FileManager.default.removeItem(at: path)
        }
    }
}

extension Data {
    /// Non-overlapping occurrences of `needle`.
    func occurrences(of needle: [UInt8]) -> Int {
        guard !needle.isEmpty, self.count >= needle.count else { return 0 }
        return withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let base = raw.baseAddress else { return 0 }
            let total = raw.count
            var hits = 0
            var offset = 0
            while offset <= total - needle.count {
                guard let found = memmem(base + offset, total - offset, needle, needle.count) else { break }
                hits += 1
                offset = base.distance(to: UnsafeRawPointer(found)) + needle.count
            }
            return hits
        }
    }

    /// Occurrences of a file-name token as UTF-8 (APFS), UTF-16BE (HFS+) or UTF-16LE (exFAT).
    func nameHits(_ token: String) -> Int {
        let utf8 = Array(token.utf8)
        var be: [UInt8] = []
        var le: [UInt8] = []
        for unit in token.utf16 {
            let high = UInt8(truncatingIfNeeded: unit >> 8)
            let low = UInt8(truncatingIfNeeded: unit)
            be += [high, low]
            le += [low, high]
        }
        return occurrences(of: utf8) + occurrences(of: be) + occurrences(of: le)
    }
}
