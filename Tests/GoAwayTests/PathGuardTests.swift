import XCTest
@testable import GoAwayCore

final class PathGuardTests: XCTestCase {
    func testAcceptsNestedTrashPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoAway-guard-\(UUID().uuidString)", isDirectory: true)
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let guardrail = PathGuard(roots: [trash])
        let nested = trash.appendingPathComponent("folder/file.txt")
        XCTAssertTrue(guardrail.allowsUnlink(nested))
        XCTAssertTrue(guardrail.allowsOverwrite(nested))
        XCTAssertTrue(guardrail.isRoot(trash))
        XCTAssertFalse(guardrail.isRoot(nested))
    }

    func testRejectsSiblingPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoAway-guard-\(UUID().uuidString)", isDirectory: true)
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        let decoy = root.appendingPathComponent("Trash-evil", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let guardrail = PathGuard(roots: [trash])
        XCTAssertFalse(guardrail.allowsUnlink(decoy.appendingPathComponent("secret.txt")))
        XCTAssertFalse(guardrail.contains(decoy.path))
    }

    func testSymlinkEscapeCannotBeOverwritten() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoAway-guard-\(UUID().uuidString)", isDirectory: true)
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let secret = outside.appendingPathComponent("secret.txt")
        try Data("keep me".utf8).write(to: secret)
        let link = trash.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        defer { try? FileManager.default.removeItem(at: root) }

        let guardrail = PathGuard(roots: [trash])
        XCTAssertTrue(guardrail.allowsUnlink(link))
        XCTAssertFalse(guardrail.allowsOverwrite(link))
    }
}
