import AppKit
import SwiftUI

enum AppearancePreference: String, CaseIterable, Identifiable {
    case matchMac
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .matchMac: return "Match Mac"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .matchMac: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .matchMac: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .matchMac: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum GoAwayTheme {
    static let accent = adaptive(
        light: NSColor(srgbRed: 0.07, green: 0.62, blue: 0.58, alpha: 1),
        dark: NSColor(srgbRed: 0.32, green: 0.84, blue: 0.78, alpha: 1)
    )
    static let accentInk = adaptive(
        light: NSColor(srgbRed: 0.04, green: 0.45, blue: 0.42, alpha: 1),
        dark: NSColor(srgbRed: 0.55, green: 0.92, blue: 0.86, alpha: 1)
    )
    static let fill = adaptive(
        light: NSColor.black.withAlphaComponent(0.05),
        dark: NSColor.white.withAlphaComponent(0.1)
    )
    static let muted = Color(nsColor: .secondaryLabelColor)
    static let divider = Color(nsColor: .separatorColor)
    static let page = Color(nsColor: .textBackgroundColor)
    static let shadow = adaptive(
        light: NSColor.black.withAlphaComponent(0.12),
        dark: NSColor.black.withAlphaComponent(0.5)
    )

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}
