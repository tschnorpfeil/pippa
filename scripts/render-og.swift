// Renders the website's social preview images, site/og.jpg (German) and site/og-en.jpg (English): the page's headline
// in Bagel Fat One over a real Pippa window from the live snapshots, which show made-up sample data.
//
//   swift scripts/render-og.swift <German snapshot folder> <English snapshot folder>
//
// Each folder comes from `PIPPA_SNAPSHOT_LIVE=1 Pippa --snapshot <folder>`; the German one from an app bundle started
// with `-AppleLanguages '(de)'` (see docs/development.md, "Website"). AppKit only, no packages. Output: 1200×630 JPEG,
// each under 150 KB.
import AppKit
import CoreText

let width = 1200, height = 630
let maxBytes = 150_000
let scene = "conversation-light.png"
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let fontURL = root.appendingPathComponent("site/fonts/bagel-fat-one.ttf")

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/render-og.swift <German snapshot folder> <English snapshot folder>\n".utf8))
    exit(2)
}
let folders = Array(arguments).map { URL(fileURLWithPath: $0, isDirectory: true) }

var registerError: Unmanaged<CFError>?
if !CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &registerError) {
    FileHandle.standardError.write(Data("Could not load \(fontURL.path)\n".utf8))
    exit(1)
}

let pages: [(lines: [String], snapshots: URL, output: String)] = [
    (["Die KI-Assistentin,", "die wirklich was erledigt."], folders[0], "site/og.jpg"),
    (["The AI assistant", "that actually gets things done."], folders[1], "site/og-en.jpg"),
]

let ink = NSColor(srgbRed: 0x11 / 255, green: 0x13 / 255, blue: 0x18 / 255, alpha: 1)
let accent = NSColor(srgbRed: 0, green: 0x5b / 255, blue: 0xcd / 255, alpha: 1)

/// The headline font at the largest size (up to 58 pt) at which every line fits 1080 px.
func headlineFont(for lines: [String]) -> NSFont {
    var size: CGFloat = 58
    while size > 30 {
        let font = NSFont(name: "BagelFatOne-Regular", size: size)!
        if lines.allSatisfy({ ($0 as NSString).size(withAttributes: [.font: font]).width <= 1080 }) { return font }
        size -= 1
    }
    return NSFont(name: "BagelFatOne-Regular", size: size)!
}

func render(lines: [String], window: NSImage) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let canvas = NSRect(x: 0, y: 0, width: width, height: height)

    // A white page with the soft blue light the website shows under Pippa's window.
    NSColor.white.setFill()
    canvas.fill()
    let glow = NSGradient(colors: [accent.withAlphaComponent(0.16), accent.withAlphaComponent(0.05), accent.withAlphaComponent(0)],
                          atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    glow.draw(fromCenter: NSPoint(x: 600, y: 40), radius: 0, toCenter: NSPoint(x: 600, y: 40), radius: 620, options: [])

    // The headline, centered, two lines.
    let font = headlineFont(for: lines)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
    let lineHeight = font.pointSize * 1.08
    // Baseline of the first line: the cap height sits 52 px below the top edge.
    var baseline = CGFloat(height) - 52 - font.capHeight
    for line in lines {
        let text = line as NSString
        let lineWidth = text.size(withAttributes: attributes).width
        // draw(at:) puts the point at the bottom of the line box, which is the baseline plus the descender.
        text.draw(at: NSPoint(x: (CGFloat(width) - lineWidth) / 2, y: baseline + font.descender), withAttributes: attributes)
        baseline -= lineHeight
    }

    // The window, scaled down and cut off by the bottom edge, with a soft shadow.
    let scale: CGFloat = 0.72
    let size = NSSize(width: window.size.width * scale, height: window.size.height * scale)
    let top = baseline + lineHeight + font.descender - 36
    let frame = NSRect(x: (CGFloat(width) - size.width) / 2, y: top - size.height, width: size.width, height: size.height)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(srgbRed: 22 / 255, green: 34 / 255, blue: 56 / 255, alpha: 0.28)
    shadow.shadowBlurRadius = 36
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.set()
    window.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// JPEG at the highest quality that stays under the size limit.
func jpeg(_ rep: NSBitmapImageRep) -> Data {
    var quality = 0.9
    while true {
        let data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality])!
        if data.count < maxBytes || quality <= 0.4 { return data }
        quality -= 0.04
    }
}

for page in pages {
    let file = page.snapshots.appendingPathComponent(scene)
    guard let window = NSImage(contentsOf: file) else {
        FileHandle.standardError.write(Data("Missing \(file.path); run Pippa --snapshot first.\n".utf8))
        exit(1)
    }
    let data = jpeg(render(lines: page.lines, window: window))
    let output = root.appendingPathComponent(page.output)
    try data.write(to: output)
    print("\(page.output): \(width)×\(height), \(data.count / 1024) KB")
}
