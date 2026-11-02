import Darwin
import Foundation

/// Items handed to GoAway directly: dropped on its icon or sent from the
/// Services menu. They go to Trash the normal way, then only they are erased;
/// the rest of Trash is left alone.
public enum SelectedItems {
    public enum Refusal: Equatable, Sendable {
        case missing
        case volume
        case home
        case trash
        case goAway

        public var message: String {
            switch self {
            case .missing: return "No longer exists"
            case .volume: return "Is a whole disk"
            case .home: return "Holds your home folder"
            case .trash: return "Is Trash itself; open GoAway to erase all of Trash"
            case .goAway: return "Is GoAway itself"
            }
        }
    }

    public struct Prepared: Sendable {
        /// Everything to erase, already inside Trash, deepest first.
        public var items: [TrashItem]
        /// The Trash folders the items ended up in.
        public var roots: [URL]
        /// Items that could not be moved to Trash.
        public var failures: [WipeFailure]
    }

    public static func refusal(
        for url: URL,
        trashRoots: [URL],
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        app: URL? = Bundle.main.bundleURL
    ) -> Refusal? {
        let path = PathGuard.normalize(url)
        var info = stat()
        guard lstat(path, &info) == 0 else { return .missing }
        if path == "/" { return .volume }
        if (info.st_mode & S_IFMT) == S_IFDIR,
           (try? url.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true {
            return .volume
        }
        if encloses(path, PathGuard.normalize(home)) { return .home }
        if trashRoots.contains(where: { encloses(path, PathGuard.normalize($0)) }) { return .trash }
        if let app, encloses(path, PathGuard.normalize(app)) { return .goAway }
        return nil
    }

    /// Moves each item to Trash (unless it is already there) and collects what
    /// to erase. Items are refused again here so callers cannot skip the check.
    public static func prepare(
        _ urls: [URL],
        trashRoots: [URL],
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        app: URL? = Bundle.main.bundleURL,
        moveToTrash: (URL) throws -> URL,
        trashRoot: (URL) -> URL? = defaultTrashRoot
    ) -> Prepared {
        var failures: [WipeFailure] = []
        var placed: [URL] = []
        var roots = trashRoots

        for url in urls {
            if let refusal = refusal(for: url, trashRoots: trashRoots, home: home, app: app) {
                failures.append(WipeFailure(path: url.path, message: refusal.message, kind: .outsideTrash))
                continue
            }
            if PathGuard(roots: trashRoots).contains(PathGuard.normalize(url)) {
                placed.append(url)
                continue
            }
            do {
                let moved = try moveToTrash(url)
                placed.append(moved)
                if !PathGuard(roots: roots).contains(PathGuard.normalize(moved)), let root = trashRoot(moved) {
                    roots.append(root)
                }
            } catch {
                failures.append(WipeFailure(
                    path: url.path,
                    message: "Could not move to Trash: \(error.localizedDescription)",
                    kind: FailureKind.classify(error)
                ))
            }
        }

        let guardrail = PathGuard(roots: roots)
        var seen = Set<String>()
        let items = placed
            .flatMap { TrashEnumerator.collectSubtree(at: $0, guardrail: guardrail) }
            .filter { seen.insert(PathGuard.normalize($0.url)).inserted }
        let used = roots.filter { root in
            let one = PathGuard(roots: [root])
            return placed.contains { one.contains(PathGuard.normalize($0)) }
        }
        return Prepared(items: TrashEnumerator.sortedForErase(items), roots: used, failures: failures)
    }

    public static func defaultTrashRoot(for url: URL) -> URL? {
        try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: url, create: false)
    }

    /// `outer` is `inner` or one of its ancestors.
    static func encloses(_ outer: String, _ inner: String) -> Bool {
        inner == outer || inner.hasPrefix(outer.hasSuffix("/") ? outer : outer + "/")
    }
}
