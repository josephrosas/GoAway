import AppKit
import Foundation
import GoAwayCore
import os

private let log = Logger(subsystem: "com.unga.GoAway", category: "app")

enum AppPhase: Equatable {
    case checking
    /// Launched with Option held: waiting for the user, nothing erased.
    case ready
    case needsPermission
    case scanning
    /// Scan finished; counting down before erasing (opt-in).
    case confirming
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
    var phase: AppPhase = .checking {
        didSet {
            holdWakeDuringRun()
            if terminationPending, !isRunning {
                terminationPending = false
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
    }

    /// Keeps idle sleep and App Nap away while a run is writing; a long
    /// multi-pass erase or scrub would otherwise stall with the screen off.
    private var wakeActivity: NSObjectProtocol?

    private func holdWakeDuringRun() {
        if isRunning, wakeActivity == nil {
            wakeActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Erasing Trash"
            )
        } else if !isRunning, let activity = wakeActivity {
            ProcessInfo.processInfo.endActivity(activity)
            wakeActivity = nil
        }
    }
    var progress = WipeProgress()
    var result: WipeResult?
    /// Why the permission screen is showing, e.g. "~/.Trash: EPERM (Operation not permitted)".
    var permissionReason: String?
    var snapshotActionMessage: String?
    var isDeletingSnapshots = false
    /// Mount points whose deleted snapshots released blocks no scrub has overwritten yet.
    var unscrubbedSnapshotSpace: Set<String> = []
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
    var confirmBeforeErasing: Bool {
        didSet { UserDefaults.standard.set(confirmBeforeErasing, forKey: AppDefaults.confirmBeforeErasing) }
    }

    static let countdownSeconds = 3
    var countdownRemaining = 0
    /// Scanned items waiting on the countdown.
    private(set) var pendingItems: [TrashItem] = []
    private var countdownTask: Task<Void, Never>?
    private var permissionWatch: Task<Void, Never>?

    enum ReadyReason { case optionKey, noRequest }
    private(set) var readyReason = ReadyReason.optionKey
    /// This run erases items handed over directly, not all of Trash.
    private(set) var erasingSelection = false

    var pendingBytes: Int64 {
        pendingItems.reduce(0) { $0 + ($1.kind == .file ? $1.byteSize : 0) }
    }

    var versionText: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var canCancel: Bool { isRunning }

    /// Engine work is in flight; quitting now must wait for it to stop.
    var isRunning: Bool { phase == .wiping || phase == .scanning || phase == .scrubbing }

    private var terminationPending = false

    /// Called from `applicationShouldTerminate`. Cancels any run and returns
    /// true when the app has to wait for it, so the scrub's cleanup and the
    /// final device flush always happen.
    func prepareToQuit() -> Bool {
        guard isRunning else { return false }
        guard !terminationPending else { return true }
        terminationPending = true
        log.notice("Quit requested during a run; cancelling first")
        cancel()
        // A wedged write must not hold the app hostage; leftovers are swept next launch.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, self.terminationPending else { return }
            self.terminationPending = false
            log.error("Run did not stop in time; quitting anyway")
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return true
    }

    /// Warnings worth holding the window open for.
    var blockingWarnings: [AssuranceWarning] {
        guard showAssuranceWarnings, let result else { return [] }
        return result.warnings.filter { $0.blocksAutoQuit }
    }

    /// The report stays up while something can still hold the erased data.
    var holdsReportOpen: Bool {
        !blockingWarnings.isEmpty || !unscrubbedSnapshotSpace.isEmpty
    }

    private var cancelFlag = CancelFlag()
    /// Trash roots of the last run, reused by retry and the post-snapshot scrub.
    private var lastRoots: [URL] = []
    private var started = false
    private var quitTask: Task<Void, Never>?
    private let probe = SystemVolumeProbe()
    let updates = Updates()

    init() {
        let storedLevel = UserDefaults.standard.string(forKey: AppDefaults.wipeLevel) ?? ""
        wipeLevel = WipeLevel(rawValue: storedLevel) ?? .dod
        respectSSD = AppDefaults.bool(forKey: AppDefaults.respectSSD, default: true)
        playSound = AppDefaults.bool(forKey: AppDefaults.playSound, default: true)
        scrubFreeSpace = AppDefaults.bool(forKey: AppDefaults.scrubFreeSpace, default: false)
        showAssuranceWarnings = AppDefaults.bool(forKey: AppDefaults.showAssuranceWarnings, default: true)
        confirmBeforeErasing = AppDefaults.bool(forKey: AppDefaults.confirmBeforeErasing, default: false)
        let storedAppearance = UserDefaults.standard.string(forKey: AppDefaults.appearance) ?? ""
        appearance = AppearancePreference(rawValue: storedAppearance) ?? .matchMac
    }

    /// Holding Option while GoAway opens skips the automatic erase, so
    /// Settings can be changed before anything is touched.
    func startIfNeeded(holdingOption: Bool = NSEvent.modifierFlags.contains(.option)) {
        guard markStarted() else { return }
        if holdingOption {
            log.info("Option held at launch; waiting instead of erasing")
            readyReason = .optionKey
            phase = .ready
            return
        }
        begin()
    }

    /// Opened for something other than a plain launch (e.g. a Services request
    /// that has not arrived yet). Never erases Trash on its own: if no request
    /// shows up, waits for the user like an Option-launch.
    func waitForRequest() {
        guard markStarted() else { return }
        log.info("Not a default launch; waiting for a request")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, self.phase == .checking else { return }
            self.readyReason = .noRequest
            self.phase = .ready
        }
    }

