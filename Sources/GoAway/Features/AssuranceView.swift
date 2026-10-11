import SwiftUI
import GoAwayCore

/// Honest per-volume account of what the erase achieved, plus anything that
/// can still hold the data and a button to deal with it where possible.
struct AssuranceView: View {
    @Environment(AppModel.self) private var appModel
    var assurances: [VolumeAssurance]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(assurances) { assurance in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: assurance.isClean ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(assurance.isClean ? GoAwayTheme.accentInk : Color.orange)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(assurance.volume.displayName)
                            .font(.callout.weight(.semibold))
                        Text(assurance.summary)
                            .font(.caption)
                            .foregroundStyle(GoAwayTheme.muted)
                    }
                    Spacer(minLength: 0)
                }
            }

            ForEach(Array(uniqueWarnings.enumerated()), id: \.offset) { _, warning in
                warningRow(warning)
            }

            if let message = appModel.snapshotActionMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(GoAwayTheme.muted)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GoAwayTheme.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(GoAwayTheme.divider))
    }

    private var uniqueWarnings: [AssuranceWarning] {
        var seen = Set<AssuranceWarning>()
        return assurances.flatMap(\.warnings).filter { seen.insert($0).inserted }
    }

    @ViewBuilder
    private func warningRow(_ warning: AssuranceWarning) -> some View {
        switch warning {
        case .localSnapshots(let count, _):
            HStack(spacing: 8) {
                Text(count == 1
                     ? "1 local snapshot may still hold this data."
                     : "\(count) local snapshots may still hold this data.")
                    .font(.caption)
                Spacer(minLength: 4)
                Button(appModel.isDeletingSnapshots ? "Deleting…" : "Delete Snapshots…") {
                    appModel.deleteSnapshots()
                }
                .disabled(appModel.isDeletingSnapshots)
                .controlSize(.small)
            }
        case .fileVaultOff:
            HStack(spacing: 8) {
                Text("FileVault is off: freed blocks stay readable.")
                    .font(.caption)
                Spacer(minLength: 4)
                Button("Open FileVault Settings") {
                    appModel.openFileVaultSettings()
                }
                .controlSize(.small)
            }
        case .timeMachineConfigured:
            Text("Time Machine is on: backups may hold copies.")
                .font(.caption)
                .foregroundStyle(GoAwayTheme.muted)
        }
    }
}
