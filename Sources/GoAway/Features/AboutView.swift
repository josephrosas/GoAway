import SwiftUI

struct AboutView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                BrandLogo(size: 64, shadowed: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("GoAway")
                        .font(.title2.weight(.semibold))
                    Text("Permanently erases your Trash")
                        .font(.callout)
                        .foregroundStyle(GoAwayTheme.muted)
                }
            }

            LabeledContent("Version", value: appModel.versionText)
            LabeledContent("Open", value: "Wipes Trash immediately")

            Text("Overwriting helps against casual recovery. On SSDs and APFS, FileVault is the real protection — extra passes cannot reach every physical block.")
                .font(.caption)
                .foregroundStyle(GoAwayTheme.muted)

            Spacer(minLength: 0)

            R6Footer(showsProductName: false)
        }
        .padding(28)
        .frame(width: 420, height: 320, alignment: .topLeading)
        .background(GoAwayTheme.page)
        .preferredColorScheme(appModel.appearance.colorScheme)
        .onAppear {
            BrandAppearance.applyAppIcon()
        }
    }
}
