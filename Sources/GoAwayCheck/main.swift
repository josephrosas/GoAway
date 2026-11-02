import Darwin
import Foundation
import GoAwayCore

@main
enum GoAwayCheck {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--bench" {
            Bench.run(arguments: Array(arguments.dropFirst()))
            return
        }
        if arguments.first == "--forensic" {
            do {
                let findings = try Forensic.run()
                Forensic.printReport(findings)
                exit(findings.allSatisfy(\.passed) ? 0 : 1)
            } catch {
                fputs("forensic: setup failed: \(error)\n", stderr)
                exit(2)
            }
        }

        do {
            try testPassCounts()
            try testDoDPattern()
            try testSSDOverride()
            try testPathGuard()
            try testOverwrite()
            try testRepeatingPatternAcrossChunks()
            try testFakeTrash()
            try testSymlinkSafety()
            try testCancel()
            try testEmpty()
            try testProbeClassifiedOncePerRoot()
            try testParallelWipeOnSSD()
            try testCancelMidRun()
            try testRunItemsMatchesCollect()
            try testRetryFailedPath()
            try testLockedItems()
            try testScrubLeftovers()
            try testCancelInsideFile()
            try testSelectedItems()
            try testWorkLanes()
            try testScrubHeadroom()
            try testStoredErrno()
            try testFailureKinds()
            try testSnapshotParser()
            try testAssuranceWarnings()
            try testSortedForErase()
            try testFreeSpaceScrubOnDiskImage()
            try testPrivacyDenialClassification()
            try testPermissionProbes()
            try testCollectReportFlagsUnreadable()
            try testForensic()
            print("GoAwayCheck: all passed")
        } catch {
            fputs("GoAwayCheck failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static let quietInspector = FixedAssuranceInspector(snapshots: [], timeMachine: false, fileVault: true)

    private static func testPassCounts() throws {
        try expect(WipeLevel.simple.passCount == 1, "simple")
        try expect(WipeLevel.doe.passCount == 3, "doe")
        try expect(WipeLevel.dod.passCount == 7, "dod")
        try expect(WipeLevel.gutmann.passCount == 35, "gutmann")
    }

    private static func testDoDPattern() throws {
        try expect(
            WipeLevel.dod.passes == [
                .constant(0xF6),
                .constant(0x00),
                .constant(0xFF),
                .random,
                .constant(0x00),
                .constant(0xFF),
                .random
            ],
            "dod pattern"
        )
    }

    private static func testSSDOverride() throws {
        try expect(
            WipeLevel.effectivePasses(level: .gutmann, isSSD: true, respectSSD: true) == WipeLevel.simple.passes,
            "ssd override"
        )
        try expect(
            WipeLevel.effectivePasses(level: .gutmann, isSSD: true, respectSSD: false).count == 35,
            "ssd override off"
        )
    }

    private static func testPathGuard() throws {
        let root = tempRoot("check")
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        let decoy = root.appendingPathComponent("Trash-evil", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let guardrail = PathGuard(roots: [trash])
        try expect(guardrail.allowsUnlink(trash.appendingPathComponent("folder/file.txt")), "nested ok")
        try expect(!guardrail.contains(decoy.appendingPathComponent("secret.txt").path), "sibling rejected")

        let secret = outside.appendingPathComponent("secret.txt")
        try Data("keep me".utf8).write(to: secret)
        let link = trash.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        try expect(guardrail.allowsUnlink(link), "unlink symlink")
        try expect(!guardrail.allowsOverwrite(link), "no overwrite escape")
    }

    private static func testOverwrite() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoAway-over-\(UUID().uuidString).bin")
        let original = Data(repeating: 0x41, count: 4096)
        try original.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try SecureEraser.overwriteContents(at: url.path, passes: [.constant(0x00)])
        let after = try Data(contentsOf: url)
        try expect(after.count == original.count && after.allSatisfy { $0 == 0 }, "overwrite zeros")

        try SecureEraser.overwriteContents(at: url.path, passes: [.random])
        let random = try Data(contentsOf: url)
        try expect(random.count == original.count && !random.allSatisfy { $0 == 0 }, "overwrite random")
    }

    /// A 3-byte pattern must stay phase-aligned across chunk boundaries and on
    /// files whose length is not a multiple of the pattern.
    private static func testRepeatingPatternAcrossChunks() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoAway-rep-\(UUID().uuidString).bin")
        let size = SecureEraser.chunkSize * 2 + 7
        try Data(count: size).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let pattern: [UInt8] = [0x92, 0x49, 0x24]
        try SecureEraser.overwriteContents(at: url.path, passes: [.repeating(pattern)])
        let after = try Data(contentsOf: url)
        try expect(after.count == size, "repeating size")
        var ok = true
        after.withUnsafeBytes { raw in
            for (index, byte) in raw.enumerated() where byte != pattern[index % 3] {
                ok = false
                break
            }
        }
        try expect(ok, "repeating pattern aligned")

        try SecureEraser.overwriteContents(at: url.path, passes: [.constant(0xAA)])
        let constant = try Data(contentsOf: url)
        try expect(constant.allSatisfy { $0 == 0xAA }, "constant pass after repeating")
    }

    private static func testFakeTrash() throws {
        let root = tempRoot("fake")
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
            inspector: quietInspector
        )
        let result = WipeRunner.run(request, cancel: CancelFlag()) { _ in }
        try expect(result.outcome == .completed && result.failures.isEmpty, "wipe completed")
        try expect(!FileManager.default.fileExists(atPath: nested.appendingPathComponent("note.txt").path), "file gone")
        try expect(try String(contentsOf: outside, encoding: .utf8) == "stay", "outsider intact")
        let leftover = try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)
        try expect(leftover.isEmpty, "trash empty")
        try expect(result.assurances.count == 1, "one assurance")
        try expect(result.assurances[0].inPlaceOverwrite, "apfs overwrites in place")
        try expect(result.assurances[0].summary.hasPrefix("overwritten in place"), "summary \(result.assurances[0].summary)")
        try expect(result.warnings.isEmpty, "no warnings")
    }

    private static func testSymlinkSafety() throws {
        let root = tempRoot("link")
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
            inspector: quietInspector
        )
        let result = WipeRunner.run(request, cancel: CancelFlag()) { _ in }
        try expect(result.outcome == .completed, "symlink wipe")
        try expect(!FileManager.default.fileExists(atPath: link.path), "link gone")
        try expect(try String(contentsOf: outside, encoding: .utf8) == "keep-secret", "target intact")
    }

    private static func testCancel() throws {
        let root = tempRoot("cancel")
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: trash.appendingPathComponent("aaa.txt"))
        try Data("b".utf8).write(to: trash.appendingPathComponent("zzz.txt"))
        defer { try? FileManager.default.removeItem(at: root) }

        let cancel = CancelFlag()
        cancel.cancel()
        let request = WipeRequest(
            roots: [trash],
            level: .simple,
            respectSSD: true,
            probe: FixedVolumeProbe(solidState: true),
            inspector: quietInspector
        )
        let result = WipeRunner.run(request, cancel: cancel) { _ in }
        try expect(result.outcome == .cancelled && result.erasedCount == 0, "cancelled")
        try expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("aaa.txt").path), "left a")
        try expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("zzz.txt").path), "left b")
    }

    private static func testEmpty() throws {
        let root = tempRoot("empty")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = WipeRequest(
            roots: [root],
            level: .simple,
            respectSSD: true,
            probe: FixedVolumeProbe(solidState: true),
            inspector: quietInspector
        )
        let result = WipeRunner.run(request, cancel: CancelFlag()) { _ in }
        try expect(result.outcome == .empty, "empty")
    }

    private static func testProbeClassifiedOncePerRoot() throws {
        let root = tempRoot("probe")
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        for index in 0..<40 {
            try Data("x\(index)".utf8).write(to: trash.appendingPathComponent("f\(index).txt"))
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let probe = CountingProbe()
        let request = WipeRequest(roots: [trash], level: .dod, respectSSD: true, probe: probe, inspector: quietInspector)
        let result = WipeRunner.run(request, cancel: CancelFlag()) { _ in }
        try expect(result.outcome == .completed && result.erasedCount == 40, "probe wipe")
        try expect(probe.count == 1, "probe classified once, got \(probe.count)")
    }

    private static func testParallelWipeOnSSD() throws {
        let root = tempRoot("parallel")
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        let outside = root.appendingPathComponent("outside.txt")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try Data("stay".utf8).write(to: outside)
        for folder in 0..<8 {
            let dir = trash.appendingPathComponent("d\(folder)/inner", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for file in 0..<25 {
                try Data(repeating: UInt8(file), count: 2048 + file).write(to: dir.appendingPathComponent("f\(file).bin"))
            }
        }
        let link = trash.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: root) }

        let request = WipeRequest(
            roots: [trash],
            level: .simple,
            respectSSD: true,
            probe: FixedVolumeProbe(solidState: true),
            inspector: quietInspector
        )
        let emits = Counter()
        let lastDone = Counter(-1)
        let regressions = Counter()
        let result = WipeRunner.run(request, cancel: CancelFlag()) { snapshot in
            emits.increment()
            if snapshot.itemsDone < lastDone.value { regressions.increment() }
            lastDone.value = snapshot.itemsDone
        }
        try expect(result.outcome == .completed, "parallel completed")
        try expect(result.failures.isEmpty, "parallel no failures: \(result.failures)")
        try expect(result.erasedCount == 8 * 25 + 8 * 2 + 1, "parallel count \(result.erasedCount)")
        let leftover = try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)
        try expect(leftover.isEmpty, "parallel trash empty: \(leftover)")
        try expect(try String(contentsOf: outside, encoding: .utf8) == "stay", "parallel outsider intact")
        try expect(regressions.value == 0, "progress monotonic")
        try expect(emits.value >= 2, "progress emitted")
    }

    private static func testCancelMidRun() throws {
        let root = tempRoot("midcancel")
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let count = 24
        for index in 0..<count {
            try Data(count: 4 * 1024 * 1024).write(to: trash.appendingPathComponent(String(format: "f%02d.bin", index)))
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let cancel = CancelFlag()
        let request = WipeRequest(
            roots: [trash],
            level: .dod,
            respectSSD: false,
            probe: FixedVolumeProbe(solidState: false),
            inspector: quietInspector
        )
        let result = WipeRunner.run(request, cancel: cancel) { snapshot in
            if snapshot.itemsDone >= 1 { cancel.cancel() }
        }
        try expect(result.outcome == .cancelled, "mid cancel outcome \(result.outcome)")
        try expect(result.erasedCount >= 1 && result.remainingCount >= 1, "mid cancel counts \(result.erasedCount)/\(result.remainingCount)")
        let leftover = try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)
        try expect(leftover.count == result.remainingCount, "mid cancel leftover \(leftover.count) vs \(result.remainingCount)")
    }

    private static func testRunItemsMatchesCollect() throws {
        let root = tempRoot("items")
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        let nested = trash.appendingPathComponent("a/b/c", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("1".utf8).write(to: nested.appendingPathComponent("deep.txt"))
        try Data("2".utf8).write(to: trash.appendingPathComponent("top.txt"))
        defer { try? FileManager.default.removeItem(at: root) }

        let items = TrashEnumerator.collect(roots: [trash])
        try expect(items.count == 5, "collected \(items.count)")
        try expect(items.first?.kind == .file && items.first?.url.lastPathComponent == "deep.txt", "deepest first")
        try expect(items.last?.url.lastPathComponent == "a", "shallowest dir last")

        let request = WipeRequest(
            roots: [trash],
            level: .simple,
            respectSSD: true,
            probe: FixedVolumeProbe(solidState: true),
            inspector: quietInspector
        )
        let result = WipeRunner.run(items: items.shuffled(), request: request, cancel: CancelFlag()) { _ in }
        try expect(result.outcome == .completed && result.failures.isEmpty && result.erasedCount == 5, "run(items:) ok")
        let leftover = try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)
        try expect(leftover.isEmpty, "run(items:) empty")
    }

    /// A file that appears in a folder after the scan must not be removed
    /// unerased along with the folder. The folder fails, keeps its name, and a
    /// retry over its subtree erases what is left.
    private static func testRetryFailedPath() throws {
        let root = tempRoot("retry")
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        let folder = trash.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("scanned".utf8).write(to: folder.appendingPathComponent("scanned.txt"))
        defer { try? FileManager.default.removeItem(at: root) }

        let request = WipeRequest(
            roots: [trash],
            level: .simple,
            respectSSD: true,
            probe: FixedVolumeProbe(solidState: true),
            inspector: quietInspector
        )
        let items = TrashEnumerator.collect(roots: [trash])
        let late = folder.appendingPathComponent("late.txt")
        try Data("late".utf8).write(to: late)

        let first = WipeRunner.run(items: items, request: request, cancel: CancelFlag()) { _ in }
        try expect(first.failures.count == 1, "folder fails: \(first.failures)")
        let failedPath = first.failures.first.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path }
        try expect(failedPath == folder.resolvingSymlinksInPath().path, "failure keeps original name: \(first.failures)")
        try expect(FileManager.default.fileExists(atPath: folder.path), "failed folder still under its name")
        try expect(FileManager.default.fileExists(atPath: late.path), "late file not dropped unerased")

        let guardrail = PathGuard(roots: [trash])
        let retryItems = first.failures.flatMap {
            TrashEnumerator.collectSubtree(at: URL(fileURLWithPath: $0.path), guardrail: guardrail)
        }
        try expect(retryItems.count == 2, "subtree has folder and late file: \(retryItems.count)")
        let second = WipeRunner.run(items: retryItems, request: request, cancel: CancelFlag()) { _ in }
        try expect(second.outcome == .completed && second.failures.isEmpty, "retry clean: \(second.failures)")
        let leftover = try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)
        try expect(leftover.isEmpty, "retry trash empty")
    }

    /// Read-only files in read-only folders (Git objects, Go module caches),
    /// user-locked files and "deny delete" ACLs are erased, not reported.
    private static func testLockedItems() throws {
        if getuid() == 0 { return }
        let root = tempRoot("locked")
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        let objects = trash.appendingPathComponent("repo/.git/objects/ab", isDirectory: true)
        try FileManager.default.createDirectory(at: objects, withIntermediateDirectories: true)
        let object = objects.appendingPathComponent("cdef0123")
        try Data(repeating: 0x33, count: 8192).write(to: object)
        chmod(object.path, 0o444)
        chmod(objects.path, 0o555)

        let flagged = trash.appendingPathComponent("locked.txt")
        try Data("locked".utf8).write(to: flagged)
        try expect(chflags(flagged.path, UInt32(UF_IMMUTABLE)) == 0, "set uchg")

        let denied = trash.appendingPathComponent("acl.txt")
        try Data("acl".utf8).write(to: denied)
        let aclStatus = shell("/bin/chmod", ["+a", "everyone deny delete,write", denied.path])
        defer {
            _ = shell("/bin/chmod", ["-R", "-N", root.path])
            _ = shell("/usr/bin/chflags", ["-R", "nouchg", root.path])
            _ = shell("/bin/chmod", ["-R", "u+rwx", root.path])
            try? FileManager.default.removeItem(at: root)
        }
        try expect(aclStatus == 0, "set ACL")

        let request = WipeRequest(
            roots: [trash],
            level: .simple,
            respectSSD: true,
            probe: FixedVolumeProbe(solidState: true),
            inspector: quietInspector
        )
        let result = WipeRunner.run(request, cancel: CancelFlag()) { _ in }
        try expect(result.outcome == .completed && result.failures.isEmpty, "locked items erased: \(result.failures)")
        let leftover = try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)
        try expect(leftover.isEmpty, "locked trash empty: \(leftover.map(\.lastPathComponent))")
    }

    /// A scrub folder left by a killed run is deleted directly and never
    /// enumerated for overwriting.
    private static func testScrubLeftovers() throws {
        let root = tempRoot("leftover")
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        let leftover = trash.appendingPathComponent(FreeSpaceScrubber.folderPrefix + "deadbeef", isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data(count: 64 * 1024).write(to: leftover.appendingPathComponent("fill.bin"))
        try Data("real".utf8).write(to: trash.appendingPathComponent("real.txt"))
        defer { try? FileManager.default.removeItem(at: root) }

        let items = TrashEnumerator.collect(roots: [trash])
        try expect(items.map(\.url.lastPathComponent) == ["real.txt"], "scrub folder skipped: \(items.map(\.url.lastPathComponent))")

        let released = FreeSpaceScrubber.removeLeftovers(in: [trash])
        try expect(released == 64 * 1024, "released \(released)")
        try expect(!FileManager.default.fileExists(atPath: leftover.path), "leftover removed")
        try expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("real.txt").path), "real item untouched")
    }

    /// Cancel stops inside a large file instead of finishing it; the file
    /// stays in Trash and is counted as remaining, not failed.
    private static func testCancelInsideFile() throws {
        let root = tempRoot("cancelfile")
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let big = trash.appendingPathComponent("big.bin")
        try Data(count: 64 * 1024 * 1024).write(to: big)
        defer { try? FileManager.default.removeItem(at: root) }

        let cancel = CancelFlag()
        let request = WipeRequest(
            roots: [trash],
            level: .gutmann,
            respectSSD: false,
            probe: FixedVolumeProbe(solidState: false),
            inspector: quietInspector
        )
        let result = WipeRunner.run(request, cancel: cancel) { snapshot in
            if snapshot.bytesDone > 0 { cancel.cancel() }
        }
        try expect(result.outcome == .cancelled, "cancelled: \(result.outcome)")
        try expect(result.failures.isEmpty, "not a failure: \(result.failures)")
        try expect(result.remainingCount == 1, "remaining \(result.remainingCount)")
        try expect(FileManager.default.fileExists(atPath: big.path), "file stays in Trash")
    }

    /// Dropped items: disks, the home folder, Trash itself and GoAway are
    /// refused; the rest moves into Trash and only that is erased.
    private static func testSelectedItems() throws {
        let fm = FileManager.default
        let root = tempRoot("selected")
        let home = root.appendingPathComponent("home", isDirectory: true)
        let trash = home.appendingPathComponent(".Trash", isDirectory: true)
        let docs = home.appendingPathComponent("Documents", isDirectory: true)
        let folder = docs.appendingPathComponent("Folder", isDirectory: true)
        let app = root.appendingPathComponent("GoAway.app", isDirectory: true)
        for dir in [trash, folder, app] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: root) }

        let keep = trash.appendingPathComponent("keep.txt")
        let alreadyInTrash = trash.appendingPathComponent("already.txt")
        let secret = docs.appendingPathComponent("secret.txt")
        let locked = docs.appendingPathComponent("locked.txt")
        for url in [keep, alreadyInTrash, secret, locked, folder.appendingPathComponent("inner.txt")] {
            try Data("x".utf8).write(to: url)
        }

        func refusal(_ url: URL) -> SelectedItems.Refusal? {
            SelectedItems.refusal(for: url, trashRoots: [trash], home: home, app: app)
        }
        try expect(refusal(URL(fileURLWithPath: "/")) == .volume, "disk refused")
        try expect(refusal(home) == .home, "home refused")
        try expect(refusal(root) == .home, "home's parent refused")
        try expect(refusal(trash) == .trash, "Trash refused")
        try expect(refusal(app) == .goAway, "GoAway refused")
        try expect(refusal(docs.appendingPathComponent("gone.txt")) == .missing, "missing refused")
        try expect(refusal(secret) == nil, "file accepted")
        try expect(refusal(alreadyInTrash) == nil, "item in Trash accepted")

        var moved: [String] = []
        let prepared = SelectedItems.prepare(
            [secret, folder, alreadyInTrash, home, locked],
            trashRoots: [trash], home: home, app: app,
            moveToTrash: { url in
                if url.lastPathComponent == "locked.txt" { throw CocoaError(.fileWriteNoPermission) }
                let target = trash.appendingPathComponent(url.lastPathComponent)
                try fm.moveItem(at: url, to: target)
                moved.append(url.lastPathComponent)
                return target
            }
        )
        try expect(moved == ["secret.txt", "Folder"], "moved \(moved)")
        let names = Set(prepared.items.map(\.url.lastPathComponent))
        try expect(names == ["secret.txt", "Folder", "inner.txt", "already.txt"], "items \(names)")
        try expect(prepared.roots.map(PathGuard.normalize) == [PathGuard.normalize(trash)], "roots \(prepared.roots)")
        try expect(prepared.failures.map(\.path) == [home.path, locked.path], "failures \(prepared.failures)")
        try expect(prepared.failures.last?.message.hasPrefix("Could not move to Trash") == true, "move failure message")

        let request = WipeRequest(
            roots: prepared.roots,
            level: .simple,
            respectSSD: true,
            probe: FixedVolumeProbe(solidState: true),
            inspector: quietInspector
        )
        let result = WipeRunner.run(items: prepared.items, request: request, cancel: CancelFlag()) { _ in }
        try expect(result.failures.isEmpty, "selection erased: \(result.failures)")
        let left = try fm.contentsOfDirectory(atPath: trash.path)
        try expect(left == ["keep.txt"], "rest of Trash untouched: \(left)")
        try expect(fm.fileExists(atPath: locked.path), "failed move leaves the original")
    }

    /// Lanes: a parallel set for each SSD, one lane per hard drive, all at once.
    private static func testWorkLanes() throws {
        let ssd = VolumeClass(mountPoint: "/", filesystem: "apfs", isSolidState: true, isNetwork: false)
        let hdd = VolumeClass(mountPoint: "/Volumes/HDD", filesystem: "hfs", isSolidState: false, isNetwork: false)
        let volumes = Array(repeating: ssd, count: 10) + Array(repeating: hdd, count: 10)
        let lanes = WipeRunner.laneCounts(for: Array(volumes.indices), volumes: volumes)
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        try expect(lanes["/"] == min(WipeRunner.maxWorkers, cores), "ssd lanes \(lanes)")
        try expect(lanes["/Volumes/HDD"] == 1, "hdd lanes \(lanes)")
        try expect(WipeRunner.passLabel(for: [ssd, hdd], request: WipeRequest(roots: [], level: .dod, respectSSD: true)) == "mixed passes", "mixed label")
        try expect(WipeRunner.passLabel(for: [ssd], request: WipeRequest(roots: [], level: .dod, respectSSD: true)) == "1 pass (SSD)", "ssd label")
    }

    /// The startup and home volumes keep at least 2 GB (or 2%) free; others 256 MB.
    private static func testScrubHeadroom() throws {
        let gb: Int64 = 1024 * 1024 * 1024
        let startup = VolumeClass(mountPoint: "/", filesystem: "apfs", isSolidState: true, isNetwork: false)
        let data = VolumeClass(mountPoint: "/System/Volumes/Data", filesystem: "apfs", isSolidState: true, isNetwork: false)
        let external = VolumeClass(mountPoint: "/Volumes/Backup", filesystem: "hfs", isSolidState: false, isNetwork: false)
        let homeDisk = VolumeClass(mountPoint: "/Volumes/Home", filesystem: "apfs", isSolidState: true, isNetwork: false)
        let home = "/Users/someone"

        try expect(FreeSpaceScrubber.headroom(for: startup, capacity: 50 * gb, homePath: home) == 2 * gb, "small startup floor")
        try expect(FreeSpaceScrubber.headroom(for: data, capacity: 1000 * gb, homePath: home) == 20 * gb, "2% of large data volume")
        try expect(FreeSpaceScrubber.headroom(for: external, capacity: 1000 * gb, homePath: home) == FreeSpaceScrubber.defaultHeadroom, "external")
        try expect(FreeSpaceScrubber.headroom(for: homeDisk, capacity: 500 * gb, homePath: "/Volumes/Home/someone") == 10 * gb, "home volume")
    }

    /// Failure kinds come from the errno captured at the failing call.
    private static func testStoredErrno() throws {
        errno = 0
        try expect(FailureKind.classify(SecureEraserError.openFailed("/x", errno: EACCES)) == .permission, "stored EACCES")
        try expect(FailureKind.classify(SecureEraserError.writeFailed("/x", errno: EBUSY)) == .busy, "stored EBUSY")
        errno = EACCES
        try expect(FailureKind.classify(SecureEraserError.removeFailed("/x", errno: ENOTEMPTY)) == .other, "ignores global errno")
    }

    private static func testFailureKinds() throws {
        try expect(FailureKind.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))) == .permission, "eacces")
        try expect(FailureKind.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))) == .busy, "ebusy")
        try expect(FailureKind.classify(SecureEraserError.outsideTrash("/x")) == .outsideTrash, "outside")
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        try expect(FailureKind.classify(cocoa) == .permission, "cocoa permission")
    }

    private static func testSnapshotParser() throws {
        let output = """
        Snapshots for volume group containing disk /:
        com.apple.TimeMachine.2026-10-07-091500.local
        com.apple.TimeMachine.2026-10-07-101500.local
          com.apple.TimeMachine.2026-10-07-111500.local
        com.apple.os.update-ABCDEF
        com.apple.TimeMachine.not-a-date.local
        """
        let dates = SnapshotParser.dates(in: output)
        try expect(dates == ["2026-10-07-091500", "2026-10-07-101500", "2026-10-07-111500"], "parsed \(dates)")
        try expect(SnapshotParser.isValidDate("2026-10-07-091500"), "valid date")
        try expect(!SnapshotParser.isValidDate("2026-10-07-09150;"), "reject shell chars")
        try expect(!SnapshotParser.isValidDate("2026-10-07"), "reject short")
        try expect(SnapshotParser.dates(in: "").isEmpty, "empty")
    }

    private static func testAssuranceWarnings() throws {
        let home = VolumeClass(mountPoint: "/", name: "Macintosh HD", filesystem: "apfs", isSolidState: true, isNetwork: false)
        try expect(home.inPlaceOverwrite, "apfs overwrites in place")
        let clean = VolumeAssurance(volume: home, inPlaceOverwrite: home.inPlaceOverwrite, freeSpaceScrubbed: true, fileVaultOn: true)
        try expect(clean.warnings.isEmpty && clean.isClean, "clean")
        try expect(clean.summary == "overwritten in place, free space scrubbed, FileVault on", "summary \(clean.summary)")

        let risky = VolumeAssurance(
            volume: home,
            inPlaceOverwrite: home.inPlaceOverwrite,
            freeSpaceScrubbed: false,
            localSnapshots: ["2026-10-07-091500", "2026-10-07-101500"],
            timeMachineConfigured: true,
            fileVaultOn: false
        )
        try expect(risky.summary.hasPrefix("overwritten; snapshots keep older copies"), "snapshot summary \(risky.summary)")
        try expect(risky.warnings.contains(.localSnapshots(count: 2, mountPoint: "/")), "snapshot warning")
        try expect(risky.warnings.contains(.fileVaultOff), "filevault warning")
        try expect(risky.warnings.contains(.timeMachineConfigured), "tm info")
        try expect(!risky.isClean, "not clean")
        try expect(!AssuranceWarning.timeMachineConfigured.blocksAutoQuit, "tm does not block")

        let external = VolumeClass(mountPoint: "/Volumes/Backup", name: "Backup", filesystem: "hfs", isSolidState: false, isNetwork: false)
        let hfs = VolumeAssurance(volume: external, inPlaceOverwrite: external.inPlaceOverwrite, freeSpaceScrubbed: false, fileVaultOn: false)
        try expect(hfs.inPlaceOverwrite, "hfs in place")
        try expect(!hfs.warnings.contains(.fileVaultOff), "filevault only for home volume")

        let share = VolumeClass(mountPoint: "/Volumes/Share", filesystem: "smbfs", isSolidState: false, isNetwork: true)
        let network = VolumeAssurance(volume: share, inPlaceOverwrite: share.inPlaceOverwrite, freeSpaceScrubbed: false)
        try expect(!share.inPlaceOverwrite && network.summary == "unlinked only (network volume)", "network \(network.summary)")
    }

    private static func testSortedForErase() throws {
        let base = URL(fileURLWithPath: "/tmp/T", isDirectory: true)
        let items = [
            TrashItem(url: base.appendingPathComponent("a"), kind: .directory, byteSize: 0, linkCount: 1, isDataless: false),
            TrashItem(url: base.appendingPathComponent("a/b"), kind: .directory, byteSize: 0, linkCount: 1, isDataless: false),
            TrashItem(url: base.appendingPathComponent("a/b/c.txt"), kind: .file, byteSize: 1, linkCount: 1, isDataless: false),
            TrashItem(url: base.appendingPathComponent("a/z.txt"), kind: .file, byteSize: 1, linkCount: 1, isDataless: false)
        ]
        let sorted = TrashEnumerator.sortedForErase(items.shuffled())
        let names = sorted.map { $0.url.lastPathComponent }
        try expect(names == ["c.txt", "z.txt", "b", "a"], "sorted \(names)")
    }

    /// Scrubs a throwaway 64 MB APFS image. Skipped when hdiutil is unavailable.
    private static func testFreeSpaceScrubOnDiskImage() throws {
        let image = FileManager.default.temporaryDirectory.appendingPathComponent("GoAway-scrub-\(UUID().uuidString).dmg")
        let volumeName = "GoAwayScrub\(Int.random(in: 1000...9999))"
        guard shell("/usr/bin/hdiutil", ["create", "-quiet", "-size", "64m", "-fs", "APFS", "-volname", volumeName, image.path]) == 0 else {
            print("GoAwayCheck: skipping scrub test (hdiutil create failed)")
            return
        }
        defer { try? FileManager.default.removeItem(at: image) }
        guard shell("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", image.path]) == 0 else {
            print("GoAwayCheck: skipping scrub test (hdiutil attach failed)")
            return
        }
        let mount = URL(fileURLWithPath: "/Volumes/\(volumeName)", isDirectory: true)
        defer { _ = shell("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path]) }

        let trash = mount.appendingPathComponent(".Trashes/\(getuid())", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 1024 * 1024).write(to: trash.appendingPathComponent("victim.bin"))

        let before = VolumeSpace.available(at: mount.path)
        try expect(before > 16 * 1024 * 1024, "image has free space \(before)")

        let headroom: Int64 = 8 * 1024 * 1024
        var low = before
        let outcome = try FreeSpaceScrubber.scrub(inside: trash, headroom: headroom, cancel: CancelFlag()) { _, _ in
            low = min(low, VolumeSpace.available(at: mount.path))
        }
        try expect(outcome.bytesWritten > 0 && !outcome.cancelled, "scrub wrote \(outcome.bytesWritten)")
        try expect(low < before / 2, "free space dropped during scrub: low=\(low) before=\(before)")
        let after = VolumeSpace.available(at: mount.path)
        try expect(after > before - 4 * 1024 * 1024, "free space restored: after=\(after) before=\(before)")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: trash.path).filter { $0.hasPrefix(".goaway-scrub") }
        try expect(leftovers.isEmpty, "no scrub leftovers")

        // Cancelled scrub must also leave nothing behind.
        let cancel = CancelFlag()
        let cancelled = try FreeSpaceScrubber.scrub(inside: trash, headroom: headroom, cancel: cancel) { written, _ in
            if written > 0 { cancel.cancel() }
        }
        try expect(cancelled.cancelled, "scrub cancelled")
        let afterCancel = try FileManager.default.contentsOfDirectory(atPath: trash.path).filter { $0.hasPrefix(".goaway-scrub") }
        try expect(afterCancel.isEmpty, "no leftovers after cancel")

        // Whole pipeline with scrub enabled reports it in the assurance, and
        // lists snapshots before the scrub starts.
        let order = OrderLog()
        let request = WipeRequest(
            roots: [trash],
            level: .simple,
            respectSSD: true,
            scrubFreeSpace: true,
            scrubHeadroom: headroom,
            probe: FixedVolumeProbe(solidState: true, mountPoint: mount.path),
            inspector: RecordingInspector(log: order)
        )
        let scrubEmits = Counter()
        let result = WipeRunner.run(request, cancel: CancelFlag()) { snapshot in
            if snapshot.isScrubbing {
                scrubEmits.increment()
                order.append("scrub")
            }
        }
        try expect(result.outcome == .completed && result.failures.isEmpty, "pipeline with scrub: \(result.failures)")
        try expect(scrubEmits.value > 0, "scrub phase reported")
        try expect(result.assurances.first?.freeSpaceScrubbed == true, "assurance scrubbed")
        try expect(result.assurances.first.map { $0.scrubbedBytes > 0 } == true, "pipeline scrub wrote data")
        try expect(order.first == "snapshots", "snapshots listed before scrub: \(order.entries.prefix(3))")

        // Scrub-only pass, as run after snapshots are deleted.
        let only = WipeRunner.scrubOnly(request, mountPoints: [mount.path], cancel: CancelFlag()) { _ in }
        try expect(!only.cancelled && only.failures.isEmpty, "scrub-only clean: \(only.failures)")
        try expect((only.scrubbed[mount.path] ?? 0) > 0, "scrub-only wrote data: \(only.scrubbed)")
        let skipped = WipeRunner.scrubOnly(request, mountPoints: ["/Volumes/elsewhere"], cancel: CancelFlag()) { _ in }
        try expect(skipped.scrubbed.isEmpty, "scrub-only respects mount filter")
    }

    // MARK: - Helpers

    private static func tempRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("GoAway-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    /// Erased data must not be readable from the raw image. Skipped when hdiutil is unavailable.
    private static func testForensic() throws {
        let findings: [Forensic.Finding]
        do {
            findings = try Forensic.run()
        } catch {
            print("GoAwayCheck: skipping forensic test (\(error))")
            return
        }
        let failed = findings.filter { !$0.passed }
        if !failed.isEmpty {
            Forensic.printReport(findings)
        }
        try expect(failed.isEmpty, "forensic: \(failed.map { "\($0.filesystem.rawValue) \($0.label)" }.joined(separator: "; "))")
    }

    static func shell(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func testPrivacyDenialClassification() throws {
        try expect(FullDiskAccess.isPrivacyDenial(EPERM), "EPERM is denial")
        try expect(FullDiskAccess.isPrivacyDenial(EACCES), "EACCES is denial")
        try expect(!FullDiskAccess.isPrivacyDenial(ENOENT), "ENOENT is not denial")

        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        try expect(FullDiskAccess.isPrivacyDenial(posix as Error), "posix EPERM error")
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        try expect(FullDiskAccess.isPrivacyDenial(cocoa as Error), "cocoa no-permission error")
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                              userInfo: [NSUnderlyingErrorKey: posix])
        try expect(FullDiskAccess.isPrivacyDenial(wrapped as Error), "wrapped posix error")
        let missing = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        try expect(!FullDiskAccess.isPrivacyDenial(missing as Error), "missing file is not denial")
    }

    private static func testPermissionProbes() throws {
        let root = tempRoot("probe")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        try Data("x".utf8).write(to: file)
        let missing = root.appendingPathComponent("missing").path

        try expect(FullDiskAccess.probeDirectory(root.path) == .readable, "readable dir")
        try expect(FullDiskAccess.probeFile(file.path) == .readable, "readable file")
        try expect(FullDiskAccess.probeDirectory(missing) == .other(ENOENT), "missing dir is other")
        try expect(FullDiskAccess.probeFile(missing) == .other(ENOENT), "missing file is other")

        // A real denial should surface as such, not as "nothing there".
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        defer { chmod(locked.path, 0o755) }
        chmod(locked.path, 0o000)
        if getuid() != 0 {
            try expect(FullDiskAccess.probeDirectory(locked.path) == .denied(EACCES), "locked dir is denied")
        }
    }

    private static func testCollectReportFlagsUnreadable() throws {
        let trash = tempRoot("report")
        let locked = trash.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        defer {
            chmod(locked.path, 0o755)
            try? FileManager.default.removeItem(at: trash)
        }
        try Data("x".utf8).write(to: locked.appendingPathComponent("inner.txt"))
        chmod(locked.path, 0o000)
        guard getuid() != 0 else { return }

        let report = TrashEnumerator.collectReport(roots: [trash])
        try expect(report.items.count == 1, "locked dir still listed as an item (\(report.items.count))")
        try expect(report.unreadable.count == 1, "one unreadable directory (\(report.unreadable.count))")
        try expect(
            report.unreadable.first?.url.standardizedFileURL.path == locked.standardizedFileURL.path,
            "unreadable path"
        )
        try expect(report.hasPrivacyDenial, "flagged as permission denial")

        // Plain `collect` keeps its old shape.
        try expect(TrashEnumerator.collect(roots: [trash]).count == 1, "collect wrapper")
    }

    private static func expect(_ condition: Bool, _ name: String) throws {
        if !condition { throw CheckError(name) }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int

    init(_ value: Int = 0) { stored = value }

    var value: Int {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }

    func increment() {
        lock.lock()
        stored += 1
        lock.unlock()
    }
}

private final class CountingProbe: VolumeClassifying, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func classify(_ url: URL) -> VolumeClass {
        lock.lock()
        calls += 1
        lock.unlock()
        return VolumeClass(mountPoint: "/", name: "Counted", filesystem: "apfs", isSolidState: true, isNetwork: false)
    }
}

