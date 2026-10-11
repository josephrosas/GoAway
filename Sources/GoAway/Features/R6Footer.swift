import AppKit
import SwiftUI

struct R6Footer: View {
    var showsProductName = true

    var body: some View {
        VStack(spacing: 14) {
            Rectangle()
                .fill(GoAwayTheme.divider)
                .frame(height: 1)
                .padding(.horizontal, showsProductName ? 48 : 0)

            VStack(spacing: 6) {
                if showsProductName {
                    Text("GoAway")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .tracking(1.6)
                        .foregroundStyle(GoAwayTheme.muted)
                        .textCase(.uppercase)
                }

                HStack(spacing: 5) {
                    Text("an")
                    Link(destination: AppIdentity.website) {
                        Text("R6.ai")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .tracking(-0.4)
                            .foregroundStyle(GoAwayTheme.accentInk)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    Text("product")
                }
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(GoAwayTheme.muted)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, showsProductName ? 8 : 0)
        .padding(.bottom, showsProductName ? 12 : 0)
    }
}
