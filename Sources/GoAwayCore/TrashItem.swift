import Foundation

public enum TrashItemKind: Sendable, Equatable {
    case file
    case directory
    case symlink
}

public struct TrashItem: Sendable, Equatable {
    public var url: URL
    public var kind: TrashItemKind
    /// Logical size. This is what an overwrite actually writes, so progress and
    /// planning stay in step on sparse or compressed files.
    public var byteSize: Int64
    public var linkCount: UInt
    public var isDataless: Bool
    /// Number of path components, precomputed so sorting never allocates.
    public var depth: Int

    public init(
        url: URL,
        kind: TrashItemKind,
        byteSize: Int64,
        linkCount: UInt,
        isDataless: Bool,
        depth: Int? = nil
    ) {
        self.url = url
        self.kind = kind
        self.byteSize = byteSize
        self.linkCount = linkCount
        self.isDataless = isDataless
        self.depth = depth ?? url.pathComponents.count
    }
}

public enum FailureKind: Sendable, Equatable {
    case permission
    case busy
    case outsideTrash
    case scrub
    case other

    public var reason: String {
        switch self {
        case .permission: return "No permission"
        case .busy: return "In use by another app"
        case .outsideTrash: return "Refused: outside Trash"
        case .scrub: return "Free-space scrub failed"
        case .other: return "Could not erase"
        }
    }

    public static func classify(_ error: Error) -> FailureKind {
        if let eraser = error as? SecureEraserError {
            switch eraser {
            case .outsideTrash: return .outsideTrash
            case .openFailed, .writeFailed:
                return classifyErrno(errno)
            case .cancelled: return .other
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return classifyErrno(Int32(nsError.code))
        }
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return .permission
            case NSFileLockingError: return .busy
            default: break
            }
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
               underlying.domain == NSPOSIXErrorDomain {
                return classifyErrno(Int32(underlying.code))
            }
        }
        return .other
    }

    private static func classifyErrno(_ code: Int32) -> FailureKind {
        switch code {
        case EACCES, EPERM, EROFS: return .permission
        case EBUSY, ETXTBSY: return .busy
        default: return .other
        }
    }
}

public struct WipeFailure: Sendable, Equatable, Identifiable {
    public var path: String
    public var message: String
    public var kind: FailureKind

    public var id: String { path }

    public init(path: String, message: String, kind: FailureKind = .other) {
        self.path = path
        self.message = message
        self.kind = kind
    }
}

public struct WipeProgress: Sendable, Equatable {
    public var phaseLabel: String
    public var currentName: String
    public var itemsDone: Int
    public var itemsTotal: Int
    public var bytesDone: Int64
    public var bytesTotal: Int64
    /// Smoothed write rate over the last couple of seconds. Zero until known.
    public var bytesPerSecond: Double
    /// Human label for what is actually being done, e.g. "1 pass (SSD)" or "DoD 7x".
    public var passLabel: String
    public var isScrubbing: Bool

    public init(
        phaseLabel: String = "Erasing",
        currentName: String = "",
        itemsDone: Int = 0,
        itemsTotal: Int = 0,
        bytesDone: Int64 = 0,
        bytesTotal: Int64 = 0,
        bytesPerSecond: Double = 0,
        passLabel: String = "",
        isScrubbing: Bool = false
    ) {
        self.phaseLabel = phaseLabel
        self.currentName = currentName
        self.itemsDone = itemsDone
        self.itemsTotal = itemsTotal
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.bytesPerSecond = bytesPerSecond
        self.passLabel = passLabel
        self.isScrubbing = isScrubbing
    }

    public var fraction: Double {
        if bytesTotal > 0 {
            return min(1, Double(bytesDone) / Double(bytesTotal))
        }
        if itemsTotal > 0 {
            return min(1, Double(itemsDone) / Double(itemsTotal))
        }
        return 0
    }

    public var bytesRemaining: Int64 {
        max(0, bytesTotal - bytesDone)
    }

    public var estimatedSecondsRemaining: Double? {
        guard bytesPerSecond > 1, bytesRemaining > 0 else { return nil }
        return Double(bytesRemaining) / bytesPerSecond
    }
}

public enum WipeOutcome: Sendable, Equatable {
    case empty
    case completed
    case cancelled
}

public struct WipeResult: Sendable, Equatable {
    public var outcome: WipeOutcome
    public var erasedCount: Int
    public var remainingCount: Int
    public var failures: [WipeFailure]
    public var assurances: [VolumeAssurance]

    public init(
        outcome: WipeOutcome,
        erasedCount: Int,
        remainingCount: Int,
        failures: [WipeFailure],
        assurances: [VolumeAssurance] = []
    ) {
        self.outcome = outcome
        self.erasedCount = erasedCount
        self.remainingCount = remainingCount
        self.failures = failures
        self.assurances = assurances
    }

    public var warnings: [AssuranceWarning] {
        assurances.flatMap(\.warnings)
    }
}

public struct WipeRequest: Sendable {
    public var roots: [URL]
    public var level: WipeLevel
    public var respectSSD: Bool
    /// Fill free space on each affected volume after unlinking. The only way to
    /// reach freed blocks on APFS from user space.
    public var scrubFreeSpace: Bool
    public var probe: any VolumeClassifying
    public var inspector: any AssuranceInspecting

    public init(
        roots: [URL],
        level: WipeLevel,
        respectSSD: Bool,
        scrubFreeSpace: Bool = false,
        probe: any VolumeClassifying = SystemVolumeProbe(),
        inspector: any AssuranceInspecting = SystemAssuranceInspector()
    ) {
        self.roots = roots
        self.level = level
        self.respectSSD = respectSSD
        self.scrubFreeSpace = scrubFreeSpace
        self.probe = probe
        self.inspector = inspector
    }
}
