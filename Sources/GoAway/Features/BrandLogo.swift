import AppKit
import SwiftUI

struct BrandLogo: View {
    var size: CGFloat = 28
    var shadowed = false

    var body: some View {
        logo
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .shadow(
                color: shadowed ? GoAwayTheme.accent.opacity(0.28) : .clear,
                radius: shadowed ? 16 : 0,
                y: shadowed ? 6 : 0
            )
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var logo: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(GoAwayTheme.accent)
                .overlay {
                    Image(systemName: "trash")
                        .font(.system(size: size * 0.42, weight: .bold))
                        .foregroundStyle(.white)
                }
        }
    }

    static let image: NSImage? = {
        if let url = Bundle.main.url(forResource: "AppLogo", withExtension: "png")
            ?? Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSImage(named: "AppLogo") ?? NSImage(named: "AppIcon")
    }()
}

enum BrandAppearance {
    @MainActor
    static func applyAppIcon() {
        if let image = BrandLogo.image {
            NSApp.applicationIconImage = image
        }
    }
}
