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
                    Text("Multi-pass wiping is for hard drives. On SSDs one pass replaces the data; extra passes only add wear.")
                        .font(.caption)
                        .foregroundStyle(GoAwayTheme.muted)
                }

                group("Starting") {
                    Toggle("Show a countdown before erasing", isOn: $appModel.confirmBeforeErasing)
                    Text("Opening GoAway erases Trash immediately. With the countdown on, you get \(AppModel.countdownSeconds) seconds and a count of what is about to go, with a chance to cancel. Hold Option while opening GoAway to skip erasing altogether.")
                        .font(.caption)
                        .foregroundStyle(GoAwayTheme.muted)
                }

                group("Beyond the file") {
                    Toggle("Also scrub free space after erasing", isOn: $appModel.scrubFreeSpace)
                    Text("Erasing overwrites each file's own blocks. Free space can still hold files deleted the normal way and blocks released by deleted snapshots; scrubbing fills it with random data, except a safety margin it leaves free. It can take minutes, briefly fills the disk, and adds wear on SSDs.")
                        .font(.caption)
                        .foregroundStyle(GoAwayTheme.muted)
                    Toggle("Show assurance warnings", isOn: $appModel.showAssuranceWarnings)
                    Text("Keeps the window open after erasing when local snapshots still hold the data or FileVault is off. Turn off to always quit right away.")
                        .font(.caption)
                        .foregroundStyle(GoAwayTheme.muted)
                }

                group("General") {
                    Toggle("Play a sound when finished", isOn: $appModel.playSound)
                    if appModel.updates.isAvailable {
                        @Bindable var updates = appModel.updates
                        HStack {
                            Toggle("Check for updates automatically", isOn: $updates.checksAutomatically)
                            Spacer()
                            Button("Check Now") {
                                updates.checkForUpdates()
                            }
                            .disabled(!updates.canCheck)
                        }
                    }
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
                    Text("Overwriting defeats recovery tools. An SSD may keep stale copies in cells no software can reach; FileVault is the real protection there.")
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
