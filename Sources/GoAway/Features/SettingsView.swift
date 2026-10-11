import SwiftUI
import GoAwayCore

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings")
                    .font(.system(size: 22, weight: .semibold))

                group("Erasing") {
                    Picker("File erasing level", selection: $appModel.wipeLevel) {
                        ForEach(WipeLevel.allCases) { level in
                            Text(level.title).tag(level)
                        }
                    }
                    Toggle("Use a single pass on SSDs", isOn: $appModel.respectSSD)
                    Text(appModel.wipeLevel.summary)
                        .font(.caption)
                        .foregroundStyle(GoAwayTheme.muted)
                    Text("Opening GoAway erases Trash immediately. Multi-pass wiping is for hard drives. SSDs and APFS cannot guarantee a physical overwrite.")
                        .font(.caption)
                        .foregroundStyle(GoAwayTheme.muted)
                }

                group("Beyond the file") {
                    Toggle("Also scrub free space after erasing", isOn: $appModel.scrubFreeSpace)
                    Text("APFS never overwrites in place; it frees the old blocks. Scrubbing fills the volume's free space with random data so those blocks cannot be read back. It can take minutes, briefly fills the disk, and adds wear on SSDs.")
                        .font(.caption)
                        .foregroundStyle(GoAwayTheme.muted)
                    Toggle("Show assurance warnings", isOn: $appModel.showAssuranceWarnings)
                    Text("Keeps the window open after erasing when local snapshots still hold the data or FileVault is off. Turn off to always quit right away.")
                        .font(.caption)
                        .foregroundStyle(GoAwayTheme.muted)
                }

                group("General") {
                    Toggle("Play a sound when finished", isOn: $appModel.playSound)
                    Button("Send Feedback…") {
                        appModel.sendFeedback()
                    }
                }

                group("Appearance") {
                    Picker("Appearance", selection: $appModel.appearance) {
                        ForEach(AppearancePreference.allCases) { option in
                            Label(option.title, systemImage: option.symbol)
                                .tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Text("Match Mac follows System Settings. Light and Dark stay that way even if you change macOS later.")
                        .font(.caption)
                        .foregroundStyle(GoAwayTheme.muted)
                }

                group("About") {
                    HStack(spacing: 14) {
                        BrandLogo(size: 56, shadowed: true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("GoAway")
                                .font(.title3.weight(.semibold))
                            Text("Permanently erases your Trash")
                                .font(.caption)
                                .foregroundStyle(GoAwayTheme.muted)
                        }
                    }
                    LabeledContent("Version", value: appModel.versionText)
                    Text("Overwriting helps against casual recovery. On SSDs and APFS, FileVault is the real protection.")
                        .font(.caption)
                        .foregroundStyle(GoAwayTheme.muted)
                }

                R6Footer()
            }
            .padding(28)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .frame(minWidth: 480, minHeight: 560, alignment: .topLeading)
        .background(GoAwayTheme.page)
        .preferredColorScheme(appModel.appearance.colorScheme)
        .onAppear {
            BrandAppearance.applyAppIcon()
        }
    }

    private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GoAwayTheme.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(GoAwayTheme.divider))
    }
}
