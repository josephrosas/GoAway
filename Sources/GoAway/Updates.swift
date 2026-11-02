import Foundation
import Observation
import Sparkle

/// Sparkle updates. Only switched on in builds that carry both a feed URL and
/// the EdDSA public key in Info.plist (Scripts/build-app.sh stamps the key).
@MainActor
@Observable
final class Updates {
    private(set) var isAvailable = false
    private(set) var canCheck = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private let delegate = UpdaterDelegate()
    @ObservationIgnored private var observation: NSKeyValueObservation?

    var checksAutomatically = false {
        didSet {
            guard let updater = controller?.updater,
                  updater.automaticallyChecksForUpdates != checksAutomatically else { return }
            updater.automaticallyChecksForUpdates = checksAutomatically
        }
    }

    /// True while Sparkle is checking or showing an update. GoAway quits on its
    /// own after erasing and must not do that out from under an update prompt.
    var isBusy: Bool {
        controller?.updater.sessionInProgress ?? false
    }

    /// Called when a check, download or prompt finishes.
    var onSessionEnd: (() -> Void)? {
        get { delegate.onCycleEnd }
        set { delegate.onCycleEnd = newValue }
    }

    func start() {
        guard controller == nil else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        guard let feed = info["SUFeedURL"] as? String, !feed.isEmpty,
              let key = info["SUPublicEDKey"] as? String, !key.isEmpty else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        self.controller = controller
        isAvailable = true
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated {
                self?.canCheck = updater.canCheckForUpdates
            }
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

@MainActor
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    var onCycleEnd: (() -> Void)?

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        onCycleEnd?()
    }
}