    private func markStarted() -> Bool {
        guard !started else { return false }
        started = true
        NSApp.appearance = appearance.nsAppearance
        return true
    }

    /// Items dropped on the icon or sent from the Services menu: confirm, move
    /// them to Trash, then erase only those.
    func eraseSelection(_ urls: [URL]) {
        let launchedForThis = markStarted() || phase == .checking
        guard !urls.isEmpty else { return }
        guard !isRunning, phase != .confirming else {
            let alert = NSAlert()
            alert.messageText = "GoAway is busy"
            alert.informativeText = "Try again when the current erase has finished."
            alert.runModal()
            return
        }
        if launchedForThis {
            erasingSelection = true
        }

        let overrideRoot = Self.overrideRoot
        if overrideRoot == nil {
            let status = FullDiskAccess.status()
            if !status.isGranted {
                showPermission(reason: status.reason)
                watchForGrant()
                return
            }
        }

        let trashRoots = overrideRoot.map { [$0] } ?? TrashEnumerator.discover()
        var accepted: [URL] = []
        var skipped: [String] = []
        for url in urls {
            if let refusal = SelectedItems.refusal(for: url, trashRoots: trashRoots) {
                skipped.append("“\(url.lastPathComponent)”: \(refusal.message)")
            } else {
                accepted.append(url)
            }
        }
        guard confirmSelection(accepted, skipped: skipped) else {
            log.info("Erasing selected items cancelled")
            if launchedForThis { NSApp.terminate(nil) }
            return
        }

        cancelQuit()
        erasingSelection = true
        result = nil
        snapshotActionMessage = nil
        unscrubbedSnapshotSpace = []
        progress = WipeProgress()
        DockProgress.shared.fraction = 0
        permissionReason = nil
        phase = .scanning
        cancelFlag = CancelFlag()
        log.info("Moving \(accepted.count) selected item(s) to Trash")
        let sink = ProgressSink(model: self)

        Task.detached(priority: .userInitiated) {
            let prepared = SelectedItems.prepare(accepted, trashRoots: trashRoots) { url in
                try Self.moveToTrash(url, override: overrideRoot)
            }
            await sink.selectionPrepared(prepared)
        }
    }

