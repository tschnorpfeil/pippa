// App icon for Pippa: the resting PippaMark (three organic rings) on a light, rounded
// macOS-style tile. No Xcode needed, only CoreGraphics/AppKit.
//
//   swift app/Packaging/make-icon.swift out.png [1024]
//   swift app/Packaging/make-icon.swift --dmg-background out.png [1280x800] [site/fonts]
//
// The rings follow the mark in site/pippaMark.js (state "resting", time 0):
// radius size·(0.34 − i·0.016), wobble 1 + 1.35·(0.035·sin(3a + i·1.2) + 0.026·sin(2a + i·0.84)),
// stroke size·0.052, opacity 1.0 / 0.6 / 0.42, color #005bcd.
import AppKit
import CoreGraphics
import CoreText
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

/// Loads a font from site/fonts (same files as the website); falls back to the system font.
func brandFont(_ fontsDir: String?, file: String, name: String, size: CGFloat) -> NSFont {
    if let dir = fontsDir {
        let url = URL(fileURLWithPath: dir).appendingPathComponent(file) as CFURL
        _ = CTFontManagerRegisterFontsForURL(url, .process, nil)  // false if already registered: fine
    }
    return NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size, weight: .bold)
}

/// DMG window in the style of the website: soft colour clouds, "Hol dir Pippa." in Bagel Fat One,
/// a hand-drawn arrow with a Gochi Hand note and sparkles at the Applications folder.
/// Coordinates are Finder points from the top-left of a 640×400 window; icons sit at (160, 190) and (480, 190).
func dmgBackground(width: Int, height: Int, fontsDir: String?) -> CGImage {
    let w = CGFloat(width), h = CGFloat(height)
    let scale = w / 640
    let ctx = makeContext(width, height)
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * scale, y: h - y * scale) }
    let ink = rgb(16, 37, 26), blue = rgb(0, 91, 205)

    ctx.setFillColor(rgb(246, 247, 243))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    // Colour clouds: radial gradients fading to transparent, like the blurred blobs on the website.
    for (x, y, r, c) in [(70, 60, 200, rgb(169, 200, 255, 0.75)), (615, 200, 190, rgb(185, 227, 195, 0.8)),
                         (350, 410, 175, rgb(255, 224, 138, 0.7)), (30, 400, 130, rgb(255, 198, 214, 0.55))] {
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                           colors: [c, c.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(g, startCenter: p(CGFloat(x), CGFloat(y)), startRadius: 0,
                               endCenter: p(CGFloat(x), CGFloat(y)), endRadius: CGFloat(r) * scale, options: [])
    }

    // Hand-drawn strokes: arrow from the app to Applications, sparkles at the folder.
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(4 * scale)
    let arrow = CGMutablePath()
    arrow.move(to: p(236, 208))
    arrow.addCurve(to: p(398, 196), control1: p(272, 186), control2: p(330, 178))
    arrow.move(to: p(376, 180))
    arrow.addCurve(to: p(400, 197), control1: p(386, 186), control2: p(393, 191))
    arrow.addCurve(to: p(373, 214), control1: p(391, 201), control2: p(383, 206))
    for (path, color) in [(arrow as CGPath, ink), (line(p(548, 112), p(551, 129)), ink),
                          (line(p(578, 112), p(568, 132)), blue), (line(p(584, 152), p(600, 149)), ink)] as [(CGPath, CGColor)] {
        ctx.setStrokeColor(color)
        ctx.addPath(path)
        ctx.strokePath()
    }

    // Name tags under the icons. The background is the same in light and dark mode, while Finder may draw
    // the names black or white: a mid blue keeps either readable (about 4.5:1).
    ctx.setFillColor(rgb(61, 118, 204))
    for (x, width) in [(160, 56), (480, 92)] as [(CGFloat, CGFloat)] {
        let tag = CGRect(x: (x - width / 2) * scale, y: h - 270 * scale, width: width * scale, height: 19 * scale)
        ctx.addPath(CGPath(roundedRect: tag, cornerWidth: 6 * scale, cornerHeight: 6 * scale, transform: nil))
        ctx.fillPath()
    }

    // Text via NSGraphicsContext (works without a window/screen).
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let bagel = brandFont(fontsDir, file: "bagel-fat-one.ttf", name: "BagelFatOne-Regular", size: 34 * scale)
    let headline = NSMutableAttributedString(string: "Hol dir ", attributes: [.font: bagel, .foregroundColor: NSColor(cgColor: ink)!])
    headline.append(NSAttributedString(string: "Pippa", attributes: [.font: bagel, .foregroundColor: NSColor(cgColor: blue)!]))
    let size = headline.size()
    let ring = 12 * scale
    let left = (w - size.width - ring - 3 * scale) / 2
    let bottom = h - 30 * scale - size.height
    headline.draw(at: CGPoint(x: left, y: bottom))
    // The full stop is the Pippa ring, as in the website's logo.
    ctx.setStrokeColor(blue)
    ctx.setLineWidth(3 * scale)
    let baseline = bottom - bagel.descender
    ctx.strokeEllipse(in: CGRect(x: left + size.width + 3 * scale + 1.5 * scale, y: baseline + 1.5 * scale,
                                 width: ring - 3 * scale, height: ring - 3 * scale))

    let gochi = { (pt: CGFloat) in brandFont(fontsDir, file: "gochi-hand.ttf", name: "GochiHand-Regular", size: pt * scale) }
    ctx.saveGState()
    ctx.translateBy(x: 262 * scale, y: h - 160 * scale)
    ctx.rotate(by: 5 * .pi / 180)
    NSAttributedString(string: "zieh mich rüber!", attributes: [.font: gochi(21), .foregroundColor: NSColor(cgColor: blue)!])
        .draw(at: .zero)
    ctx.restoreGState()

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    NSAttributedString(string: "Danach öffnen. Alles bleibt auf deinem Mac.", attributes: [
        .font: gochi(17), .foregroundColor: NSColor(srgbRed: 0.30, green: 0.35, blue: 0.32, alpha: 1),
        .paragraphStyle: paragraph,
    ]).draw(in: CGRect(x: 0, y: h - 372 * scale, width: w, height: 30 * scale))
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

func line(_ a: CGPoint, _ b: CGPoint) -> CGPath {
    let path = CGMutablePath()
    path.move(to: a)
    path.addLine(to: b)
    return path
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
    guard let out = args.first else { fatalError("Aufruf: make-icon.swift --dmg-background out.png [1280x800] [fonts-dir]") }
    let dims = (args.count > 1 ? args[1] : "1280x800").split(separator: "x").compactMap { Int($0) }
    writePNG(dmgBackground(width: dims[0], height: dims[1], fontsDir: args.count > 2 ? args[2] : nil), to: out)
} else {
    guard let out = args.first else { fatalError("Aufruf: make-icon.swift out.png [1024]") }
    let size = args.count > 1 ? Int(args[1]) ?? 1024 : 1024
    writePNG(icon(size: size), to: out)
}
