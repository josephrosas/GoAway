import AppKit
import Foundation
import GoAwayCore
import os

private let log = Logger(subsystem: "com.unga.GoAway", category: "app")

enum AppPhase: Equatable {
    case checking
    case needsPermission
    case scanning
    case wiping
    case scrubbing
    case empty
    case done
    case cancelled
    case failed
}

@Observable
@MainActor
final class AppModel {
    var phase: AppPhase = .checking
    var progress = WipeProgress()
    var result: WipeResult?
    /// Why the permission screen is showing, e.g. "~/.Trash: EPERM (Operation not permitted)".
    var permissionReason: String?
    var snapshotActionMessage: String?
    var isDeletingSnapshots = false
    var appearance: AppearancePreference {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: AppDefaults.appearance)
            NSApp.appearance = appearance.nsAppearance
        }
    }
    var wipeLevel: WipeLevel {
        didSet { UserDefaults.standard.set(wipeLevel.rawValue, forKey: AppDefaults.wipeLevel) }
    }
    var respectSSD: Bool {
        didSet { UserDefaults.standard.set(respectSSD, forKey: AppDefaults.respectSSD) }
    }
    var playSound: Bool {
        didSet { UserDefaults.standard.set(playSound, forKey: AppDefaults.playSound) }
    }
    var scrubFreeSpace: Bool {
        didSet { UserDefaults.standard.set(scrubFreeSpace, forKey: AppDefaults.scrubFreeSpace) }
    }
    var showAssuranceWarnings: Bool {
        didSet { UserDefaults.standard.set(showAssuranceWarnings, forKey: AppDefaults.showAssuranceWarnings) }
    }

    var versionText: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var canCancel: Bool { phase == .wiping || phase == .scanning || phase == .scrubbing }

    /// Warnings worth holding the window open for.
    var blockingWarnings: [AssuranceWarning] {
        guard showAssuranceWarnings, let result else { return [] }
        return result.warnings.filter { $0.blocksAutoQuit }
    }

    private var cancelFlag = CancelFlag()
    private var started = false
    private var quitTask: Task<Void, Never>?
    private let probe = SystemVolumeProbe()

    init() {
        let storedLevel = UserDefaults.standard.string(forKey: AppDefaults.wipeLevel) ?? ""
        wipeLevel = WipeLevel(rawValue: storedLevel) ?? .dod
        respectSSD = AppDefaults.bool(forKey: AppDefaults.respectSSD, default: true)
        playSound = AppDefaults.bool(forKey: AppDefaults.playSound, default: true)
        scrubFreeSpace = AppDefaults.bool(forKey: AppDefaults.scrubFreeSpace, default: false)
        showAssuranceWarnings = AppDefaults.bool(forKey: AppDefaults.showAssuranceWarnings, default: true)
        let storedAppearance = UserDefaults.standard.string(forKey: AppDefaults.appearance) ?? ""
        appearance = AppearancePreference(rawValue: storedAppearance) ?? .matchMac
    }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        NSApp.appearance = appearance.nsAppearance
        begin()
    }

    /// Full Disk Access only applies to processes started after it was granted,
    /// so the only way to pick up a new grant is a fresh launch.
    func relaunch() {
        let bundle = Bundle.main.bundleURL.path
        log.notice("Relaunching \(bundle, privacy: .public) to pick up Full Disk Access")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this instance to exit so the new one does not just activate it.
        let escaped = bundle.replacingOccurrences(of: "'", with: "'\\''")
        process.arguments = ["-c", "sleep 0.6; /usr/bin/open -n '\(escaped)'"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            log.error("Relaunch failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        NSApp.terminate(nil)
    }

    func cancel() {
        cancelFlag.cancel()
    }

    func openFullDiskAccess() {
        for url in FullDiskAccess.settingsURLs {
            if NSWorkspace.shared.open(url) { return }
        }
    }

    /// Shows the app bundle so it can be dragged into the Full Disk Access list.
    func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func openFileVaultSettings() {
        let urls = [
            URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?FileVault")!,
            URL(string: "x-apple.systempreferences:com.apple.preference.security?FileVault")!
        ]
        for url in urls {
            if NSWorkspace.shared.open(url) { return }
        }
    }

    func sendFeedback() {
        NSWorkspace.shared.open(AppIdentity.feedback)
    }

    func reveal(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Re-runs the engine on just the paths that failed last time.
    func retryFailed() {
        guard let result, !result.failures.isEmpty else { return }
        let paths = result.failures.filter { $0.kind != .scrub }.map(\.path)
        guard !paths.isEmpty else { return }
        quitTask?.cancel()
        snapshotActionMessage = nil

        let overrideRoot = ProcessInfo.processInfo.environment["GOAWAY_TRASH_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let request = makeRequest(roots: overrideRoot.map { [$0] } ?? TrashEnumerator.discover())
        let guardrail = PathGuard(roots: request.roots)
        let items = paths.compactMap { path -> TrashItem? in
            let url = URL(fileURLWithPath: path)
            guard guardrail.allowsUnlink(url) else { return nil }
            return TrashEnumerator.makeItem(at: url)
        }
        guard !items.isEmpty else {
            // Everything that failed is already gone.
            finish(WipeResult(outcome: .completed, erasedCount: result.erasedCount, remainingCount: 0,
                              failures: [], assurances: result.assurances), progress: nil)
            return
        }

        self.result = nil
        progress = WipeProgress(itemsTotal: items.count)
        phase = .wiping
        cancelFlag = CancelFlag()
        let flag = cancelFlag
        let sink = ProgressSink(model: self)
        let previousErased = result.erasedCount

        Task.detached(priority: .userInitiated) {
            var outcome = WipeRunner.run(items: items, request: request, cancel: flag, progress: sink.apply)
            outcome.erasedCount += previousErased
            await sink.finish(outcome, progress: nil)
        }
    }

    func deleteSnapshots() {
        guard let result else { return }
        let dates = Array(Set(result.assurances.flatMap(\.localSnapshots))).sorted()
        guard !dates.isEmpty, !isDeletingSnapshots else { return }
        isDeletingSnapshots = true
        snapshotActionMessage = nil
        quitTask?.cancel()

        Task.detached(priority: .userInitiated) {
            let error: Error?
            do {
                try SnapshotDeleter.deleteLocalSnapshots(dates: dates)
                error = nil
            } catch let caught {
                error = caught
            }
            await MainActor.run { [weak self] in
                self?.snapshotsDeleted(error: error, dates: dates)
            }
        }
    }

    private func snapshotsDeleted(error: Error?, dates: [String]) {
        isDeletingSnapshots = false
        if let error {
            snapshotActionMessage = error.localizedDescription
            return
        }
        guard var updated = result else { return }
        updated.assurances = updated.assurances.map { assurance in
            var copy = assurance
            copy.localSnapshots.removeAll { dates.contains($0) }
            return copy
        }
        result = updated
        snapshotActionMessage = dates.count == 1 ? "Deleted 1 snapshot." : "Deleted \(dates.count) snapshots."
        if blockingWarnings.isEmpty, updated.failures.isEmpty {
            scheduleQuit()
        }
    }

    private func makeRequest(roots: [URL]) -> WipeRequest {
        WipeRequest(
            roots: roots,
            level: wipeLevel,
            respectSSD: respectSSD,
            scrubFreeSpace: scrubFreeSpace,
            probe: probe,
            inspector: SystemAssuranceInspector()
        )
    }

    private func begin() {
        quitTask?.cancel()
        result = nil
        snapshotActionMessage = nil
        progress = WipeProgress()
        DockProgress.shared.fraction = 0

        // Development hook: point the whole run at a fake Trash instead of the real one.
        let overrideRoot = ProcessInfo.processInfo.environment["GOAWAY_TRASH_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }

        if overrideRoot == nil {
            let status = FullDiskAccess.status()
            if !status.isGranted {
                showPermission(reason: status.reason)
                return
            }
        }

        permissionReason = nil
        phase = .scanning
        log.info("Scanning Trash")
        cancelFlag = CancelFlag()
        let flag = cancelFlag
        let sink = ProgressSink(model: self)
        let template = makeRequest(roots: [])

        Task.detached(priority: .userInitiated) {
            let roots = overrideRoot.map { [$0] } ?? TrashEnumerator.discover()
            let report = TrashEnumerator.collectReport(roots: roots)
            let items = report.items

            if items.isEmpty, overrideRoot == nil, report.hasPrivacyDenial {
                // The permission probe passed but Trash itself is still gated.
                let first = report.unreadable.first { $0.isPrivacyDenial }
                let reason = first.map { "\($0.url.path): \($0.message)" }
                await sink.needsPermission(reason: reason)
                return
            }

            if items.isEmpty {
                let failures = report.unreadable.map {
                    WipeFailure(path: $0.url.path, message: $0.message, kind: $0.isPrivacyDenial ? .permission : .other)
                }
                if failures.isEmpty {
                    await sink.finish(
                        WipeResult(outcome: .empty, erasedCount: 0, remainingCount: 0, failures: []),
                        progress: WipeProgress(phaseLabel: "Nothing to erase")
                    )
                } else {
                    // Could not look inside Trash; say so instead of "Nothing to erase".
                    await sink.finish(
                        WipeResult(outcome: .completed, erasedCount: 0, remainingCount: 0, failures: failures),
                        progress: nil
                    )
                }
                return
            }

            await sink.markWiping(itemCount: items.count)

            var request = template
            request.roots = roots
            let outcome = WipeRunner.run(items: items, request: request, cancel: flag, progress: sink.apply)
            await sink.finish(outcome, progress: nil)
        }
    }

    fileprivate func showPermission(reason: String?) {
        permissionReason = reason
        phase = .needsPermission
        log.notice("Showing permission screen: \(reason ?? "no reason", privacy: .public)")
    }

    fileprivate func markWiping(itemCount: Int) {
        phase = .wiping
        progress.itemsTotal = itemCount
        log.info("Erasing \(itemCount) item(s)")
    }

    fileprivate func apply(_ snapshot: WipeProgress) {
        progress = snapshot
        if snapshot.isScrubbing, phase == .wiping {
            phase = .scrubbing
        }
        DockProgress.shared.fraction = snapshot.fraction
    }

    fileprivate func finish(_ result: WipeResult, progress: WipeProgress?) {
        self.result = result
        if let progress {
            self.progress = progress
        }
        log.info("Finished: outcome=\(String(describing: result.outcome), privacy: .public) erased=\(result.erasedCount) failures=\(result.failures.count)")
        for failure in result.failures.prefix(20) {
            log.error("Failed \(failure.path, privacy: .public): \(failure.message, privacy: .public)")
        }
        switch result.outcome {
        case .empty:
            phase = .empty
            DockProgress.shared.fraction = 1
            scheduleQuit()
        case .completed:
            phase = result.failures.isEmpty ? .done : .failed
            DockProgress.shared.fraction = 1
            if playSound {
                NSSound(named: "Glass")?.play()
            }
            if result.erasedCount > 0 {
                QuickLookCache.reset()
            }
            if result.failures.isEmpty, blockingWarnings.isEmpty {
                scheduleQuit()
            }
        case .cancelled:
            phase = .cancelled
        }
    }

    private func scheduleQuit() {
        quitTask?.cancel()
        quitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            NSApp.terminate(nil)
        }
    }
}

/// Forwards engine progress to the main actor, coalescing bursts so only the
/// latest snapshot is delivered per main-thread turn.
private final class ProgressSink: @unchecked Sendable {
    @MainActor private weak var model: AppModel?
    private let lock = NSLock()
    private var pending: WipeProgress?
    private var scheduled = false

    init(model: AppModel) {
        self.model = model
    }

    func apply(_ snapshot: WipeProgress) {
        lock.lock()
        pending = snapshot
        let needsHop = !scheduled
        scheduled = true
        lock.unlock()
        guard needsHop else { return }

        Task { @MainActor [self] in
            if let latest = self.takePending() {
                self.model?.apply(latest)
            }
        }
    }

    func markWiping(itemCount: Int) async {
        await MainActor.run {
            model?.markWiping(itemCount: itemCount)
        }
    }

    func needsPermission(reason: String?) async {
        await MainActor.run {
            model?.showPermission(reason: reason)
        }
    }

    func finish(_ result: WipeResult, progress: WipeProgress?) async {
        // Flush anything still pending so the final numbers are not stale.
        let latest = takePending()
        await MainActor.run {
            if let latest { model?.apply(latest) }
            model?.finish(result, progress: progress)
        }
    }

    private func takePending() -> WipeProgress? {
        lock.lock()
        defer { lock.unlock() }
        let latest = pending
        pending = nil
        scheduled = false
        return latest
    }
}

enum QuickLookCache {
    /// Drops Quick Look thumbnails so previews of erased files do not linger.
    static func reset() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-r", "cache"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
