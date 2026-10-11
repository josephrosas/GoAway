import Darwin
import DiskArbitration
import Foundation

/// Everything the wipe engine needs to know about the volume a path lives on.
/// Resolved once per mount point, never per file.
public struct VolumeClass: Sendable, Equatable, Hashable {
    public var mountPoint: String
    public var name: String
    /// `statfs.f_fstypename`: "apfs", "hfs", "exfat", "msdos", "smbfs", ...
    public var filesystem: String
    public var isSolidState: Bool
    public var isNetwork: Bool
    public var isEncrypted: Bool
    public var isReadOnly: Bool

    public init(
        mountPoint: String,
        name: String = "",
        filesystem: String,
        isSolidState: Bool,
        isNetwork: Bool,
        isEncrypted: Bool = false,
        isReadOnly: Bool = false
    ) {
        self.mountPoint = mountPoint
        self.name = name
        self.filesystem = filesystem
        self.isSolidState = isSolidState
        self.isNetwork = isNetwork
        self.isEncrypted = isEncrypted
        self.isReadOnly = isReadOnly
    }

    /// APFS is copy-on-write: overwriting a file allocates fresh blocks and frees
    /// the old ones, so in-place overwrite is only real on other local filesystems.
    public var inPlaceOverwrite: Bool {
        !isNetwork && filesystem.lowercased() != "apfs"
    }

    public var displayName: String {
        if !name.isEmpty { return name }
        if mountPoint == "/" { return "Startup Disk" }
        return (mountPoint as NSString).lastPathComponent
    }

    public static let unknown = VolumeClass(
        mountPoint: "",
        filesystem: "",
        isSolidState: true,
        isNetwork: false
    )
}

public protocol VolumeClassifying: Sendable {
    func classify(_ url: URL) -> VolumeClass
}

public extension VolumeClassifying {
    func isSolidState(at url: URL) -> Bool { classify(url).isSolidState }
    func isNetwork(at url: URL) -> Bool { classify(url).isNetwork }
}

/// Test double: every path gets the same answer.
public struct FixedVolumeProbe: VolumeClassifying {
    public var solidState: Bool
    public var network: Bool
    public var filesystem: String
    public var mountPoint: String
    public var encrypted: Bool

    public init(
        solidState: Bool,
        network: Bool = false,
        filesystem: String = "apfs",
        mountPoint: String = "/",
        encrypted: Bool = false
    ) {
        self.solidState = solidState
        self.network = network
        self.filesystem = filesystem
        self.mountPoint = mountPoint
        self.encrypted = encrypted
    }

    public func classify(_ url: URL) -> VolumeClass {
        VolumeClass(
            mountPoint: mountPoint,
            name: "Test Volume",
            filesystem: filesystem,
            isSolidState: solidState,
            isNetwork: network,
            isEncrypted: encrypted
        )
    }
}

/// Real probe. `statfs` for the mount point and filesystem, DiskArbitration for
/// media facts. Results are cached by mount point because DiskArbitration lookups
/// cost milliseconds each and a Trash can hold hundreds of thousands of files.
public final class SystemVolumeProbe: VolumeClassifying, @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: VolumeClass] = [:]
    private var session: DASession?

    public init() {}

    public func classify(_ url: URL) -> VolumeClass {
        guard let fs = fileSystemStats(for: url.path) else { return .unknown }
        let mountPoint = string(from: fs.f_mntonname)

        lock.lock()
        if let cached = cache[mountPoint] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = resolve(fs: fs, mountPoint: mountPoint)

        lock.lock()
        cache[mountPoint] = resolved
        lock.unlock()
        return resolved
    }

    public func isEncrypted(at url: URL) -> Bool {
        classify(url).isEncrypted
    }

    private func resolve(fs: statfs, mountPoint: String) -> VolumeClass {
        let filesystem = string(from: fs.f_fstypename)
        let flags = UInt32(truncatingIfNeeded: fs.f_flags)
        let isLocal = flags & UInt32(MNT_LOCAL) != 0
        let isReadOnly = flags & UInt32(MNT_RDONLY) != 0

        var device = string(from: fs.f_mntfromname)
        if device.hasPrefix("/dev/") { device.removeFirst(5) }

        var solidState = true
        var encrypted = false
        var name = ""
        if isLocal, !device.isEmpty, let description = diskDescription(bsdName: device) {
            if let ssd = description["DAMediaSolidState"] as? Bool {
                solidState = ssd
            }
            if let enc = description["DAVolumeEncrypted"] as? Bool {
                encrypted = enc
            }
            if let volumeName = description[kDADiskDescriptionVolumeNameKey as String] as? String {
                name = volumeName
            }
        }
        // The user's data lives on the APFS "Data" volume; show it under the
        // startup disk's name, which is what Finder calls it.
        if mountPoint == "/System/Volumes/Data" || name.isEmpty {
            let lookup = mountPoint == "/System/Volumes/Data" ? "/" : mountPoint
            let values = try? URL(fileURLWithPath: lookup, isDirectory: true)
                .resourceValues(forKeys: [.volumeLocalizedNameKey])
            if let localized = values?.volumeLocalizedName, !localized.isEmpty {
                name = localized
            }
        }

        return VolumeClass(
            mountPoint: mountPoint,
            name: name,
            filesystem: filesystem,
            isSolidState: solidState,
            isNetwork: !isLocal,
            isEncrypted: encrypted,
            isReadOnly: isReadOnly
        )
    }

    private func diskDescription(bsdName: String) -> [AnyHashable: Any]? {
        lock.lock()
        if session == nil {
            session = DASessionCreate(kCFAllocatorDefault)
        }
        let active = session
        lock.unlock()

        guard let active else { return nil }
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, active, bsdName) else { return nil }
        guard let copy = DADiskCopyDescription(disk) else { return nil }
        return copy as NSDictionary as? [AnyHashable: Any]
    }

    private func fileSystemStats(for path: String) -> statfs? {
        var fs = statfs()
        let ok = path.withCString { statfs($0, &fs) == 0 }
        return ok ? fs : nil
    }

    private func string<T>(from tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw -> String in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
            return String(cString: base)
        }
    }
}

public enum VolumeSpace {
    /// Bytes available to this user on the volume holding `path`.
    public static func available(at path: String) -> Int64 {
        var fs = statfs()
        guard path.withCString({ statfs($0, &fs) == 0 }) else { return 0 }
        return Int64(fs.f_bavail) * Int64(fs.f_bsize)
    }
}
