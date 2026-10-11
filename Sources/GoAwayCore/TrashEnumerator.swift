import Darwin
import Foundation
import os

public enum TrashEnumerator {
    /// User Trash folders on the home volume and mounted local volumes.
    public static func discover(fileManager: FileManager = .default) -> [URL] {
        var roots: [URL] = []
        var seen = Set<String>()

        func add(_ url: URL) {
            let path = PathGuard.normalize(url)
            guard !path.isEmpty, !seen.contains(path) else { return }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return
            }
            seen.insert(path)
            roots.append(URL(fileURLWithPath: path, isDirectory: true))
        }

        if let home = try? fileManager.url(
            for: .trashDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            add(home)
        }

        add(fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true))

        let volumes = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsLocalKey, .volumeIsReadOnlyKey],
            options: [.skipHiddenVolumes]
        ) ?? []

        for volume in volumes {
            let values = try? volume.resourceValues(forKeys: [.volumeIsReadOnlyKey])
            if values?.volumeIsReadOnly == true { continue }
            if let trash = try? fileManager.url(
                for: .trashDirectory,
                in: .userDomainMask,
                appropriateFor: volume,
                create: false
            ) {
                add(trash)
            }
        }

        addVolumeTrashes(fileManager: fileManager, into: &roots, seen: &seen)
        log.info("Discovered Trash roots: \(roots.map(\.path).joined(separator: ", "), privacy: .public)")
        return roots
    }

    /// A directory inside Trash that could not be listed.
    public struct UnreadableDirectory: Sendable {
        public let url: URL
        public let message: String
        /// True when macOS refused for privacy reasons (Full Disk Access).
        public let isPrivacyDenial: Bool
    }

    public struct Report: Sendable {
        public var items: [TrashItem]
        public var unreadable: [UnreadableDirectory]

        public var hasPrivacyDenial: Bool {
            unreadable.contains { $0.isPrivacyDenial }
        }
    }

    static let log = Logger(subsystem: "com.unga.GoAway", category: "scan")

    public static func collect(roots: [URL], fileManager: FileManager = .default) -> [TrashItem] {
        collectReport(roots: roots, fileManager: fileManager).items
    }

    /// Like `collect`, but also reports every directory that could not be
    /// listed instead of silently treating it as empty.
    public static func collectReport(roots: [URL], fileManager: FileManager = .default) -> Report {
        let guardrail = PathGuard(roots: roots)
        var items: [TrashItem] = []
        var unreadable: [UnreadableDirectory] = []
        var visited = Set<String>()

        func list(_ url: URL) -> [URL] {
            do {
                return try fileManager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: Array(itemKeys),
                    options: []
                )
            } catch {
                let denial = FullDiskAccess.isPrivacyDenial(error)
                log.error("Cannot list \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public) privacy=\(denial)")
                unreadable.append(UnreadableDirectory(
                    url: url,
                    message: error.localizedDescription,
                    isPrivacyDenial: denial
                ))
                return []
            }
        }

        for root in roots {
            guard fileManager.fileExists(atPath: root.path) else { continue }
            var stack = [root]
            while let current = stack.popLast() {
                let path = PathGuard.normalize(current)
                guard visited.insert(path).inserted else { continue }
                guard guardrail.contains(path) else { continue }

                if guardrail.isRoot(current) {
                    stack.append(contentsOf: list(current))
                    continue
                }

                guard let item = makeItem(at: current, fileManager: fileManager) else { continue }
                items.append(item)
                if item.kind == .directory {
                    stack.append(contentsOf: list(current))
                }
            }
        }

        log.info("Scanned \(roots.count) root(s): \(items.count) item(s), \(unreadable.count) unreadable")
        return Report(items: sortedForErase(items), unreadable: unreadable)
    }

    /// Deepest paths first so directories are only removed after their children;
    /// files before directories at the same depth; stable by path.
    public static func sortedForErase(_ items: [TrashItem]) -> [TrashItem] {
        items.sorted { lhs, rhs in
            if lhs.depth != rhs.depth { return lhs.depth > rhs.depth }
            if lhs.kind != rhs.kind {
                return kindPriority(lhs.kind) < kindPriority(rhs.kind)
            }
            return lhs.url.path < rhs.url.path
        }
    }

    /// Keys fetched in one `getattrlist` per directory and reused by `makeItem`.
    static let itemKeys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .linkCountKey,
        .ubiquitousItemDownloadingStatusKey
    ]

    public static func makeItem(at url: URL, fileManager: FileManager = .default) -> TrashItem? {
        let values = try? url.resourceValues(forKeys: itemKeys)

        let isLink = values?.isSymbolicLink == true
        let isDirectory = values?.isDirectory == true && !isLink
        let kind: TrashItemKind
        if isLink {
            kind = .symlink
        } else if isDirectory {
            kind = .directory
        } else if values?.isRegularFile == true {
            kind = .file
        } else {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
            kind = isDir.boolValue ? .directory : .file
        }

        let size = kind == .file ? Int64(values?.fileSize ?? 0) : 0
        let links = values?.linkCount.map { UInt($0) } ?? 1
        let dataless = values?.ubiquitousItemDownloadingStatus == .notDownloaded

        return TrashItem(
            url: url,
            kind: kind,
            byteSize: size,
            linkCount: links,
            isDataless: dataless,
            depth: url.pathComponents.count
        )
    }

    private static func kindPriority(_ kind: TrashItemKind) -> Int {
        switch kind {
        case .file, .symlink: return 0
        case .directory: return 1
        }
    }

    private static func addVolumeTrashes(
        fileManager: FileManager,
        into roots: inout [URL],
        seen: inout Set<String>
    ) {
        let uid = getuid()
        let volumes = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        let names = (try? fileManager.contentsOfDirectory(at: volumes, includingPropertiesForKeys: nil)) ?? []
        for volume in names {
            let trash = volume
                .appendingPathComponent(".Trashes", isDirectory: true)
                .appendingPathComponent(String(uid), isDirectory: true)
            let path = PathGuard.normalize(trash)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            roots.append(URL(fileURLWithPath: path, isDirectory: true))
        }
    }
}
