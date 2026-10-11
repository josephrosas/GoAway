import Darwin
import Foundation

/// Fills a volume's free space with random data so blocks freed by unlinking
/// (the only thing an overwrite achieves on copy-on-write APFS) get overwritten.
///
/// Everything is written inside the Trash root itself, so `PathGuard` keeps
/// covering every path GoAway touches. A large file takes the bulk of free
/// space down to `headroom`; a bounded burst of 4 KB files then churns small
/// allocations and directory slack. All scrub files are removed on exit,
/// including on cancel or error.
public enum FreeSpaceScrubber {
    public static let defaultHeadroom: Int64 = 256 * 1024 * 1024
    public static let smallFileSize = 4096
    public static let smallFileLimit = 4096

    public struct Outcome: Sendable, Equatable {
        public var bytesWritten: Int64
        public var smallFiles: Int
        public var cancelled: Bool
        public var reachedEnd: Bool
    }

    public enum ScrubError: Error, LocalizedError {
        case rootMissing(String)
        case createFailed(String)
        case writeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .rootMissing(let path): return "Trash root missing: \(path)"
            case .createFailed(let path): return "Could not create scrub file in \(path)"
            case .writeFailed(let path): return "Could not write scrub data in \(path)"
            }
        }
    }

    /// `onProgress(bytesWritten, bytesPlanned)` is called on the calling thread.
    public static func scrub(
        inside root: URL,
        headroom: Int64 = defaultHeadroom,
        cancel: CancelFlag,
        onProgress: ((Int64, Int64) -> Void)? = nil
    ) throws -> Outcome {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ScrubError.rootMissing(root.path)
        }

        let scrubDir = root.appendingPathComponent(".goaway-scrub-\(SecureEraser.randomName())", isDirectory: true)
        try fm.createDirectory(at: scrubDir, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: scrubDir) }

        let planned = max(0, VolumeSpace.available(at: root.path) - headroom)
        onProgress?(0, planned)

        var outcome = Outcome(bytesWritten: 0, smallFiles: 0, cancelled: false, reachedEnd: false)
        let buffer = AlignedBuffer(count: SecureEraser.chunkSize)

        let bigFile = scrubDir.appendingPathComponent("fill.bin")
        let fd = open(bigFile.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ScrubError.createFailed(scrubDir.path) }
        _ = fcntl(fd, F_NOCACHE, 1)

        var hitEnd = false
        var checkCounter = 0
        do {
            defer { close(fd) }
            while outcome.bytesWritten < planned {
                if cancel.isCancelled {
                    outcome.cancelled = true
                    break
                }
                let count = Int(min(Int64(buffer.count), planned - outcome.bytesWritten))
                arc4random_buf(buffer.pointer, count)
                let written = write(fd, buffer.pointer, count)
                if written < 0 {
                    if errno == EINTR { continue }
                    if errno == ENOSPC || errno == EDQUOT {
                        hitEnd = true
                        break
                    }
                    throw ScrubError.writeFailed(scrubDir.path)
                }
                if written == 0 { break }
                outcome.bytesWritten += Int64(written)
                onProgress?(outcome.bytesWritten, planned)

                // Another process may be consuming space too; respect the headroom live.
                checkCounter += 1
                if checkCounter % 64 == 0, VolumeSpace.available(at: root.path) < headroom {
                    break
                }
            }
            _ = fsync(fd)
            _ = fcntl(fd, F_FULLFSYNC)
        }

        // Small-file burst: churn block-sized allocations and directory slack.
        if !outcome.cancelled {
            let small = AlignedBuffer(count: smallFileSize)
            for index in 0..<smallFileLimit {
                if cancel.isCancelled {
                    outcome.cancelled = true
                    break
                }
                if VolumeSpace.available(at: root.path) < headroom / 2 {
                    hitEnd = true
                    break
                }
                let path = scrubDir.appendingPathComponent("s\(index)").path
                let sfd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                guard sfd >= 0 else { break }
                arc4random_buf(small.pointer, smallFileSize)
                let written = write(sfd, small.pointer, smallFileSize)
                close(sfd)
                if written < 0 {
                    hitEnd = errno == ENOSPC || errno == EDQUOT
                    break
                }
                outcome.smallFiles += 1
            }
        }

        outcome.reachedEnd = hitEnd || outcome.bytesWritten >= planned
        try? fm.removeItem(at: scrubDir)
        return outcome
    }
}
