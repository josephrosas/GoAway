import Darwin
import Foundation

public enum SecureEraserError: Error, LocalizedError {
    case openFailed(String)
    case writeFailed(String)
    case outsideTrash(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .openFailed(let path): return "Could not open \(path)"
        case .writeFailed(let path): return "Could not overwrite \(path)"
        case .outsideTrash(let path): return "Refused to touch \(path)"
        case .cancelled: return "Cancelled"
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

    public static func clearFlags(at path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        let locked = UInt32(UF_IMMUTABLE) | UInt32(UF_APPEND) | UInt32(SF_IMMUTABLE) | UInt32(SF_APPEND)
        if info.st_flags & locked != 0 {
            _ = chflags(path, 0)
        }
        try? FileManager.default.setAttributes(
            [.immutable: false, .appendOnly: false],
            ofItemAtPath: path
        )
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
        guard fd >= 0 else { throw SecureEraserError.openFailed(path) }
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
                throw SecureEraserError.writeFailed(path)
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
                if errno == EINTR { continue }
                throw SecureEraserError.writeFailed(path)
            }
            if written == 0 { throw SecureEraserError.writeFailed(path) }
            offset += written
        }
    }

    public static func scrambleTruncateUnlink(at url: URL) throws -> URL {
        let directory = url.deletingLastPathComponent()
        let scrambled = directory.appendingPathComponent(randomName())
        do {
            try FileManager.default.moveItem(at: url, to: scrambled)
        } catch {
            try truncateAndUnlink(url)
            return url
        }
        try truncateAndUnlink(scrambled)
        return scrambled
    }

    public static func unlink(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
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

    private static func truncateAndUnlink(_ url: URL) throws {
        let path = url.path
        let fd = open(path, O_WRONLY | O_NOFOLLOW)
        if fd >= 0 {
            _ = ftruncate(fd, 0)
            _ = fsync(fd)
            close(fd)
        }
        removeExtendedAttributes(at: path)
        try FileManager.default.removeItem(at: url)
    }

    static func randomName() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        bytes.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress {
                arc4random_buf(base, raw.count)
            }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
