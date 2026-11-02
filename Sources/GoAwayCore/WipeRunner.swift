import Darwin
import Foundation

public enum WipeRunner {
    public static let maxWorkers = 4
    /// Minimum interval between progress callbacks while bytes are flowing.
    public static let progressInterval: TimeInterval = 1.0 / 30

    public static func plannedBytes(
        items: [TrashItem],
        request: WipeRequest
    ) -> Int64 {
        let volumes = items.map { request.probe.classify($0.url) }
        return plannedBytes(items: items, volumes: volumes, request: request)
    }

    static func plannedBytes(
        items: [TrashItem],
        volumes: [VolumeClass],
        request: WipeRequest
    ) -> Int64 {
        var total: Int64 = 0
        for (index, item) in items.enumerated() {
            guard item.kind == .file, item.linkCount <= 1, !item.isDataless else { continue }
            let volume = volumes[index]
            if volume.isNetwork { continue }
            let passes = WipeLevel.effectivePasses(
                level: request.level,
                isSSD: volume.isSolidState,
                respectSSD: request.respectSSD
            )
            total += item.byteSize * Int64(passes.count)
        }
        return total
    }

    public static func run(
        _ request: WipeRequest,
        cancel: CancelFlag,
        progress: @escaping @Sendable (WipeProgress) -> Void
    ) -> WipeResult {
        let items = TrashEnumerator.collect(roots: request.roots)
        return run(items: items, request: request, cancel: cancel, progress: progress)
    }

    /// Erases already-enumerated items. Files and symlinks run first, in
    /// parallel on solid-state volumes; directories follow, deepest first.
    public static func run(
        items unsorted: [TrashItem],
        request: WipeRequest,
        cancel: CancelFlag,
        progress: @escaping @Sendable (WipeProgress) -> Void
    ) -> WipeResult {
        let guardrail = PathGuard(roots: request.roots)
        let items = TrashEnumerator.sortedForErase(unsorted)
        if items.isEmpty {
            progress(WipeProgress(phaseLabel: "Nothing to erase", itemsTotal: 0))
            return WipeResult(outcome: .empty, erasedCount: 0, remainingCount: 0, failures: [])
        }

        // Classify each root once; map items to their root's volume.
        let rootPaths = request.roots.map { PathGuard.normalize($0) }
        let rootVolumes = request.roots.map { request.probe.classify($0) }
        let volumeIndex: [Int] = items.map { item in
            let path = PathGuard.normalize(item.url)
            for (index, root) in rootPaths.enumerated() {
                let prefix = root.hasSuffix("/") ? root : root + "/"
                if path == root || path.hasPrefix(prefix) { return index }
            }
            return -1
        }
        let fallback = SystemVolumeProbe()
        func volume(for index: Int) -> VolumeClass {
            let rootIndex = volumeIndex[index]
            if rootIndex >= 0 { return rootVolumes[rootIndex] }
            return fallback.classify(items[index].url)
        }
        let volumes = items.indices.map { volume(for: $0) }

        // Leaves (files, symlinks) first, directories after; both already deepest-first.
        let leafIndices = items.indices.filter { items[$0].kind != .directory }
        let directoryIndices = items.indices.filter { items[$0].kind == .directory }

        let state = RunState(
            progress: progress,
            snapshot: WipeProgress(
                phaseLabel: "Erasing",
                itemsTotal: items.count,
                bytesTotal: plannedBytes(items: items, volumes: volumes, request: request),
                passLabel: passLabel(for: leafIndices.map { volumes[$0] }, request: request)
            )
        )
        state.emit(force: true)

        let shouldStop: @Sendable () -> Bool = { cancel.isCancelled }

        /// Erases one item; false when cancellation stopped it part-way, in
        /// which case it stays in Trash and counts as remaining.
        @Sendable func process(_ index: Int, buffer: AlignedBuffer?) -> Bool {
            let item = items[index]
            state.itemStarted(name: item.url.lastPathComponent)
            do {
                try erase(
                    item,
                    volume: volumes[index],
                    request: request,
                    guardrail: guardrail,
                    buffer: buffer,
                    shouldStop: shouldStop
                ) { delta in
                    state.addBytes(delta)
                }
                state.itemFinished(failure: nil)
            } catch SecureEraserError.cancelled {
                return false
            } catch {
                state.itemFinished(failure: WipeFailure(
                    path: item.url.path,
                    message: error.localizedDescription,
                    kind: FailureKind.classify(error)
                ))
            }
            return true
        }

        // One lane set per volume, so a hard drive's single worker runs
        // alongside an SSD's parallel ones instead of serializing everything.
        let lanes = workLanes(for: leafIndices, volumes: volumes)
        let laneGroup = DispatchGroup()
        for queue in lanes {
            DispatchQueue.global(qos: .userInitiated).async(group: laneGroup) {
                let buffer = AlignedBuffer(count: SecureEraser.chunkSize)
                while !cancel.isCancelled, let index = queue.next() {
                    if !process(index, buffer: buffer) { break }
                }
            }
        }
        laneGroup.wait()

        if !cancel.isCancelled {
            for index in directoryIndices {
                if cancel.isCancelled || !process(index, buffer: nil) { break }
            }
        }

        let (erased, failures) = state.counts()
        let distinctVolumes = distinct(rootVolumes)

        if cancel.isCancelled {
            state.emit(force: true)
            fullSync(volumes: distinctVolumes, roots: request.roots)
            let remaining = items.count - erased - failures.count
            return WipeResult(
                outcome: .cancelled,
                erasedCount: erased,
                remainingCount: max(0, remaining),
                failures: failures
            )
        }

        // Snapshots are listed before the scrub: blocks they hold are out of the
        // scrub's reach until the snapshot is deleted, which the report offers.
        let inspector = request.inspector
        var snapshots: [String: [String]] = [:]
        for volume in distinctVolumes where !volume.isNetwork {
            snapshots[volume.mountPoint] = inspector.localSnapshots(mountPoint: volume.mountPoint)
        }

        // FileVault / Time Machine probes overlap with the scrub.
        let inspection = InspectionBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            inspection.set(timeMachine: inspector.isTimeMachineConfigured(), fileVault: inspector.isFileVaultOn())
            group.leave()
        }

