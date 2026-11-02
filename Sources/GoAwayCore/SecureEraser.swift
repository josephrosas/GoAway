import Darwin
import Foundation

public enum SecureEraserError: Error, LocalizedError {
    /// The errno is captured at the failing call; the global one is stale by the time anyone reads it.
    case openFailed(String, errno: Int32)
    case writeFailed(String, errno: Int32)
    case removeFailed(String, errno: Int32)
    case outsideTrash(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .openFailed(let path, let code): return "Could not open \(path): \(String(cString: strerror(code)))"
        case .writeFailed(let path, let code): return "Could not overwrite \(path): \(String(cString: strerror(code)))"
        case .removeFailed(let path, let code): return "Could not remove \(path): \(String(cString: strerror(code)))"
        case .outsideTrash(let path): return "Refused to touch \(path)"
        case .cancelled: return "Cancelled"
        }
    }

    public var code: Int32? {
        switch self {
        case .openFailed(_, let code), .writeFailed(_, let code), .removeFailed(_, let code): return code
        case .outsideTrash, .cancelled: return nil
        }
    }
}

/// Page-aligned scratch buffer. Aligned memory keeps `F_NOCACHE` writes on the
/// fast path and lets the kernel DMA straight from user space.
public final class AlignedBuffer: @unchecked Sendable {
    public let pointer: UnsafeMutableRawPointer
    public let count: Int

    public init(count: Int) {
        var raw: UnsafeMutableRawPointer?
        let alignment = max(Int(getpagesize()), 4096)
        let result = posix_memalign(&raw, alignment, count)
        guard result == 0, let raw else {
            fatalError("posix_memalign failed with \(result)")
        }
        self.pointer = raw
        self.count = count
    }

    deinit {
        free(pointer)
    }
}

public enum SecureEraser {
    /// 4 MB per write call. Large enough that syscall overhead is negligible,
    /// small enough that progress stays responsive.
    public static let chunkSize = 4 * 1024 * 1024
    /// Files at or above this size bypass the unified buffer cache.
    public static let noCacheThreshold: Int64 = 16 * 1024 * 1024

    /// Clears the owner-settable locked and append-only flags. The system
    /// variants need root and are left for the error path to report.
    public static func clearFlags(at path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        let userLocks = UInt32(UF_IMMUTABLE) | UInt32(UF_APPEND)
        if info.st_flags & userLocks != 0 {
            _ = lchflags(path, info.st_flags & ~userLocks)
        }
    }

    /// Makes an item the user owns erasable: owner write on files, owner
    /// read/write/search on folders, user lock flags off, and every ACL entry
    /// (such as "deny delete") dropped. Never follows symlinks and never
    /// touches items owned by someone else. Returns true when anything changed.
    @discardableResult
    public static func unlock(at path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid() else { return false }
        let type = info.st_mode & S_IFMT
        guard type == S_IFREG || type == S_IFDIR else { return false }

        var changed = false
        let userLocks = UInt32(UF_IMMUTABLE) | UInt32(UF_APPEND)
        if info.st_flags & userLocks != 0, lchflags(path, info.st_flags & ~userLocks) == 0 {
            changed = true
        }
        let wanted: mode_t = type == S_IFDIR ? S_IRWXU : S_IWUSR
        if info.st_mode & wanted != wanted, lchmod(path, (info.st_mode & 0o7777) | wanted) == 0 {
            changed = true
        }
        if clearACL(at: path) {
            changed = true
        }
        return changed
    }

