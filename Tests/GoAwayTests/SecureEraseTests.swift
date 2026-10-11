import XCTest
@testable import GoAwayCore

final class SecureEraseTests: XCTestCase {
    private let quiet = FixedAssuranceInspector(snapshots: [], timeMachine: false, fileVault: true)

    func testOverwriteReplacesContents() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoAway-over-\(UUID().uuidString).bin")
        let original = Data(repeating: 0x41, count: 4096)
        try original.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        try SecureEraser.overwriteContents(at: url.path, passes: [.constant(0x00)])
        let after = try Data(contentsOf: url)
        XCTAssertEqual(after.count, original.count)
        XCTAssertTrue(after.allSatisfy { $0 == 0 })
        XCTAssertNotEqual(after, original)
    }

    func testRepeatingPatternStaysAlignedAcrossChunks() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoAway-rep-\(UUID().uuidString).bin")
        let size = SecureEraser.chunkSize * 2 + 7
        try Data(count: size).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let pattern: [UInt8] = [0x92, 0x49, 0x24]
        try SecureEraser.overwriteContents(at: url.path, passes: [.repeating(pattern)])
        let after = try Data(contentsOf: url)
        XCTAssertEqual(after.count, size)
        for (index, byte) in after.enumerated() where byte != pattern[index % 3] {
            XCTFail("byte \(index) was \(byte)")
            break
        }
    }

    func testFakeTrashWipeRemovesFilesAndLeavesOutsiders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoAway-fake-\(UUID().uuidString)", isDirectory: true)
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        let nested = trash.appendingPathComponent("nested", isDirectory: true)
        let outside = root.appendingPathComponent("outside.txt")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("gone".utf8).write(to: nested.appendingPathComponent("note.txt"))
        try Data("stay".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: root) }

        let request = WipeRequest(
            roots: [trash],
            level: .simple,
            respectSSD: true,
            probe: FixedVolumeProbe(solidState: true),
            inspector: quiet
        )
        let result = WipeRunner.run(request, cancel: CancelFlag()) { _ in }

        XCTAssertEqual(result.outcome, .completed)
        XCTAssertGreaterThanOrEqual(result.erasedCount, 1)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.appendingPathComponent("note.txt").path))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "stay")
        XCTAssertEqual(result.assurances.count, 1)
        XCTAssertFalse(result.assurances[0].inPlaceOverwrite)
        XCTAssertTrue(result.warnings.isEmpty)

        let leftover = try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)
        XCTAssertTrue(leftover.isEmpty)
    }

    func testParallelWipeLeavesNothingBehind() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoAway-par-\(UUID().uuidString)", isDirectory: true)
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        for folder in 0..<6 {
            let dir = trash.appendingPathComponent("d\(folder)/inner", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for file in 0..<20 {
                try Data(repeating: UInt8(file), count: 1024 + file).write(to: dir.appendingPathComponent("f\(file).bin"))
            }
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let request = WipeRequest(
            roots: [trash],
            level: .simple,
            respectSSD: true,
            probe: FixedVolumeProbe(solidState: true),
            inspector: quiet
        )
        let result = WipeRunner.run(request, cancel: CancelFlag()) { _ in }
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertEqual(result.erasedCount, 6 * 20 + 6 * 2)
        let leftover = try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)
        XCTAssertTrue(leftover.isEmpty)
    }

    func testSymlinkInTrashDoesNotTouchTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoAway-link-\(UUID().uuidString)", isDirectory: true)
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("secret.txt")
        try Data("keep-secret".utf8).write(to: outside)
        let link = trash.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: root) }

        let request = WipeRequest(
            roots: [trash],
            level: .dod,
            respectSSD: false,
            probe: FixedVolumeProbe(solidState: false),
            inspector: quiet
        )
        let result = WipeRunner.run(request, cancel: CancelFlag()) { _ in }

        XCTAssertEqual(result.outcome, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep-secret")
    }

    func testCancelLeavesLaterFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoAway-cancel-\(UUID().uuidString)", isDirectory: true)
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: trash.appendingPathComponent("aaa.txt"))
        try Data("b".utf8).write(to: trash.appendingPathComponent("zzz.txt"))
        defer { try? FileManager.default.removeItem(at: root) }

        let cancel = CancelFlag()
        let request = WipeRequest(
            roots: [trash],
            level: .simple,
            respectSSD: true,
            probe: FixedVolumeProbe(solidState: true),
            inspector: quiet
        )
        cancel.cancel()
        let result = WipeRunner.run(request, cancel: cancel) { _ in }

        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertEqual(result.erasedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("aaa.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("zzz.txt").path))
    }

    func testRunItemsAcceptsUnsortedInput() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoAway-items-\(UUID().uuidString)", isDirectory: true)
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        let nested = trash.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("1".utf8).write(to: nested.appendingPathComponent("deep.txt"))
        defer { try? FileManager.default.removeItem(at: root) }

        let items = TrashEnumerator.collect(roots: [trash])
        XCTAssertEqual(items.count, 3)
        let request = WipeRequest(
            roots: [trash],
            level: .simple,
            respectSSD: true,
            probe: FixedVolumeProbe(solidState: true),
            inspector: quiet
        )
        let result = WipeRunner.run(items: items.reversed(), request: request, cancel: CancelFlag()) { _ in }
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.erasedCount, 3)
    }

    func testEmptyTrash() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoAway-empty-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let request = WipeRequest(
            roots: [root],
            level: .simple,
            respectSSD: true,
            probe: FixedVolumeProbe(solidState: true),
            inspector: quiet
        )
        let result = WipeRunner.run(request, cancel: CancelFlag()) { _ in }
        XCTAssertEqual(result.outcome, .empty)
    }
}