        let scrub = request.scrubFreeSpace
            ? scrubVolumes(distinctVolumes, request: request, rootVolumes: rootVolumes, cancel: cancel, state: state)
            : ScrubReport()

        fullSync(volumes: distinctVolumes, roots: request.roots)
        group.wait()
        let facts = inspection.get()

        let assurances = distinctVolumes.map { volume in
            VolumeAssurance(
                volume: volume,
                inPlaceOverwrite: volume.inPlaceOverwrite,
                freeSpaceScrubbed: scrub.scrubbed[volume.mountPoint] != nil,
                scrubbedBytes: scrub.scrubbed[volume.mountPoint] ?? 0,
                localSnapshots: snapshots[volume.mountPoint] ?? [],
                timeMachineConfigured: facts.timeMachine,
                fileVaultOn: facts.fileVault
            )
        }

        state.emit(force: true)
        return WipeResult(
            outcome: scrub.cancelled ? .cancelled : .completed,
            erasedCount: erased,
            remainingCount: 0,
            failures: failures + scrub.failures,
            assurances: assurances
        )
    }

    public struct ScrubReport: Sendable, Equatable {
        /// Bytes written, by mount point, for every volume that finished.
        public var scrubbed: [String: Int64] = [:]
        public var failures: [WipeFailure] = []
        public var cancelled = false

        public init() {}
    }

    /// Scrubs free space without erasing anything, e.g. after local snapshots
    /// were deleted and released blocks that still hold Trash data.
    /// `mountPoints` limits the run to those volumes; nil means every root's volume.
    public static func scrubOnly(
        _ request: WipeRequest,
        mountPoints: Set<String>? = nil,
        cancel: CancelFlag,
        progress: @escaping @Sendable (WipeProgress) -> Void
    ) -> ScrubReport {
        let rootVolumes = request.roots.map { request.probe.classify($0) }
        let volumes = distinct(rootVolumes).filter { mountPoints?.contains($0.mountPoint) ?? true }
        let state = RunState(progress: progress, snapshot: WipeProgress(phaseLabel: "Scrubbing free space"))
        let report = scrubVolumes(volumes, request: request, rootVolumes: rootVolumes, cancel: cancel, state: state)
        fullSync(volumes: volumes, roots: request.roots)
        state.emit(force: true)
        return report
    }

    private static func scrubVolumes(
        _ volumes: [VolumeClass],
        request: WipeRequest,
        rootVolumes: [VolumeClass],
        cancel: CancelFlag,
        state: RunState
    ) -> ScrubReport {
        var report = ScrubReport()
        for volume in volumes where !volume.isNetwork && !volume.isReadOnly {
            if cancel.isCancelled { report.cancelled = true; break }
            guard let rootIndex = rootVolumes.firstIndex(of: volume) else { continue }
            let root = request.roots[rootIndex]
            state.beginScrub(volumeName: volume.displayName)
            do {
                let headroom = request.scrubHeadroom ?? FreeSpaceScrubber.headroom(
                    for: volume,
                    capacity: VolumeSpace.capacity(at: root.path)
                )
                let outcome = try FreeSpaceScrubber.scrub(inside: root, headroom: headroom, cancel: cancel) { written, planned in
                    state.scrubProgress(written: written, planned: planned)
                }
                if outcome.cancelled {
                    report.cancelled = true
                    break
                }
                report.scrubbed[volume.mountPoint] = outcome.bytesWritten
            } catch {
                report.failures.append(WipeFailure(
                    path: root.path,
                    message: error.localizedDescription,
                    kind: .scrub
                ))
            }
        }
        return report
    }

    public static func passLabel(for volume: VolumeClass, request: WipeRequest) -> String {
        if volume.isNetwork {
            return "unlink only (network)"
        }
        if volume.isSolidState && request.respectSSD {
            return "1 pass (SSD)"
        }
        return request.level.title
    }

    /// The label shared by every volume being erased, or "mixed" when they differ.
    public static func passLabel(for volumes: [VolumeClass], request: WipeRequest) -> String {
        let labels = Set(volumes.map { passLabel(for: $0, request: request) })
        if labels.count > 1 { return "mixed passes" }
        return labels.first ?? passLabel(for: .unknown, request: request)
    }

    /// Workers per volume for the leaf phase, keyed by mount point: up to
    /// `maxWorkers` on local SSDs and one elsewhere (seeks on a hard drive make
    /// parallel writers slower, not faster).
    public static func laneCounts(for indices: [Int], volumes: [VolumeClass]) -> [String: Int] {
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        var sizes: [String: Int] = [:]
        var parallel: [String: Bool] = [:]
        for index in indices {
            let volume = volumes[index]
            sizes[volume.mountPoint, default: 0] += 1
            parallel[volume.mountPoint] = volume.isSolidState && !volume.isNetwork
        }
        return sizes.reduce(into: [:]) { counts, entry in
            counts[entry.key] = parallel[entry.key] == true ? min(maxWorkers, cores, entry.value) : 1
        }
    }

    /// One shared queue per volume, repeated once per lane.
    static func workLanes(for indices: [Int], volumes: [VolumeClass]) -> [WorkQueue] {
        let counts = laneCounts(for: indices, volumes: volumes)
        var order: [String] = []
        var grouped: [String: [Int]] = [:]
        for index in indices {
            let key = volumes[index].mountPoint
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(index)
        }
        return order.flatMap { key -> [WorkQueue] in
            let queue = WorkQueue(indices: grouped[key] ?? [])
            return Array(repeating: queue, count: counts[key] ?? 1)
        }
    }

    public static func erase(
        _ item: TrashItem,
        volume: VolumeClass,
        request: WipeRequest,
        guardrail: PathGuard,
        buffer: AlignedBuffer? = nil,
        shouldStop: (() -> Bool)? = nil,
        onBytes: ((Int) -> Void)? = nil
    ) throws {
        switch item.kind {
        case .symlink:
            guard guardrail.allowsUnlink(item.url) else {
                throw SecureEraserError.outsideTrash(item.url.path)
            }
            try SecureEraser.scrambleAndRemove(at: item.url, isDirectory: false, truncate: false) {
                unlockForRemoval($0, guardrail: guardrail)
            }
        case .directory:
            guard guardrail.allowsUnlink(item.url), !guardrail.isRoot(item.url) else {
                throw SecureEraserError.outsideTrash(item.url.path)
            }
            try SecureEraser.scrambleAndRemove(at: item.url, isDirectory: true, truncate: false) {
                unlockForRemoval($0, guardrail: guardrail)
            }
        case .file:
            try eraseFile(
                item,
                volume: volume,
                request: request,
                guardrail: guardrail,
                buffer: buffer,
                shouldStop: shouldStop,
                onBytes: onBytes
            )
        }
    }

    /// Compatibility wrapper that classifies the item's volume on demand.
    public static func erase(
        _ item: TrashItem,
        request: WipeRequest,
        guardrail: PathGuard,
        onBytes: ((Int) -> Void)? = nil
    ) throws {
        try erase(
            item,
            volume: request.probe.classify(item.url),
            request: request,
            guardrail: guardrail,
            onBytes: onBytes
        )
    }

    private static func eraseFile(
        _ item: TrashItem,
        volume: VolumeClass,
        request: WipeRequest,
        guardrail: PathGuard,
        buffer: AlignedBuffer?,
        shouldStop: (() -> Bool)?,
        onBytes: ((Int) -> Void)?
    ) throws {
        guard guardrail.allowsUnlink(item.url) else {
            throw SecureEraserError.outsideTrash(item.url.path)
        }

        // Dataless (iCloud) files would download if opened for writing, and
        // truncating a hard link would destroy the other links' data.
        if item.isDataless || item.linkCount > 1 || volume.isNetwork {
            try SecureEraser.scrambleAndRemove(at: item.url, isDirectory: false, truncate: false) {
                unlockForRemoval($0, guardrail: guardrail)
            }
            return
        }

        guard guardrail.allowsOverwrite(item.url) else {
            throw SecureEraserError.outsideTrash(item.url.path)
        }

        let path = item.url.path
        SecureEraser.clearFlags(at: path)

        let passes = WipeLevel.effectivePasses(
            level: request.level,
            isSSD: volume.isSolidState,
            respectSSD: request.respectSSD
        )
        do {
            try SecureEraser.overwriteContents(
                at: path, passes: passes, buffer: buffer, shouldStop: shouldStop, onBytes: onBytes
            )
        } catch {
            // Read-only files (Git objects, Go module caches) and "deny write" ACLs.
            guard FailureKind.classify(error) == .permission, SecureEraser.unlock(at: path) else { throw error }
            try SecureEraser.overwriteContents(
                at: path, passes: passes, buffer: buffer, shouldStop: shouldStop, onBytes: onBytes
            )
        }

        let resourceFork = SecureEraser.resourceForkPath(for: path)
        if FileManager.default.fileExists(atPath: resourceFork) {
            try? SecureEraser.overwriteContents(at: resourceFork, passes: passes, buffer: buffer)
        }

        try SecureEraser.scrambleAndRemove(at: item.url, isDirectory: false, truncate: true) {
            unlockForRemoval($0, guardrail: guardrail)
        }
    }

    /// Unlocks an item and, when it sits below a Trash root, its parent folder:
    /// removing an entry needs write access to the folder that holds it.
    private static func unlockForRemoval(_ url: URL, guardrail: PathGuard) -> Bool {
        guard guardrail.allowsUnlink(url) else { return false }
        var changed = SecureEraser.unlock(at: url.path)
        let parent = url.deletingLastPathComponent()
        if guardrail.allowsUnlink(parent), !guardrail.isRoot(parent) {
            changed = SecureEraser.unlock(at: parent.path) || changed
        }
        return changed
    }

    private static func distinct(_ volumes: [VolumeClass]) -> [VolumeClass] {
        var seen = Set<String>()
        return volumes.filter { seen.insert($0.mountPoint).inserted }
    }

    private static func fullSync(volumes: [VolumeClass], roots: [URL]) {
        var synced = Set<String>()
        for root in roots {
            let path = PathGuard.normalize(root)
            let volume = volumes.first { v in
                let prefix = v.mountPoint.hasSuffix("/") ? v.mountPoint : v.mountPoint + "/"
                return path == v.mountPoint || path.hasPrefix(prefix)
            }
            if let volume, volume.isNetwork { continue }
            let key = volume?.mountPoint ?? path
            guard synced.insert(key).inserted else { continue }
            SecureEraser.fullSync(volumeRoot: root)
        }
    }
}

