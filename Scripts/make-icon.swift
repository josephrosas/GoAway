// Draws GoAway's icon: a bin whose right side breaks into pixels that drift
// away. Writes Resources/AppIcon.icns and AppIcon.png (Apple's icon grid, with
// the transparent margin and shadow) and Sources/GoAway/Assets/AppLogo.png
// (full-bleed tile for in-app use; the app rounds its corners).
//
// Usage: swift Scripts/make-icon.swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette and geometry (1024-unit canvas, y pointing down)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tileTop = rgb(0x3FE0CB)
let tileBottom = rgb(0x073F3C)
let glyph = rgb(0xFFFFFF)
let glyphShade = rgb(0xA8EDE3, 0.45)

let cx: CGFloat = 476
let handleTop: CGFloat = 284
let lidTop: CGFloat = 340
let lidBottom: CGFloat = 386
let bodyTop: CGFloat = 404
let bodyBottom: CGFloat = 770
let topHalf: CGFloat = 176
let bottomHalf: CGFloat = 144
let cell: CGFloat = 23
let gridLeft = cx - 253

/// Where the bin breaks apart: a diagonal, so more of the top has gone.
func breakLine(atY y: CGFloat) -> CGFloat {
    cx + 62 + (y - lidTop) / (bodyBottom - lidTop) * 70
}

/// Deterministic jitter so every run draws the same icon.
struct Jitter {
    var state: UInt64
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((state >> 40) & 0xFFFF) / CGFloat(0xFFFF)
    }
}

func squircle(_ rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    for i in 0..<steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let point = CGPoint(
            x: rect.midX + rect.width / 2 * copysign(pow(abs(c), 2 / n), c),
            y: rect.midY + rect.height / 2 * copysign(pow(abs(s), 2 / n), s)
        )
        i == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    path.closeSubpath()
    return path
}

/// Pixels that would drift this close to the tile's edge are left out.
let safeArea = squircle(tile.insetBy(dx: 70, dy: 70))

func binBody() -> CGPath {
    let tl = CGPoint(x: cx - topHalf, y: bodyTop)
    let tr = CGPoint(x: cx + topHalf, y: bodyTop)
    let br = CGPoint(x: cx + bottomHalf, y: bodyBottom)
    let bl = CGPoint(x: cx - bottomHalf, y: bodyBottom)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: cx, y: bodyTop))
    path.addArc(tangent1End: tr, tangent2End: br, radius: 18)
    path.addArc(tangent1End: br, tangent2End: bl, radius: 62)
    path.addArc(tangent1End: bl, tangent2End: tl, radius: 62)
    path.addArc(tangent1End: tl, tangent2End: tr, radius: 18)
    path.closeSubpath()
    return path
}

func binLid() -> CGPath {
    CGPath(roundedRect: CGRect(x: cx - 206, y: lidTop, width: 412, height: lidBottom - lidTop),
           cornerWidth: 23, cornerHeight: 23, transform: nil)
}

func binHandle() -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: cx - 52, y: lidTop + 4))
    path.addArc(tangent1End: CGPoint(x: cx - 52, y: handleTop + 12), tangent2End: CGPoint(x: cx + 52, y: handleTop + 12), radius: 22)
    path.addArc(tangent1End: CGPoint(x: cx + 52, y: handleTop + 12), tangent2End: CGPoint(x: cx + 52, y: lidTop + 4), radius: 22)
    path.addLine(to: CGPoint(x: cx + 52, y: lidTop + 4))
    return path.copy(strokingWithWidth: 24, lineCap: .butt, lineJoin: .round, miterLimit: 10)
}

/// Ribs cut through the body, following its taper.
func binSlots() -> CGPath {
    let path = CGMutablePath()
    for k: CGFloat in [-1, 0] {
        path.move(to: CGPoint(x: cx + k * 82, y: 466))
        path.addLine(to: CGPoint(x: cx + k * 68, y: 708))
    }
    return path.copy(strokingWithWidth: 22, lineCap: .round, lineJoin: .round, miterLimit: 10)
}

