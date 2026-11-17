// Renders the website's social preview images, site/og.jpg (German) and site/og-en.jpg (English).
//
// Built to be read as a small card in a feed: Pippa-blue so it stands out among white previews; on the left her icon,
// name, the page's headline in Bagel Fat One and "free for Mac"; on the right Pippa Island hanging from the top edge
// with one finished answer, drawn large enough to read at half size. Island text, colors and proportions follow
// IslandViews.swift; the sample data is the website's made-up letter.
//
//   swift scripts/render-og.swift
//
// AppKit only, no packages. Output: 1200×630 JPEG, each under 150 KB.
import AppKit
import CoreText

let width: CGFloat = 1200, height: CGFloat = 630
let maxBytes = 150_000
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

var registerError: Unmanaged<CFError>?
let fontURL = root.appendingPathComponent("site/fonts/bagel-fat-one.ttf")
guard CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &registerError),
      let icon = NSImage(contentsOf: root.appendingPathComponent("site/icon-512.png")) else {
    FileHandle.standardError.write(Data("Could not load the font or site/icon-512.png\n".utf8))
    exit(1)
}

struct Page {
    var output: String
    var headline: [String]
    var tagline: String
    var cta: String
    /// The answer in runs: (text, bold).
    var answer: [(String, Bool)]
    var question: String
    var file: String
    var cardTitle: String
    var cardDetail: String
    var field: String
}

let pages = [
    Page(output: "site/og.jpg", headline: ["Die KI-Assistentin,", "die wirklich", "was erledigt."],
         tagline: "Kostenlos für den Mac.\nDie KI läuft auf deinem Mac.", cta: "heypippa.app",
         answer: [("Die Nachzahlung von ", false), ("184,37 €", true), (" musst du ", false), ("bis zum 15. November", true), (" überweisen.", false)],
         question: "Bis wann muss ich hier etwas tun?", file: "Brief-Stadtwerke.pdf", cardTitle: "Erinnerung angelegt", cardDetail: "Nachzahlung überweisen · 14. Nov.", field: "Pippa fragen …"),
    Page(output: "site/og-en.jpg", headline: ["The AI assistant", "that actually", "gets things done."],
         tagline: "Free for Mac.\nThe AI runs on your Mac.", cta: "heypippa.app/en",
         answer: [("Your back payment of ", false), ("€184.37", true), (" is due ", false), ("by November 15", true), (".", false)],
         question: "By when do I need to do something?", file: "Letter-utility.pdf", cardTitle: "Reminder added", cardDetail: "Pay the back payment · Nov 14", field: "Ask Pippa…"),
]

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}
let accent = rgb(0x005bcd), deep = rgb(0x0a3d91), white = NSColor.white

func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: size) ?? base
}
func bagel(_ size: CGFloat) -> NSFont { NSFont(name: "BagelFatOne-Regular", size: size)! }

/// Draws text with its first baseline at `top - ascender`, wrapped to `width`; returns the height used.
@discardableResult
func draw(_ text: NSAttributedString, x: CGFloat, top: CGFloat, width: CGFloat) -> CGFloat {
    let bounds = text.boundingRect(with: NSSize(width: width, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading])
    text.draw(with: NSRect(x: x, y: top - bounds.height, width: width, height: bounds.height), options: [.usesLineFragmentOrigin, .usesFontLeading])
    return bounds.height
}

func paragraph(_ lineHeight: CGFloat) -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.minimumLineHeight = lineHeight; style.maximumLineHeight = lineHeight
    return style
}

/// Pippa's mark as on the island: a blue ring.
func ring(center: NSPoint, radius: CGFloat, lineWidth: CGFloat) {
    let path = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    path.lineWidth = lineWidth
    rgb(0x7fb2ff).setStroke()
    path.stroke()
}

