import Foundation

enum AppIdentity {
    static let name = "GoAway"
    static let bundleID = "com.unga.GoAway"
    static let website = URL(string: "https://r6.ai")!
    static let feedback = URL(string: "mailto:hi@r6.ai?subject=GoAway%20Feedback")!
}

enum AppDefaults {
    static let wipeLevel = "goaway.wipeLevel"
    static let respectSSD = "goaway.respectSSD"
    static let playSound = "goaway.playSound"
    static let appearance = "goaway.appearance"
    static let scrubFreeSpace = "goaway.scrubFreeSpace"
    static let showAssuranceWarnings = "goaway.showAssuranceWarnings"

    static func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }
}
