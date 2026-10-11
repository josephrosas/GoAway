import SwiftUI
import GoAwayCore

/// Every item that could not be erased, with a reason and a way to find it.
struct FailuresView: View {
    @Environment(AppModel.self) private var appModel
    var failures: [WipeFailure]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(failures) { failure in
                    row(failure)
                    if failure.id != failures.last?.id {
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(GoAwayTheme.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(GoAwayTheme.divider))
    }

    private func row(_ failure: WipeFailure) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol(for: failure.kind))
                .foregroundStyle(GoAwayTheme.accentInk)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(failure.path.lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(failure.kind.reason)
                    .font(.caption)
                    .foregroundStyle(GoAwayTheme.muted)
            }
            Spacer(minLength: 4)
            if failure.kind != .scrub {
                Button("Reveal") {
                    appModel.reveal(path: failure.path)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Reveal in Finder")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: WipeLayout.failureRow)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(failure.path.lastPathComponent), \(failure.kind.reason)")
    }

    private func symbol(for kind: FailureKind) -> String {
        switch kind {
        case .permission: return "lock.fill"
        case .busy: return "hourglass"
        case .outsideTrash: return "hand.raised.fill"
        case .scrub: return "internaldrive"
        case .other: return "exclamationmark.circle"
        }
    }
}