struct Square {
    var rect: CGRect
    var alpha: CGFloat
}

/// Cuts `shape` along the break line: the grid cells left of it stay in
/// `solid`, the ones right of it come loose and drift up and away, faster and
/// fainter the further they were from the break.
func dissolve(_ shape: CGPath, top: CGFloat, bottom: CGFloat,
              solid: CGMutablePath, loose: inout [Square], jitter: inout Jitter) {
    let rows = Int(((bottom - top) / cell).rounded(.up))
    for row in 0..<rows {
        let y = top + CGFloat(row) * cell
        let front = Int(((breakLine(atY: y + cell / 2) - gridLeft) / cell).rounded())
        let frontX = gridLeft + CGFloat(front) * cell
        solid.addRect(CGRect(x: gridLeft - 60, y: y, width: frontX - gridLeft + 60, height: cell))

        var column = front
        while gridLeft + CGFloat(column) * cell < cx + 260 {
            defer { column += 1 }
            let center = CGPoint(x: gridLeft + (CGFloat(column) + 0.5) * cell, y: y + cell / 2)
            guard shape.contains(center) else { continue }
            let distance = CGFloat(column - front) + 0.2 + jitter.next() * 1.3
            let t = min(1, distance / 5.5)
            // Some pixels have already vanished, more of them the further out.
            if jitter.next() < 0.35 * t { continue }
            let lift = pow(t, 1.6)
            let side = (cell - 4) * (1 - 0.45 * t)
            let moved = CGPoint(
                x: center.x + lift * 190 + (jitter.next() - 0.5) * 34 * t,
                y: center.y - lift * 226 - t * 8 + (jitter.next() - 0.5) * 44 * t
            )
            guard safeArea.contains(moved) else { continue }
            loose.append(Square(
                rect: CGRect(x: moved.x - side / 2, y: moved.y - side / 2, width: side, height: side),
                alpha: 1 - 0.78 * pow(t, 1.3)
            ))
        }
    }
}

func dissolvedBin() -> (solid: CGPath, loose: [Square]) {
    var jitter = Jitter(state: 0x60A3A1)
    let solid = CGMutablePath()
    var loose: [Square] = []
    dissolve(binLid(), top: lidTop, bottom: lidBottom, solid: solid, loose: &loose, jitter: &jitter)
    dissolve(binBody(), top: bodyTop, bottom: bodyBottom, solid: solid, loose: &loose, jitter: &jitter)

    // A few stragglers further along the same path, smallest and faintest last.
    let start = CGPoint(x: cx + 226, y: 282)
    let control = CGPoint(x: 744, y: 250)
    let end = CGPoint(x: 796, y: 200)
    for i in 0..<7 {
        let s = CGFloat(i) / 6
        let u = 1 - s
        let point = CGPoint(
            x: u * u * start.x + 2 * u * s * control.x + s * s * end.x + (jitter.next() - 0.5) * 40,
            y: u * u * start.y + 2 * u * s * control.y + s * s * end.y + (jitter.next() - 0.5) * 34
        )
        let side = 14 * (1 - 0.45 * s)
        loose.append(Square(
            rect: CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side),
            alpha: 0.32 * (1 - 0.6 * s)
        ))
    }
    return (solid, loose)
}

// MARK: - Drawing

/// Shadows ignore the transform and work in y-up device pixels, so convert
/// from design units by hand.
func castShadow(_ ctx: CGContext, drop: CGFloat, blur: CGFloat, color: CGColor) {
    let unit = ctx.ctm.a
    ctx.setShadow(offset: CGSize(width: 0, height: -drop * unit), blur: blur * unit, color: color)
}