private final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func append(_ entry: String) {
        lock.lock()
        stored.append(entry)
        lock.unlock()
    }

    var entries: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var first: String? { entries.first }
}

private struct RecordingInspector: AssuranceInspecting {
    let log: OrderLog

    func localSnapshots(mountPoint: String) -> [String] {
        log.append("snapshots")
        return []
    }

    func isTimeMachineConfigured() -> Bool { false }
    func isFileVaultOn() -> Bool? { true }
}

private struct CheckError: Error, CustomStringConvertible {
    var name: String
    init(_ name: String) { self.name = name }
    var description: String { name }
}

// MARK: - Benchmark

/// `GoAwayCheck --bench [small=N] [big=MB] [level=simple|dod] [serial]`
/// Builds a fake Trash in the temporary directory, wipes it, prints throughput.
private enum Bench {
    static func run(arguments: [String]) {
        var small = 5000
        var bigMB = 2048
        var level = WipeLevel.simple
        var serial = false
        for argument in arguments {
            if argument == "serial" { serial = true; continue }
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "small": small = Int(parts[1]) ?? small
            case "big": bigMB = Int(parts[1]) ?? bigMB
            case "level": level = WipeLevel(rawValue: parts[1]) ?? level
            default: break
            }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoAway-bench-\(UUID().uuidString)", isDirectory: true)
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            print("bench: creating \(small) x 4 KB files and \(bigMB) MB file…")
            let smallPayload = Data(repeating: 0x42, count: 4096)
            for index in 0..<small {
                let dir = trash.appendingPathComponent("d\(index % 50)", isDirectory: true)
                if index < 50 {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                }
                try smallPayload.write(to: dir.appendingPathComponent("f\(index).bin"))
            }
            if bigMB > 0 {
                let big = trash.appendingPathComponent("big.bin")
                FileManager.default.createFile(atPath: big.path, contents: nil)
                let handle = try FileHandle(forWritingTo: big)
                let chunk = Data(repeating: 0x7F, count: 16 * 1024 * 1024)
                var written = 0
                while written < bigMB * 1024 * 1024 {
                    try handle.write(contentsOf: chunk)
                    written += chunk.count
                }
                try handle.close()
            }
        } catch {
            fputs("bench: setup failed: \(error)\n", stderr)
            exit(1)
        }

        let request = WipeRequest(
            roots: [trash],
            level: level,
            respectSSD: false,
            probe: FixedVolumeProbe(solidState: !serial),
            inspector: FixedAssuranceInspector()
        )
        let items = TrashEnumerator.collect(roots: [trash])
        let planned = WipeRunner.plannedBytes(items: items, request: request)
        print("bench: \(items.count) items, \(planned / 1024 / 1024) MB planned, level=\(level.rawValue), \(serial ? "serial" : "parallel")")

        let emits = Counter()
        let start = Date()
        let result = WipeRunner.run(items: items, request: request, cancel: CancelFlag()) { _ in emits.increment() }
        let elapsed = Date().timeIntervalSince(start)

        let mb = Double(planned) / 1024 / 1024
        print(String(format: "bench: %.2f s, %.0f items/s, %.0f MB/s, %d progress emits, outcome=%@, failures=%d",
                     elapsed,
                     Double(result.erasedCount) / elapsed,
                     mb / elapsed,
                     emits.value,
                     String(describing: result.outcome),
                     result.failures.count))
    }
}
