import AppKit
import SwiftUI

@MainActor
final class DockProgress {
    static let shared = DockProgress()

    /// Redraws only when the visible percentage changes.
    var fraction: Double = 0 {
        didSet {
            let shown = Int((fraction * 100).rounded())
            let before = Int((oldValue * 100).rounded())
            let crossedEdge = (fraction > 0) != (oldValue > 0) || (fraction >= 1) != (oldValue >= 1)
            if shown != before || crossedEdge {
                tile.display()
            }
        }
    }

    private let tile = NSApp.dockTile
    private let view = DockProgressView()

    private init() {
        tile.contentView = view
        view.progress = self
    }
}

private final class DockProgressView: NSView {
    weak var progress: DockProgress?

    override func draw(_ dirtyRect: NSRect) {
        guard let image = BrandLogo.image else {
            NSColor.clear.setFill()
            dirtyRect.fill()
            return
        }

        let inset = bounds.insetBy(dx: 6, dy: 6)
        image.draw(in: inset, from: .zero, operation: .sourceOver, fraction: 1)

        let fraction = progress?.fraction ?? 0
        guard fraction > 0, fraction < 1 else { return }

        let ring = bounds.insetBy(dx: 3, dy: 3)
        let track = NSBezierPath(ovalIn: ring)
        track.lineWidth = 4
        NSColor.white.withAlphaComponent(0.28).setStroke()
        track.stroke()

        let start = CGFloat.pi / 2
        let end = start - (2 * .pi * fraction)
        let arc = NSBezierPath()
        arc.appendArc(
            withCenter: NSPoint(x: bounds.midX, y: bounds.midY),
            radius: ring.width / 2,
            startAngle: start * 180 / .pi,
            endAngle: end * 180 / .pi,
            clockwise: true
        )
        arc.lineWidth = 4
        arc.lineCapStyle = .round
        NSColor(srgbRed: 0.32, green: 0.84, blue: 0.78, alpha: 1).setStroke()
        arc.stroke()
    }
}
