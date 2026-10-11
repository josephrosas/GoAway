import SwiftUI

struct PermissionView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                BrandLogo(size: 48, shadowed: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("GoAway")
                        .font(.title3.weight(.semibold))
                    Text("Needs Full Disk Access")
                        .font(.callout)
                        .foregroundStyle(GoAwayTheme.muted)
                }
            }

            Text("macOS keeps Trash behind a privacy gate. The grant only applies to a freshly launched GoAway.")
                .font(.callout)
                .foregroundStyle(GoAwayTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                step("1", "Open Privacy & Security → Full Disk Access")
                step("2", "Turn on GoAway. If it is already on, turn it off and on again, or remove it with − and drag this copy back in.")
                step("3", "Relaunch GoAway")
            }

            if let reason = appModel.permissionReason {
                Text("macOS said: \(reason)")
                    .font(.caption)
                    .foregroundStyle(GoAwayTheme.muted)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Open System Settings") {
                    appModel.openFullDiskAccess()
                }

                Button("Reveal GoAway") {
                    appModel.revealApp()
                }

                Spacer()

                Button("Relaunch GoAway") {
                    appModel.relaunch()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GoAwayTheme.page)
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(number)
                .font(.caption.weight(.semibold))
                .foregroundStyle(GoAwayTheme.accentInk)
                .frame(width: 16)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