    private static func clearACL(at path: String) -> Bool {
        guard let existing = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return false }
        acl_free(UnsafeMutableRawPointer(existing))
        guard let empty = acl_init(0) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        return acl_set_link_np(path, ACL_TYPE_EXTENDED, empty) == 0
    }

    /// Overwrites the file's logical extent once per pass. Large files bypass
    /// the unified buffer cache (`F_NOCACHE`) so gigabytes of garbage do not
    /// evict the user's working set. Each pass ends with `fsync` for ordering;
    /// the device-wide `F_FULLFSYNC` is issued once per volume by the caller.
    public static func overwriteContents(
        at path: String,
        passes: [WipePass],
        buffer: AlignedBuffer? = nil,
        shouldStop: (() -> Bool)? = nil,
        onBytes: ((Int) -> Void)? = nil
    ) throws {
        let fd = open(path, O_WRONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw SecureEraserError.openFailed(path, errno: errno) }
        defer { close(fd) }

        var size = lseek(fd, 0, SEEK_END)
        if size < 0 { size = 0 }
        if size == 0 {
            onBytes?(0)
            return
        }

        // Uncached writes cost ~10% raw throughput but keep large files from
        // evicting the user's working set. Small files ride the cache.
        if size >= noCacheThreshold {
            _ = fcntl(fd, F_NOCACHE, 1)
        }

        let scratch = buffer ?? AlignedBuffer(count: chunkSize)

        for pass in passes {
            if shouldStop?() == true { throw SecureEraserError.cancelled }
            if lseek(fd, 0, SEEK_SET) < 0 {
                throw SecureEraserError.writeFailed(path, errno: errno)
            }

            // Pattern passes fill the buffer once. Only random data is regenerated per chunk.
            let usable = prepare(scratch, for: pass)
            var remaining = size
            while remaining > 0 {
                let count = Int(min(Int64(usable), remaining))
                if case .random = pass {
                    arc4random_buf(scratch.pointer, count)
                }
                try writeFully(fd: fd, base: scratch.pointer, count: count, path: path)
                remaining -= Int64(count)
                onBytes?(count)
                if remaining > 0, shouldStop?() == true {
                    throw SecureEraserError.cancelled
                }
            }
            _ = fsync(fd)
        }
    }

    /// Fills `buffer` for a pattern pass and returns how many bytes are usable
    /// (a multiple of the pattern length so chunk boundaries never split it).
    static func prepare(_ buffer: AlignedBuffer, for pass: WipePass) -> Int {
        switch pass {
        case .random:
            return buffer.count
        case .constant(let value):
            memset(buffer.pointer, Int32(value), buffer.count)
            return buffer.count
        case .repeating(let pattern):
            guard !pattern.isEmpty else {
                memset(buffer.pointer, 0, buffer.count)
                return buffer.count
            }
            let usable = max(pattern.count, buffer.count - buffer.count % pattern.count)
            let bytes = buffer.pointer.assumingMemoryBound(to: UInt8.self)
            // Seed one period, then double it with memcpy.
            for i in 0..<pattern.count { bytes[i] = pattern[i] }
            var filled = pattern.count
            while filled < usable {
                let copy = min(filled, usable - filled)
                memcpy(buffer.pointer + filled, buffer.pointer, copy)
                filled += copy
            }
            return usable
        }
    }

    static func writeFully(fd: Int32, base: UnsafeRawPointer, count: Int, path: String) throws {
        var offset = 0
        while offset < count {
            let written = write(fd, base + offset, count - offset)
            if written < 0 {
                let code = errno
                if code == EINTR { continue }
                throw SecureEraserError.writeFailed(path, errno: code)
            }
            if written == 0 { throw SecureEraserError.writeFailed(path, errno: EIO) }
            offset += written
        }
    }

    /// Renames to a random name, optionally truncates, strips extended
    /// attributes, then removes the single entry: `unlink` for files and
    /// symlinks, `rmdir` for folders. Never recursive, so anything left inside
    /// a folder surfaces as a failure instead of being dropped unerased.
    ///
    /// When a step is refused (EACCES/EPERM), `onDenied` gets the current URL
    /// and one chance to fix permissions; the step is retried if it returns
    /// true. If removal still fails, the original name is restored so the
    /// failure points at a path that exists.
    public static func scrambleAndRemove(
        at url: URL,
        isDirectory: Bool,
        truncate: Bool,
        onDenied: (URL) -> Bool = { _ in false }
    ) throws {
        let scrambled = url.deletingLastPathComponent().appendingPathComponent(randomName())
        var current = url
        if attempt(on: url, onDenied: onDenied, { Darwin.rename(url.path, scrambled.path) }) == 0 {
            current = scrambled
        }

        let path = current.path
        if truncate && !isDirectory {
            let fd = open(path, O_WRONLY | O_NOFOLLOW)
            if fd >= 0 {
                _ = ftruncate(fd, 0)
                close(fd)
            }
        }
        removeExtendedAttributes(at: path)

        let code = attempt(on: current, onDenied: onDenied) {
            isDirectory ? Darwin.rmdir(path) : Darwin.unlink(path)
        }
        if code != 0 {
            if current != url {
                _ = Darwin.rename(path, url.path)
            }
            throw SecureEraserError.removeFailed(url.path, errno: code)
        }
    }

    /// Runs a POSIX call that returns 0 on success. On EACCES/EPERM, retries
    /// once if `onDenied` changed something. Returns 0 or the final errno.
    private static func attempt(on url: URL, onDenied: (URL) -> Bool, _ call: () -> Int32) -> Int32 {
        if call() == 0 { return 0 }
        let code = errno
        guard code == EACCES || code == EPERM, onDenied(url) else { return code }
        return call() == 0 ? 0 : errno
    }

    public static func removeExtendedAttributes(at path: String) {
        let length = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard length > 0 else { return }
        var names = [CChar](repeating: 0, count: length)
        let listed = listxattr(path, &names, names.count, XATTR_NOFOLLOW)
        guard listed > 0 else { return }

        names.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var index = 0
            while index < listed {
                let name = String(cString: base + index)
                if !name.isEmpty {
                    _ = removexattr(path, name, XATTR_NOFOLLOW)
                }
                index += name.utf8.count + 1
            }
        }
    }

    public static func resourceForkPath(for path: String) -> String {
        path + "/..namedfork/rsrc"
    }

    /// Device-wide flush. `F_FULLFSYNC` asks the drive to commit its cache to
    /// permanent storage; one call covers everything written to that device.
    @discardableResult
    public static func fullSync(volumeRoot: URL) -> Bool {
        let fd = open(volumeRoot.path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return fcntl(fd, F_FULLFSYNC) == 0
    }

    public static func randomName() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        bytes.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress {
                arc4random_buf(base, raw.count)
            }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