func drawTile(_ ctx: CGContext, fullBleed: Bool, pixelSize: CGFloat) {
    let shape: CGPath = fullBleed ? CGPath(rect: tile, transform: nil) : squircle(tile)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    if !fullBleed {
        // Apple's grid: the tile floats on a soft shadow inside the transparent margin.
        ctx.saveGState()
        castShadow(ctx, drop: 12, blur: 28, color: rgb(0x000000, 0.32))
        ctx.addPath(shape)
        ctx.setFillColor(tileBottom)
        ctx.fillPath()
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let extend: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    let fill = CGGradient(colorsSpace: space, colors: [tileTop, tileBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(fill, start: CGPoint(x: 300, y: 100), end: CGPoint(x: 720, y: 924), options: extend)
    let sheen = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.20), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(sheen, startCenter: CGPoint(x: 290, y: 140), startRadius: 0,
                           endCenter: CGPoint(x: 290, y: 140), endRadius: 620, options: [])
    let glow = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: cx + 60, y: 500), startRadius: 0,
                           endCenter: CGPoint(x: cx + 60, y: 500), endRadius: 430, options: [])
    if !fullBleed {
        ctx.addPath(shape)
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.16))
        ctx.setLineWidth(4)
        ctx.strokePath()
    }
    ctx.restoreGState()

    drawGlyph(ctx, pixelSize: pixelSize)
}

func drawGlyph(_ ctx: CGContext, pixelSize: CGFloat) {
    let (solid, loose) = dissolvedBin()
    // Small sizes keep the silhouette; slots and faint pixels would only blur.
    let showSlots = pixelSize >= 64
    let minimumAlpha: CGFloat = pixelSize <= 32 ? 0.5 : 0.05
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    ctx.saveGState()
    castShadow(ctx, drop: 14, blur: 30, color: rgb(0x002A27, 0.40))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)

    ctx.setFillColor(glyph)
    ctx.addPath(binHandle())
    ctx.fillPath()

    ctx.saveGState()
    ctx.addPath(solid)
    ctx.clip()
    ctx.addPath(binLid())
    ctx.addPath(binBody())
    ctx.fillPath()
    ctx.restoreGState()

    if showSlots {
        ctx.setBlendMode(.clear)
        ctx.addPath(binSlots())
        ctx.fillPath()
        ctx.setBlendMode(.normal)
    }

    for square in loose where square.alpha >= minimumAlpha {
        let radius = square.rect.width * 0.22
        ctx.addPath(CGPath(roundedRect: square.rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(glyph.copy(alpha: square.alpha)!)
        ctx.fillPath()
    }

    // A faint cool shade toward the bottom gives the white some depth.
    ctx.setBlendMode(.sourceAtop)
    let shade = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0), glyphShade] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(shade, start: CGPoint(x: 0, y: 300), end: CGPoint(x: 0, y: 780), options: [])

    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

func render(size: Int, fullBleed: Bool) -> CGImage {
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    // Flip to y-down design units; full bleed maps the tile onto the whole canvas.
    let scale = CGFloat(size) / (fullBleed ? tile.width : 1024)
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: scale, y: -scale)
    if fullBleed {
        ctx.translateBy(x: -tile.minX, y: -tile.minY)
    }
    drawTile(ctx, fullBleed: fullBleed, pixelSize: CGFloat(size))
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(url.path)") }
}

// MARK: - Output

func findRoot() -> URL {
    var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    for _ in 0..<6 {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            return url
        }
        url.deleteLastPathComponent()
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}

let root = findRoot()
let resources = root.appendingPathComponent("Resources")
let assets = root.appendingPathComponent("Sources/GoAway/Assets")
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

writePNG(render(size: 1024, fullBleed: false), to: resources.appendingPathComponent("AppIcon.png"))
writePNG(render(size: 512, fullBleed: true), to: assets.appendingPathComponent("AppLogo.png"))

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("GoAway.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    writePNG(render(size: points, fullBleed: false), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(render(size: points * 2, fullBleed: false), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let icns = resources.appendingPathComponent("AppIcon.icns")
try? FileManager.default.removeItem(at: icns)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed (\(iconutil.terminationStatus))") }
try? FileManager.default.removeItem(at: iconset)
print("Wrote AppIcon.icns, AppIcon.png and AppLogo.png")