    private func confirmSelection(_ accepted: [URL], skipped: [String]) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        guard !accepted.isEmpty else {
            alert.messageText = "Nothing GoAway can erase"
            alert.informativeText = skipped.joined(separator: "\n")
            alert.runModal()
            return false
        }

        let names = accepted.prefix(3).map { "“\($0.lastPathComponent)”" }
        var info: String
        if accepted.count == 1 {
            alert.messageText = "Permanently erase \(names[0])?"
            info = "It moves to Trash and is erased right away."
        } else {
            alert.messageText = "Permanently erase \(accepted.count) items?"
            let more = accepted.count > names.count ? " and \(accepted.count - names.count) more" : ""
            info = names.joined(separator: ", ") + more + "\n\nThey move to Trash and are erased right away."
        }
        info += " This cannot be undone. Nothing else in Trash is touched."
        if !skipped.isEmpty {
            info += "\n\nSkipped:\n" + skipped.joined(separator: "\n")
        }
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Erase").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    nonisolated private static func moveToTrash(_ url: URL, override: URL?) throws -> URL {
        guard let override else {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            guard let moved = resulting as URL? else { throw CocoaError(.fileNoSuchFile) }
            return moved
        }
        // Development: the fake Trash stands in for the real one.
        var target = override.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) {
            target = override.appendingPathComponent("\(url.lastPathComponent) \(SecureEraser.randomName())")
        }
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    fileprivate func selectionPrepared(_ prepared: SelectedItems.Prepared) {
        lastRoots = prepared.roots
        guard !prepared.items.isEmpty else {
            finish(WipeResult(outcome: .completed, erasedCount: 0, remainingCount: 0, failures: prepared.failures),
                   progress: nil)
            return
        }
        startWipe(prepared.items, extraFailures: prepared.failures)
    }

    /// Full Disk Access only applies to processes started after it was granted,
    /// so the only way to pick up a new grant is a fresh launch.
    func relaunch() {
        relaunch(automatic: false)
    }

    private func relaunch(automatic: Bool) {
        let bundle = Bundle.main.bundleURL.path
        log.notice("Relaunching \(bundle, privacy: .public) to pick up Full Disk Access")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this instance to exit so the new one does not just activate it.
        let escaped = bundle.replacingOccurrences(of: "'", with: "'\\''")
        let args = automatic ? " --args \(Self.relaunchedForAccess)" : ""
        process.arguments = ["-c", "sleep 0.6; /usr/bin/open -n '\(escaped)'\(args)"]
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
        cancelQuit()
        snapshotActionMessage = nil

        if lastRoots.isEmpty {
            lastRoots = Self.overrideRoot.map { [$0] } ?? TrashEnumerator.discover()
        }
        let request = makeRequest(roots: lastRoots)
        let guardrail = PathGuard(roots: request.roots)
        // A failed folder usually still holds items that were never erased; take them too.
        var seen = Set<String>()
        let items = paths.flatMap { path -> [TrashItem] in
            let url = URL(fileURLWithPath: path)
            guard guardrail.allowsUnlink(url) else { return [] }
            return TrashEnumerator.collectSubtree(at: url, guardrail: guardrail)
        }.filter { seen.insert(PathGuard.normalize($0.url)).inserted }
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
        cancelQuit()

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
        let freed = updated.assurances.filter { !$0.localSnapshots.isEmpty }.map(\.volume.mountPoint)
        updated.assurances = updated.assurances.map { assurance in
            var copy = assurance
            copy.localSnapshots.removeAll { dates.contains($0) }
            return copy
        }
        result = updated
        snapshotActionMessage = dates.count == 1 ? "Deleted 1 snapshot." : "Deleted \(dates.count) snapshots."
        // The released blocks still hold the Trash data; only a scrub reaches them.
        unscrubbedSnapshotSpace.formUnion(freed)
        if scrubFreeSpace {
            scrubFreedSpace()
        } else if !holdsReportOpen, updated.failures.isEmpty {
            scheduleQuit()
        }
    }

    /// Scrubs volumes whose snapshots were deleted after the run.
    func scrubFreedSpace() {
        guard let previous = result, !unscrubbedSnapshotSpace.isEmpty, !canCancel else { return }
        cancelQuit()
        let mounts = unscrubbedSnapshotSpace
        let request = makeRequest(roots: lastRoots)
        log.info("Scrubbing space released by deleted snapshots on \(mounts.count) volume(s)")

        phase = .scrubbing
        progress = WipeProgress(phaseLabel: "Scrubbing free space", isScrubbing: true)
        cancelFlag = CancelFlag()
        let flag = cancelFlag
        let sink = ProgressSink(model: self)
        Task.detached(priority: .userInitiated) {
            let report = WipeRunner.scrubOnly(request, mountPoints: mounts, cancel: flag, progress: sink.apply)
            await sink.finishScrub(report, previous: previous)
        }
    }

    fileprivate func finishScrub(_ report: WipeRunner.ScrubReport, previous: WipeResult) {
        var updated = previous
        updated.assurances = updated.assurances.map { assurance in
            var copy = assurance
            if let bytes = report.scrubbed[assurance.volume.mountPoint] {
                copy.freeSpaceScrubbed = true
                copy.scrubbedBytes = bytes
            }
            return copy
        }
        updated.failures += report.failures
        if report.cancelled {
            updated.outcome = .cancelled
        }
        unscrubbedSnapshotSpace.subtract(report.scrubbed.keys)
        snapshotActionMessage = report.cancelled ? nil : "Scrubbed the space the snapshots released."
        finish(updated, progress: nil)
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
        cancelQuit()
        erasingSelection = false
        result = nil
        snapshotActionMessage = nil
        unscrubbedSnapshotSpace = []
        lastRoots = []
        progress = WipeProgress()
        DockProgress.shared.fraction = 0

        let overrideRoot = Self.overrideRoot
        if overrideRoot == nil {
            let status = FullDiskAccess.status()
            if !status.isGranted {
                showPermission(reason: status.reason)
                watchForGrant()
                return
            }
        }

        permissionReason = nil
        phase = .scanning
        log.info("Scanning Trash")
        cancelFlag = CancelFlag()
        let sink = ProgressSink(model: self)

        Task.detached(priority: .userInitiated) {
            let roots = overrideRoot.map { [$0] } ?? TrashEnumerator.discover()
            let released = FreeSpaceScrubber.removeLeftovers(in: roots)
            if released > 0 {
                log.notice("Removed leftover scrub data: \(released) bytes")
            }
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

            await sink.scanned(items: items, roots: roots)
        }
    }

    fileprivate func showPermission(reason: String?) {
        permissionReason = reason
        phase = .needsPermission
        log.notice("Showing permission screen: \(reason ?? "no reason", privacy: .private)")
    }

    private static let relaunchedForAccess = "--relaunched-for-access"

    /// Every 2 s, asks a freshly started helper whether access is on now, and
    /// relaunches when it is. Only used when this process itself lacks access
    /// (so the helper can see something new), and never right after an
    /// automatic relaunch, so a grant macOS keeps refusing cannot loop.
    private func watchForGrant() {
        permissionWatch?.cancel()
        guard !ProcessInfo.processInfo.arguments.contains(Self.relaunchedForAccess),
              let probe = Self.probeURL else { return }
        permissionWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.phase == .needsPermission, !Task.isCancelled else { return }
                if await Self.probeReportsAccess(probe) {
                    log.notice("Helper sees Full Disk Access; relaunching")
                    self.relaunch(automatic: true)
                    return
                }
            }
        }
    }

    private static var probeURL: URL? {
        guard let url = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("GoAwayProbe"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    nonisolated private static func probeReportsAccess(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = url
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }

    /// The scan is done: erase now, or count down first when the user asked for that.
    fileprivate func scanned(items: [TrashItem], roots: [URL]) {
        lastRoots = roots
        if cancelFlag.isCancelled {
            finish(WipeResult(outcome: .cancelled, erasedCount: 0, remainingCount: items.count, failures: []),
                   progress: nil)
            return
        }
        guard confirmBeforeErasing else {
            startWipe(items)
            return
        }
        pendingItems = items
        countdownRemaining = Self.countdownSeconds
        phase = .confirming
        log.info("Counting down before erasing \(items.count) item(s)")
        countdownTask = Task { @MainActor [weak self] in
            while let self, self.countdownRemaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, self.phase == .confirming else { return }
                self.countdownRemaining -= 1
            }
            self?.eraseNow()
        }
    }

    /// Skips the rest of the countdown.
    func eraseNow() {
        guard phase == .confirming else { return }
        countdownTask?.cancel()
        let items = pendingItems
        pendingItems = []
        startWipe(items)
    }

    /// Stops during the countdown; nothing has been touched.
    func cancelCountdown() {
        guard phase == .confirming else { return }
        countdownTask?.cancel()
        let count = pendingItems.count
        pendingItems = []
        log.info("Countdown cancelled; nothing erased")
        finish(WipeResult(outcome: .cancelled, erasedCount: 0, remainingCount: count, failures: []), progress: nil)
    }

    /// Option-launch landing: nothing runs until the user says so.
    func eraseTrashNow() {
        guard phase == .ready else { return }
        begin()
    }

    private func startWipe(_ items: [TrashItem], extraFailures: [WipeFailure] = []) {
        // Built here, not before the scan, so settings changed during a countdown apply.
        let request = makeRequest(roots: lastRoots)
        markWiping(itemCount: items.count)
        let flag = cancelFlag
        let sink = ProgressSink(model: self)
        Task.detached(priority: .userInitiated) {
            var outcome = WipeRunner.run(items: items, request: request, cancel: flag, progress: sink.apply)
            outcome.failures.insert(contentsOf: extraFailures, at: 0)
            await sink.finish(outcome, progress: nil)
        }
    }

    private func markWiping(itemCount: Int) {
        phase = .wiping
        progress.itemsTotal = itemCount
        log.info("Erasing \(itemCount) item(s)")
    }

    /// Development hook: point the whole run at a fake Trash instead of the real one.
    private static var overrideRoot: URL? {
        ProcessInfo.processInfo.environment["GOAWAY_TRASH_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
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
            // Names of erased files must not outlive them in the persisted log.
            log.error("Failed (\(failure.kind.reason, privacy: .public)) \(failure.path, privacy: .private): \(failure.message, privacy: .private)")
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
            if result.failures.isEmpty, !holdsReportOpen {
                scheduleQuit()
            }
        case .cancelled:
            phase = .cancelled
        }
    }

    private func scheduleQuit() {
        cancelQuit()
        quitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self else { return }
            guard !self.updates.isBusy else {
                // An update check or prompt is up; quit once it is dealt with.
                log.info("Update session in progress; quitting after it ends")
                self.updates.onSessionEnd = { [weak self] in
                    self?.updates.onSessionEnd = nil
                    self?.scheduleQuit()
                }
                return
            }
            NSApp.terminate(nil)
        }
    }

    private func cancelQuit() {
        quitTask?.cancel()
        updates.onSessionEnd = nil
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

    func scanned(items: [TrashItem], roots: [URL]) async {
        await MainActor.run {
            model?.scanned(items: items, roots: roots)
        }
    }

    func selectionPrepared(_ prepared: SelectedItems.Prepared) async {
        await MainActor.run {
            model?.selectionPrepared(prepared)
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

    func finishScrub(_ report: WipeRunner.ScrubReport, previous: WipeResult) async {
        let latest = takePending()
        await MainActor.run {
            if let latest { model?.apply(latest) }
            model?.finishScrub(report, previous: previous)
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
