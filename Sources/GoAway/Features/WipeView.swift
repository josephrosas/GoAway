import AppKit
import SwiftUI
import GoAwayCore

struct WipeRootView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        // The window follows the content, so it only grows when there is a
        // report worth reading.
        AtLeastHeight(minHeight: 340) {
            switch appModel.phase {
            case .needsPermission:
                PermissionView()
            default:
                WipeView()
            }
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(GoAwayTheme.page)
        .preferredColorScheme(appModel.appearance.colorScheme)
        .background(WindowConfigurator(appearance: appModel.appearance))
        .onAppear {
            BrandAppearance.applyAppIcon()
        }
    }
}

/// Takes the content's natural height but never less than `minHeight`, then
/// lays the content out at that height so its spacers fill any extra room.
struct AtLeastHeight: Layout {
    var minHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let natural = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? natural.width, height: max(minHeight, natural.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

enum WipeLayout {
    static let failureRow: CGFloat = 44
    static let failureRowsShown = 4

    static func failuresHeight(count: Int) -> CGFloat {
        CGFloat(max(1, min(count, failureRowsShown))) * failureRow + 2
    }
}

struct WipeView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 10) {
                BrandLogo(size: 36, shadowed: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("GoAway")
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(GoAwayTheme.muted)
                }
                Spacer()
            }

            if appModel.phase == .failed, let result = appModel.result {
                FailuresView(failures: result.failures)
                    .frame(height: WipeLayout.failuresHeight(count: result.failures.count))
            } else {
                ProgressRing(fraction: displayFraction, symbol: symbolName, text: ringText)
                    .frame(width: 112, height: 112)
            }

            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .multilineTextAlignment(.center)

                if !detail.isEmpty {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(GoAwayTheme.muted)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }

                if !counts.isEmpty {
                    Text(counts)
                        .font(.caption)
                        .foregroundStyle(GoAwayTheme.muted)
                        .monospacedDigit()
                }
            }

            if showsAssurance, let result = appModel.result {
                AssuranceView(assurances: result.assurances)
            }

            Spacer(minLength: 0)

            if appModel.canCancel {
                Button("Cancel") {
                    appModel.cancel()
                }
                .keyboardShortcut(.cancelAction)
            } else if appModel.phase == .ready {
                HStack {
                    SettingsLink {
                        Text("Settings…")
                    }
                    Button("Erase Trash Now") {
                        appModel.eraseTrashNow()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else if appModel.phase == .confirming {
                HStack {
                    Button("Cancel") {
                        appModel.cancelCountdown()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Erase Now") {
                        appModel.eraseNow()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else if appModel.phase == .failed {
                HStack {
                    Button("Retry Failed") {
                        appModel.retryFailed()
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("Close") {
                        NSApplication.shared.terminate(nil)
                    }
                }
            } else if appModel.phase == .cancelled || appModel.holdsReportOpen {
                Button("Close") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .onAppear {
            if opensSettings(for: appModel.phase) { openSettings() }
        }
        .onChange(of: appModel.phase) { _, phase in
            if opensSettings(for: phase) { openSettings() }
        }
    }

    private func opensSettings(for phase: AppPhase) -> Bool {
        phase == .ready && appModel.readyReason == .optionKey
    }

    private var showsAssurance: Bool {
        switch appModel.phase {
        case .done, .cancelled, .failed:
            return appModel.holdsReportOpen
        default:
            return false
        }
    }

    private var displayFraction: Double {
        switch appModel.phase {
        case .done, .empty:
            return 1
        case .checking, .scanning:
            return 0.05
        case .ready:
            return 0
        case .confirming:
            let total = Double(AppModel.countdownSeconds)
            return (total - Double(appModel.countdownRemaining)) / total
        default:
            return appModel.progress.fraction
        }
    }

    private var symbolName: String {
        switch appModel.phase {
        case .done, .empty: return "checkmark"
        case .cancelled: return "stop.fill"
        case .failed: return "exclamationmark"
        case .ready: return "trash"
        default: return ""
        }
    }

    private var ringText: String? {
        appModel.phase == .confirming ? "\(appModel.countdownRemaining)" : nil
    }

    private var subtitle: String {
        switch appModel.phase {
        case .ready:
            return appModel.readyReason == .optionKey ? "Option was held at launch" : "Waiting for you"
        case .confirming: return "About to permanently erase Trash"
        case .checking:
            return appModel.erasingSelection ? "Erasing selected items" : "Starting…"
        case .scanning:
            return appModel.erasingSelection ? "Moving to Trash…" : "Looking through Trash…"
        case .wiping:
            let what = appModel.erasingSelection ? "Permanently erasing selected items" : "Permanently erasing Trash"
            let label = appModel.progress.passLabel
            return label.isEmpty ? what : "\(what) · \(label)"
        case .scrubbing: return "Overwriting freed space"
        case .empty: return "Trash is already clear"
        case .done: return "Permanently erased"
        case .cancelled: return "Stopped"
        case .failed: return "Finished with issues"
        case .needsPermission: return "Needs Full Disk Access"
        }
    }

    private var title: String {
        switch appModel.phase {
        case .ready:
            return "Nothing erased yet"
        case .confirming:
            let count = appModel.pendingItems.count
            let items = count == 1 ? "1 item" : "\(count) items"
            return "Erasing \(items) in \(appModel.countdownRemaining)…"
        case .checking:
            return appModel.erasingSelection ? "Waiting for confirmation" : "Getting ready"
        case .scanning:
            return appModel.erasingSelection ? "Getting ready" : "Scanning Trash"
        case .wiping:
            let count = appModel.progress.itemsTotal
            return count == 1 ? "Erasing 1 item" : "Erasing \(count) items"
        case .scrubbing:
            return appModel.progress.phaseLabel
        case .empty:
            return "Nothing to erase"
        case .done:
            let count = appModel.result?.erasedCount ?? appModel.progress.itemsDone
            return count == 1 ? "1 item is gone" : "\(count) items are gone"
        case .cancelled:
            return "Stopped"
        case .failed:
            let failed = appModel.result?.failures.count ?? 0
            return failed == 1 ? "1 item could not be erased" : "\(failed) items could not be erased"
        case .needsPermission:
            return "Permission needed"
        }
    }

    private var detail: String {
        switch appModel.phase {
        case .ready:
            return appModel.readyReason == .optionKey
                ? "Adjust Settings if you like, then erase."
                : "Erase Trash, or drop items on GoAway to erase just those."
        case .confirming:
            let bytes = appModel.pendingBytes
            return bytes > 0 ? "\(bytes.formattedBytes) will be gone for good." : "They will be gone for good."
        case .wiping:
            return appModel.progress.currentName
        case .scrubbing:
            return "Filling free space with random data so freed blocks cannot be read back."
        case .cancelled:
            let left = appModel.result?.remainingCount ?? 0
            if left == 0 {
                return appModel.progress.isScrubbing
                    ? "Trash is empty. Free-space scrub was stopped early."
                    : "Remaining items stayed in Trash."
            }
            return left == 1 ? "1 item left in Trash." : "\(left) items left in Trash."
        case .failed:
            return "Select an item to reveal it in Finder, then retry."
        case .done:
            if let message = appModel.snapshotActionMessage { return message }
            return ""
        default:
            return ""
        }
    }

    private var counts: String {
        let progress = appModel.progress
        switch appModel.phase {
        case .wiping:
            var parts = ["\(progress.itemsDone) of \(progress.itemsTotal)"]
            if progress.bytesRemaining > 0 {
                parts.append("\(progress.bytesRemaining.formattedBytes) left")
            }
            parts.append(contentsOf: rateParts(progress))
            return parts.joined(separator: " · ")
        case .scrubbing:
            var parts: [String] = []
            if progress.bytesTotal > 0 {
                parts.append("\(progress.bytesDone.formattedBytes) of \(progress.bytesTotal.formattedBytes)")
            }
            parts.append(contentsOf: rateParts(progress))
            return parts.joined(separator: " · ")
        case .failed:
            let erased = appModel.result?.erasedCount ?? 0
            return erased == 1 ? "1 erased" : "\(erased) erased"
        default:
            return ""
        }
    }

    private func rateParts(_ progress: WipeProgress) -> [String] {
        var parts: [String] = []
        if progress.bytesPerSecond > 1 {
            parts.append("\(Int64(progress.bytesPerSecond).formattedBytes)/s")
        }
        if let seconds = progress.estimatedSecondsRemaining {
            parts.append(seconds.formattedRemaining)
        }
        return parts
    }
}

struct ProgressRing: View {
    var fraction: Double
    var symbol: String
    /// Shown instead of the percentage, e.g. a countdown digit.
    var text: String? = nil

    var body: some View {
        ZStack {
            Circle()
                .stroke(GoAwayTheme.fill, lineWidth: 8)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(
                    GoAwayTheme.accent,
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.2), value: fraction)

            if let text {
                Text(text)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(GoAwayTheme.accentInk)
                    .contentTransition(.numericText(countsDown: true))
            } else if symbol.isEmpty {
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(GoAwayTheme.accentInk)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(GoAwayTheme.accentInk)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue(spokenValue)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var spokenValue: String {
        if let text { return "Starting in \(text)" }
        switch symbol {
        case "": return "\(Int((fraction * 100).rounded())) percent"
        case "checkmark": return "Finished"
        case "stop.fill": return "Stopped"
        case "exclamationmark": return "Finished with issues"
        case "trash": return "Waiting"
        default: return ""
        }
    }
}

private struct WindowConfigurator: NSViewRepresentable {
    var appearance: AppearancePreference

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            Self.apply(to: view.window, appearance: appearance)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        Self.apply(to: nsView.window, appearance: appearance)
    }

    private static func apply(to window: NSWindow?, appearance: AppearancePreference) {
        guard let window else { return }
        window.title = "GoAway"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isRestorable = false
        window.appearance = appearance.nsAppearance
        window.backgroundColor = NSColor.textBackgroundColor
    }
}

extension String {
    var lastPathComponent: String {
        (self as NSString).lastPathComponent
    }
}

extension Int64 {
    var formattedBytes: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: self)
    }
}

extension Double {
    /// "about 15 s", "about 3 min", "about 2 h".
    var formattedRemaining: String {
        if self < 60 { return "about \(max(1, Int(self.rounded()))) s" }
        if self < 3600 { return "about \(Int((self / 60).rounded())) min" }
        let hours = self / 3600
        return hours < 10 ? String(format: "about %.1f h", hours) : "about \(Int(hours.rounded())) h"
    }
}
