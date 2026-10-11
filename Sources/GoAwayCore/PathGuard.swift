import Foundation

/// Allows erase work only on paths that stay inside the current user's Trash roots.
public struct PathGuard: Sendable, Equatable {
    public let roots: [String]

    public init(roots: [URL]) {
        self.roots = roots
            .map { Self.normalize($0) }
            .filter { !$0.isEmpty }
    }

    public static func normalize(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    public func contains(_ path: String) -> Bool {
        let candidate = (path as NSString).standardizingPath
        return roots.contains { root in
            if candidate == root { return true }
            let prefix = root.hasSuffix("/") ? root : root + "/"
            return candidate.hasPrefix(prefix)
        }
    }

    /// The link or file name itself lives in Trash. Used before unlinking a symlink.
    public func allowsUnlink(_ url: URL) -> Bool {
        contains(Self.normalize(url))
    }

    /// Both the given path and its fully resolved target stay in Trash.
    public func allowsOverwrite(_ url: URL) -> Bool {
        allowsUnlink(url) && contains(Self.normalize(url.resolvingSymlinksInPath()))
    }

    public func isRoot(_ url: URL) -> Bool {
        roots.contains(Self.normalize(url))
    }
}