func render(_ page: Page) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    // Background: Pippa blue, lighter toward the top right where the island hangs.
    NSGradient(starting: accent, ending: deep)!.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -60)
    NSGradient(colors: [white.withAlphaComponent(0.20), white.withAlphaComponent(0)], atLocations: [0, 1], colorSpace: .sRGB)!
        .draw(fromCenter: NSPoint(x: 900, y: 600), radius: 0, toCenter: NSPoint(x: 900, y: 600), radius: 560, options: [])

    // Left: icon and name.
    let left: CGFloat = 64
    let iconSize: CGFloat = 64
    NSGraphicsContext.saveGraphicsState()
    let iconShadow = NSShadow(); iconShadow.shadowColor = rgb(0x041a40, 0.35); iconShadow.shadowBlurRadius = 14; iconShadow.shadowOffset = NSSize(width: 0, height: -4)
    iconShadow.set()
    icon.draw(in: NSRect(x: left, y: height - 60 - iconSize, width: iconSize, height: iconSize))
    NSGraphicsContext.restoreGraphicsState()
    let name = NSAttributedString(string: "Pippa", attributes: [.font: bagel(44), .foregroundColor: white])
    name.draw(at: NSPoint(x: left + iconSize + 16, y: height - 60 - iconSize + 6))

    // Headline: the largest Bagel size at which every line fits the column.
    let column: CGFloat = 540
    var size: CGFloat = 60
    while size > 36, !page.headline.allSatisfy({ ($0 as NSString).size(withAttributes: [.font: bagel(size)]).width <= column }) { size -= 1 }
    let headline = NSAttributedString(string: page.headline.joined(separator: "\n"),
                                      attributes: [.font: bagel(size), .foregroundColor: white, .paragraphStyle: paragraph(size * 1.04)])
    let headlineTop = height - 172
    let used = draw(headline, x: left, top: headlineTop, width: column + 40)

    // Tagline.
    let tagline = NSAttributedString(string: page.tagline, attributes: [.font: rounded(25, .semibold), .foregroundColor: white.withAlphaComponent(0.88),
                                                                         .paragraphStyle: paragraph(33)])
    draw(tagline, x: left, top: headlineTop - used - 22, width: column)

    // Address pill, bottom left.
    let cta = NSAttributedString(string: page.cta, attributes: [.font: rounded(24, .bold), .foregroundColor: accent])
    let ctaSize = cta.size()
    let pill = NSRect(x: left, y: 56, width: ctaSize.width + 44, height: 52)
    white.setFill(); NSBezierPath(roundedRect: pill, xRadius: 26, yRadius: 26).fill()
    cta.draw(at: NSPoint(x: pill.minX + 22, y: pill.midY - ctaSize.height / 2))

    // Right: Pippa Island hanging from the top edge, black like the notch, as tall as its content.
    let answer = NSMutableAttributedString()
    for (text, bold) in page.answer {
        answer.append(NSAttributedString(string: text, attributes: [.font: rounded(29, bold ? .bold : .regular),
                                                                    .foregroundColor: white.withAlphaComponent(bold ? 1 : 0.9),
                                                                    .paragraphStyle: paragraph(39)]))
    }
    let answerHeight = answer.boundingRect(with: NSSize(width: 500 - 72, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading]).height
    let contentHeight = 34 + 58 + 44 + 70 + answerHeight + 22 + 102 + 54 + 34
    let island = NSRect(x: 650, y: height - contentHeight, width: 500, height: contentHeight + 40)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = rgb(0x020c22, 0.55); shadow.shadowBlurRadius = 40; shadow.shadowOffset = NSSize(width: 0, height: -16)
    shadow.set()
    NSColor.black.setFill(); NSBezierPath(roundedRect: island, xRadius: 44, yRadius: 44).fill()
    NSGraphicsContext.restoreGraphicsState()
    let inner = island.minX + 36, innerWidth = island.width - 72
    var y = height - 34

    // Header: ring and name.
    ring(center: NSPoint(x: inner + 14, y: y - 18), radius: 12, lineWidth: 4.5)
    NSAttributedString(string: "Pippa", attributes: [.font: rounded(25, .bold), .foregroundColor: white]).draw(at: NSPoint(x: inner + 38, y: y - 33))
    y -= 58

    // The question, right-aligned like the person's message, with the letter attached.
    let question = NSAttributedString(string: page.question, attributes: [.font: rounded(21, .medium), .foregroundColor: white])
    let qSize = question.size()
    let bubble = NSRect(x: island.maxX - 36 - qSize.width - 36, y: y - 46, width: qSize.width + 36, height: 46)
    let fileText = NSAttributedString(string: page.file, attributes: [.font: rounded(18, .medium), .foregroundColor: white.withAlphaComponent(0.7)])
    let fSize = fileText.size()
    let chip = NSRect(x: island.maxX - 36 - fSize.width - 50, y: y - 34, width: fSize.width + 50, height: 34)
    white.withAlphaComponent(0.25).setStroke()
    let chipPath = NSBezierPath(roundedRect: chip, xRadius: 10, yRadius: 10); chipPath.lineWidth = 1.5; chipPath.stroke()
    let doc = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)!
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .medium).applying(.init(paletteColors: [white.withAlphaComponent(0.7)])))!
    doc.draw(in: NSRect(x: chip.minX + 13, y: chip.midY - doc.size.height / 2, width: doc.size.width, height: doc.size.height))
    fileText.draw(at: NSPoint(x: chip.minX + 37, y: chip.midY - fSize.height / 2))
    y = chip.minY - 10
    let bubbleRect = NSRect(x: bubble.minX, y: y - 46, width: bubble.width, height: 46)
    white.withAlphaComponent(0.16).setFill(); NSBezierPath(roundedRect: bubbleRect, xRadius: 23, yRadius: 23).fill()
    question.draw(at: NSPoint(x: bubbleRect.minX + 18, y: bubbleRect.midY - qSize.height / 2))
    y = bubbleRect.minY - 24

    // The answer.
    y -= draw(answer, x: inner, top: y, width: innerWidth) + 22

    // The reminder card, as the chat shows it.
    let card = NSRect(x: inner, y: y - 82, width: innerWidth, height: 82)
    white.withAlphaComponent(0.09).setFill(); NSBezierPath(roundedRect: card, xRadius: 18, yRadius: 18).fill()
    let badge = NSRect(x: card.minX + 18, y: card.midY - 21, width: 42, height: 42)
    rgb(0x2fbf62).setFill(); NSBezierPath(roundedRect: badge, xRadius: 11, yRadius: 11).fill()
    let check = NSBezierPath()
    check.move(to: NSPoint(x: badge.minX + 11, y: badge.midY + 1)); check.line(to: NSPoint(x: badge.minX + 18, y: badge.midY - 7))
    check.line(to: NSPoint(x: badge.maxX - 10, y: badge.midY + 8))
    check.lineWidth = 4.5; check.lineCapStyle = .round; check.lineJoinStyle = .round; white.setStroke(); check.stroke()
    NSAttributedString(string: page.cardTitle, attributes: [.font: rounded(23, .bold), .foregroundColor: white])
        .draw(at: NSPoint(x: badge.maxX + 16, y: card.midY + 1))
    NSAttributedString(string: page.cardDetail, attributes: [.font: rounded(20, .regular), .foregroundColor: white.withAlphaComponent(0.66)])
        .draw(at: NSPoint(x: badge.maxX + 16, y: card.midY - 27))
    y = card.minY - 20

    // The question field.
    let field = NSRect(x: inner, y: y - 54, width: innerWidth, height: 54)
    white.withAlphaComponent(0.11).setFill(); NSBezierPath(roundedRect: field, xRadius: 27, yRadius: 27).fill()
    let prompt = NSAttributedString(string: page.field, attributes: [.font: rounded(22, .regular), .foregroundColor: white.withAlphaComponent(0.55)])
    prompt.draw(at: NSPoint(x: field.minX + 22, y: field.midY - prompt.size().height / 2))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// JPEG at the highest quality that stays under the size limit.
func jpeg(_ rep: NSBitmapImageRep) -> Data {
    var quality = 0.92
    while true {
        let data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality])!
        if data.count < maxBytes || quality <= 0.4 { return data }
        quality -= 0.04
    }
}

let outputRoot = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true) : root
for page in pages {
    let data = jpeg(render(page))
    let output = outputRoot.appendingPathComponent(page.output)
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: output)
    print("\(page.output): \(Int(width))×\(Int(height)), \(data.count / 1024) KB")
}
