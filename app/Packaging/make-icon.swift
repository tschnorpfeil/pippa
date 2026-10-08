// App icon for Pippa: the resting PippaMark (three organic rings) on a light, rounded
// macOS-style tile. No Xcode needed, only CoreGraphics/AppKit.
//
//   swift app/Packaging/make-icon.swift out.png [1024]
//   swift app/Packaging/make-icon.swift --dmg-background out.png [1280x800]
//
// The rings follow the mark in site/pippaMark.js (state "resting", time 0):
// radius size·(0.34 − i·0.016), wobble 1 + 1.35·(0.035·sin(3a + i·1.2) + 0.026·sin(2a + i·0.84)),
// stroke size·0.052, opacity 1.0 / 0.6 / 0.42, color #005bcd.
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let ink = CGColor(srgbRed: 0x00 / 255.0, green: 0x5b / 255.0, blue: 0xcd / 255.0, alpha: 1)
let strands: [CGFloat] = [1.0, 0.6, 0.42]

func wobble(_ angle: CGFloat, _ strand: Int) -> CGFloat {
    let s = CGFloat(strand)
    return 1 + 1.35 * (0.035 * sin(3 * angle + s * 1.2) + 0.026 * sin(2 * angle + s * 1.2 * 0.7))
}

/// Draws the mark into a square of edge length `size` around `center`.
func drawMark(_ ctx: CGContext, center: CGPoint, size: CGFloat, glow: Bool = true) {
    let segments = 360
    for (strand, alpha) in strands.enumerated() {
        let radius = size * (0.34 - CGFloat(strand) * 0.016)
        let path = CGMutablePath()
        for i in 0...(segments + 4) {  // slightly overlapping: no seam at the start point
            let a = CGFloat(i) / CGFloat(segments) * 2 * .pi
            let r = radius * wobble(a, strand)
            // y points up (CoreGraphics), hence −sin: same shape as in the canvas.
            let p = CGPoint(x: center.x + r * cos(a), y: center.y - r * sin(a))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        if glow {
            ctx.setShadow(offset: .zero, blur: size * 0.035 * alpha, color: ink.copy(alpha: 0.55))
        }
        // Opacity and glow apply to the whole layer: CoreGraphics splits
        // long strokes internally, so with stroke alpha the joints would look darker.
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(size * 0.052)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}

func makeContext(_ width: Int, _ height: Int) -> CGContext {
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("Kein Bitmap-Kontext")
    }
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    return ctx
}

func gray(_ v: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: v, green: v, blue: v, alpha: a) }
func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

func linearGradient(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func icon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = makeContext(size, size)
    // macOS grid: 824/1024 tile, radius ≈ 185/1024, soft shadow underneath.
    let inset = s * 100 / 1024
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = CGPath(roundedRect: rect, cornerWidth: s * 185 / 1024, cornerHeight: s * 185 / 1024, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 10 / 1024), blur: s * 22 / 1024, color: gray(0, 0.28))
    ctx.addPath(shape)
    ctx.setFillColor(gray(1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    linearGradient(ctx, [rgb(255, 255, 255), rgb(232, 239, 249)],
                   from: CGPoint(x: rect.midX, y: rect.maxY), to: CGPoint(x: rect.midX, y: rect.minY))
    // Subtle glow behind the mark.
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [rgb(0, 91, 205, 0.10), rgb(0, 91, 205, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: rect.midX, y: rect.midY), startRadius: 0,
                           endCenter: CGPoint(x: rect.midX, y: rect.midY), endRadius: rect.width * 0.48, options: [])
    ctx.restoreGState()

    // Fine edge so the light tile stands out on a light background.
    ctx.addPath(shape)
    ctx.setStrokeColor(gray(0, 0.08))
    ctx.setLineWidth(max(1, s / 512))
    ctx.strokePath()

    drawMark(ctx, center: CGPoint(x: rect.midX, y: rect.midY), size: rect.width * 0.86, glow: size >= 64)
    return ctx.makeImage()!
}

func dmgBackground(width: Int, height: Int) -> CGImage {
    let w = CGFloat(width), h = CGFloat(height)
    let scale = w / 640
    let ctx = makeContext(width, height)
    linearGradient(ctx, [rgb(250, 251, 254), rgb(229, 237, 248)], from: CGPoint(x: 0, y: h), to: CGPoint(x: 0, y: 0))

    // Arrow between the app (x 160) and Applications (x 480), icon centers at y 190 (Finder, from the top).
    let y = h - 190 * scale
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: 250 * scale, y: y))
    arrow.addLine(to: CGPoint(x: 385 * scale, y: y))
    ctx.setAlpha(0.55)
    ctx.setLineWidth(6 * scale)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    arrow.move(to: CGPoint(x: 365 * scale, y: y + 18 * scale))
    arrow.addLine(to: CGPoint(x: 390 * scale, y: y))
    arrow.addLine(to: CGPoint(x: 365 * scale, y: y - 18 * scale))
    // One path, one transparency layer: no darker overlaps.
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setAlpha(1)
    ctx.setStrokeColor(rgb(0, 91, 205, 1))
    ctx.addPath(arrow)
    ctx.strokePath()
    ctx.endTransparencyLayer()
    ctx.setAlpha(1)

    // Label via NSGraphicsContext (works without a window/screen).
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let text = NSAttributedString(string: "Zieh Pippa in Programme", attributes: [
        .font: NSFont.systemFont(ofSize: 22 * scale, weight: .medium),
        .foregroundColor: NSColor(srgbRed: 0.12, green: 0.16, blue: 0.24, alpha: 0.85),
        .paragraphStyle: paragraph,
    ])
    text.draw(in: CGRect(x: 0, y: h - 330 * scale, width: w, height: 40 * scale))
    let hint = NSAttributedString(string: "Alles bleibt auf deinem Mac.", attributes: [
        .font: NSFont.systemFont(ofSize: 14 * scale, weight: .regular),
        .foregroundColor: NSColor(srgbRed: 0.12, green: 0.16, blue: 0.24, alpha: 0.55),
        .paragraphStyle: paragraph,
    ])
    hint.draw(in: CGRect(x: 0, y: h - 362 * scale, width: w, height: 28 * scale))
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Kann \(path) nicht schreiben")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("PNG fehlgeschlagen: \(path)") }
}

var args = Array(CommandLine.arguments.dropFirst())
if args.first == "--dmg-background" {
    args.removeFirst()
    guard let out = args.first else { fatalError("Aufruf: make-icon.swift --dmg-background out.png [1280x800]") }
    let dims = (args.count > 1 ? args[1] : "1280x800").split(separator: "x").compactMap { Int($0) }
    writePNG(dmgBackground(width: dims[0], height: dims[1]), to: out)
} else {
    guard let out = args.first else { fatalError("Aufruf: make-icon.swift out.png [1024]") }
    let size = args.count > 1 ? Int(args[1]) ?? 1024 : 1024
    writePNG(icon(size: size), to: out)
}