// MARK: - Shared state

/// Hands out item indices to workers.
final class WorkQueue: @unchecked Sendable {
    private let lock = NSLock()
    private let indices: [Int]
    private var cursor = 0

    init(indices: [Int]) {
        self.indices = indices
    }

    func next() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard cursor < indices.count else { return nil }
        let value = indices[cursor]
        cursor += 1
        return value
    }
}

/// Progress, counters and rate estimation shared by all workers. Emits to the
/// caller at most every `progressInterval` unless forced.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private let progress: @Sendable (WipeProgress) -> Void
    private var snapshot: WipeProgress
    private var erased = 0
    private var failures: [WipeFailure] = []
    private var lastEmit: UInt64 = 0
    private var windowStart: UInt64
    private var windowBytes: Int64 = 0
    private var rate: Double = 0

    private static let rateWindowNanos: UInt64 = 250_000_000

    init(progress: @escaping @Sendable (WipeProgress) -> Void, snapshot: WipeProgress) {
        self.progress = progress
        self.snapshot = snapshot
        self.windowStart = RunState.now()
    }

    static func now() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    func itemStarted(name: String) {
        lock.lock()
        snapshot.currentName = name
        emitLocked(force: false)
        lock.unlock()
    }

    func addBytes(_ delta: Int) {
        lock.lock()
        snapshot.bytesDone += Int64(delta)
        windowBytes += Int64(delta)
        updateRateLocked()
        emitLocked(force: false)
        lock.unlock()
    }

    func itemFinished(failure: WipeFailure?) {
        lock.lock()
        if let failure {
            failures.append(failure)
        } else {
            erased += 1
        }
        snapshot.itemsDone = erased + failures.count
        emitLocked(force: false)
        lock.unlock()
    }

    func counts() -> (Int, [WipeFailure]) {
        lock.lock()
        defer { lock.unlock() }
        return (erased, failures)
    }

    func beginScrub(volumeName: String) {
        lock.lock()
        snapshot.phaseLabel = "Scrubbing free space on \(volumeName)"
        snapshot.currentName = volumeName
        snapshot.isScrubbing = true
        snapshot.bytesDone = 0
        snapshot.bytesTotal = 0
        windowBytes = 0
        windowStart = RunState.now()
        rate = 0
        snapshot.bytesPerSecond = 0
        emitLocked(force: true)
        lock.unlock()
    }

    func scrubProgress(written: Int64, planned: Int64) {
        lock.lock()
        let delta = written - snapshot.bytesDone
        snapshot.bytesDone = written
        snapshot.bytesTotal = planned
        if delta > 0 { windowBytes += delta }
        updateRateLocked()
        emitLocked(force: false)
        lock.unlock()
    }

    func emit(force: Bool) {
        lock.lock()
        emitLocked(force: force)
        lock.unlock()
    }

    private func updateRateLocked() {
        let now = RunState.now()
        let elapsed = now &- windowStart
        guard elapsed >= RunState.rateWindowNanos else { return }
        let instant = Double(windowBytes) / (Double(elapsed) / 1_000_000_000)
        rate = rate == 0 ? instant : (0.4 * instant + 0.6 * rate)
        snapshot.bytesPerSecond = rate
        windowStart = now
        windowBytes = 0
    }

    private func emitLocked(force: Bool) {
        let now = RunState.now()
        let interval = UInt64(WipeRunner.progressInterval * 1_000_000_000)
        if !force && now &- lastEmit < interval { return }
        lastEmit = now
        progress(snapshot)
    }
}

private final class InspectionBox: @unchecked Sendable {
    struct Facts {
        var timeMachine = false
        var fileVault: Bool?
    }

    private let lock = NSLock()
    private var facts = Facts()

    func set(timeMachine: Bool, fileVault: Bool?) {
        lock.lock()
        facts = Facts(timeMachine: timeMachine, fileVault: fileVault)
        lock.unlock()
    }

    func get() -> Facts {
        lock.lock()
        defer { lock.unlock() }
        return facts
    }
}