final class AssuranceTests: XCTestCase {
    func testSnapshotParserExtractsDates() {
        let output = """
        Snapshots for volume group containing disk /:
        com.apple.TimeMachine.2026-10-07-091500.local
        com.apple.TimeMachine.2026-10-07-101500.local
        com.apple.TimeMachine.not-a-date.local
        """
        XCTAssertEqual(SnapshotParser.dates(in: output), ["2026-10-07-091500", "2026-10-07-101500"])
        XCTAssertFalse(SnapshotParser.isValidDate("2026-10-07-09150;"))
    }

    func testWarningsAndSummary() {
        let home = VolumeClass(mountPoint: "/", name: "Macintosh HD", filesystem: "apfs", isSolidState: true, isNetwork: false)
        let risky = VolumeAssurance(
            volume: home,
            inPlaceOverwrite: false,
            freeSpaceScrubbed: false,
            localSnapshots: ["2026-10-07-091500"],
            timeMachineConfigured: true,
            fileVaultOn: false
        )
        XCTAssertTrue(risky.warnings.contains(.localSnapshots(count: 1, mountPoint: "/")))
        XCTAssertTrue(risky.warnings.contains(.fileVaultOff))
        XCTAssertFalse(risky.isClean)

        let clean = VolumeAssurance(volume: home, inPlaceOverwrite: false, freeSpaceScrubbed: true, fileVaultOn: true)
        XCTAssertTrue(clean.isClean)
        XCTAssertTrue(clean.summary.contains("free space scrubbed"))

        let hfs = VolumeClass(mountPoint: "/Volumes/X", filesystem: "hfs", isSolidState: false, isNetwork: false)
        XCTAssertTrue(hfs.inPlaceOverwrite)
    }

    func testFailureKindClassification() {
        XCTAssertEqual(FailureKind.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))), .permission)
        XCTAssertEqual(FailureKind.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))), .busy)
        XCTAssertEqual(FailureKind.classify(SecureEraserError.outsideTrash("/x")), .outsideTrash)
    }
}
