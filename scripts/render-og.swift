// Renders the website's social preview images, site/og.jpg (German) and site/og-en.jpg (English).
//
// Matches the redesigned website's palette and typography: warm paper on the left with Pippa's icon, name,
// two-line SF Pro headline ("Dein Papierkram. Auf deinem Mac."), concise summary and footer line; on the right
// Pippa Island in deep obsidian hanging from the top edge with one finished answer, receipt card and Undo cue,
// sized to stay crisp at 500 px feed width. Sample data is the website's made-up utility letter.
//
//   swift scripts/render-og.swift
//
// AppKit only, no packages. Output: 1200×630 JPEG, each under 150 KB.
import AppKit

let width: CGFloat = 1200, height: CGFloat = 630
let maxBytes = 150_000
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

guard let icon = NSImage(contentsOf: root.appendingPathComponent("site/icon-512.png")) else {
    FileHandle.standardError.write(Data("Could not load site/icon-512.png\n".utf8))
    exit(1)
}

struct Page {
    var output: String
    var headlineTop: String
    var headlineAccent: String
    var lede: String
    var badge: String
    var domain: String
    var localTag: String
    /// The answer in runs: (text, bold).
    var answer: [(String, Bool)]
    var question: String
    var file: String
    var cardTitle: String
    var cardDetail: String
    var undoLabel: String
    var field: String
}

let pages = [
    Page(
        output: "site/og.jpg",
        headlineTop: "Dein Papierkram.",
        headlineAccent: "Auf deinem Mac.",
        lede: "Briefe erklärt samt Frist, Fotos als ein PDF,\nAntworten in Mail. Ohne Konto.",
        badge: "Kostenlos für den Mac",
        domain: "heypippa.app",
        localTag: "Auf diesem Mac",
        answer: [
            ("Die Nachzahlung von ", false), ("184,37 €", true), (" musst du ", false),
            ("bis zum 15. November", true), (" überweisen.", false),
        ],
        question: "Bis wann muss ich hier etwas tun?",
        file: "Brief-Stadtwerke.pdf",
        cardTitle: "Erinnerung angelegt",
        cardDetail: "Nachzahlung · 14. Nov.",
        undoLabel: "Rückgängig",
        field: "Pippa fragen …"
    ),
    Page(
        output: "site/og-en.jpg",
        headlineTop: "Your paperwork.",
        headlineAccent: "On your Mac.",
        lede: "Letters with deadlines, photos into one PDF,\ndrafts in Mail. With no account.",
        badge: "Free for Mac",
        domain: "heypippa.app/en",
        localTag: "On this Mac",
        answer: [
            ("Your back payment of ", false), ("€184.37", true), (" is due ", false),
            ("by November 15", true), (".", false),
        ],
        question: "By when do I need to do something?",
        file: "Letter-utility.pdf",
        cardTitle: "Reminder added",
        cardDetail: "Pay back payment · Nov 14",
        undoLabel: "Undo",
        field: "Ask Pippa…"
    ),
]

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat(hex >> 16 & 0xff) / 255,
        green: CGFloat(hex >> 8 & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

// Website tokens mapped to sRGB.
let paperTop = rgb(0xFAF8F4)
let paperBottom = rgb(0xF3EFE8)
let ink = rgb(0x181C24)
let inkMuted = rgb(0x49515E)
let ruleColor = rgb(0xD8D3C9)
let accent = rgb(0x005BCD)
let okGreen = rgb(0x0D712C)
let okWash = rgb(0xE4F2E8)
let islandBg = rgb(0x0E1116)
let islandSky = rgb(0x6FA8FF)
let islandOk = rgb(0x22A759)
let white = NSColor.white

func uiFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    NSFont.systemFont(ofSize: size, weight: weight)
}

func paragraph(_ lineHeight: CGFloat, alignment: NSTextAlignment = .left) -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.minimumLineHeight = lineHeight
    style.maximumLineHeight = lineHeight
    style.alignment = alignment
    return style
}

/// Draws text with its top edge at `top`, wrapped to `width`; returns the height used.
@discardableResult
func draw(_ text: NSAttributedString, x: CGFloat, top: CGFloat, width: CGFloat) -> CGFloat {
    let bounds = text.boundingRect(
        with: NSSize(width: width, height: 1000),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    text.draw(
        with: NSRect(x: x, y: top - bounds.height, width: width, height: bounds.height),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    return bounds.height
}

/// Pippa's two-ring mark as on the website and Island.
func drawPippaRings(center: NSPoint, radius: CGFloat, lineWidth: CGFloat) {
    let back = NSBezierPath(ovalIn: NSRect(
        x: center.x - radius * 0.94 + 1.8,
        y: center.y - radius * 1.02 + 1.2,
        width: radius * 1.88,
        height: radius * 2.04
    ))
    back.lineWidth = lineWidth
    islandSky.withAlphaComponent(0.45).setStroke()
    back.stroke()

    let front = NSBezierPath(ovalIn: NSRect(
        x: center.x - radius,
        y: center.y - radius * 0.95,
        width: radius * 2.0,
        height: radius * 1.90
    ))
    front.lineWidth = lineWidth
    islandSky.setStroke()
    front.stroke()
}

func render(_ page: Page) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(width),
        pixelsHigh: Int(height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    // Background: Pippa warm paper with a quiet top-to-bottom shift.
    NSGradient(starting: paperTop, ending: paperBottom)!
        .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

    // Left column geometry.
    let left: CGFloat = 68
    let column: CGFloat = 532

    // Brand lockup (top left): app icon + "Pippa".
    let iconSize: CGFloat = 54
    let brandY = height - 56 - iconSize
    NSGraphicsContext.saveGraphicsState()
    let iconShadow = NSShadow()
    iconShadow.shadowColor = rgb(0x141A26, 0.16)
    iconShadow.shadowBlurRadius = 14
    iconShadow.shadowOffset = NSSize(width: 0, height: -4)
    iconShadow.set()
    icon.draw(in: NSRect(x: left, y: brandY, width: iconSize, height: iconSize))
    NSGraphicsContext.restoreGraphicsState()

    let brandName = NSAttributedString(
        string: "Pippa",
        attributes: [
            .font: uiFont(32, .bold),
            .foregroundColor: ink,
            .kern: -0.7,
        ]
    )
    brandName.draw(at: NSPoint(x: left + iconSize + 15, y: brandY + (iconSize - brandName.size().height) / 2))

    // Two-line SF Pro headline: deep slate ink + Pippa brand blue.
    var headlineSize: CGFloat = 62
    while headlineSize > 42 {
        let attrs: [NSAttributedString.Key: Any] = [.font: uiFont(headlineSize, .bold), .kern: -headlineSize * 0.03]
        let w1 = (page.headlineTop as NSString).size(withAttributes: attrs).width
        let w2 = (page.headlineAccent as NSString).size(withAttributes: attrs).width
        if w1 <= column && w2 <= column { break }
        headlineSize -= 1
    }
    let lineHeight = headlineSize * 1.07
    let headline = NSMutableAttributedString()
    headline.append(NSAttributedString(
        string: page.headlineTop + "\n",
        attributes: [
            .font: uiFont(headlineSize, .bold),
            .foregroundColor: ink,
            .kern: -headlineSize * 0.03,
            .paragraphStyle: paragraph(lineHeight),
        ]
    ))
    headline.append(NSAttributedString(
        string: page.headlineAccent,
        attributes: [
            .font: uiFont(headlineSize, .bold),
            .foregroundColor: accent,
            .kern: -headlineSize * 0.03,
            .paragraphStyle: paragraph(lineHeight),
        ]
    ))
    let headlineTop = height - 194
    let usedHeadline = draw(headline, x: left, top: headlineTop, width: column + 16)

    // Lede copy below headline.
    let lede = NSAttributedString(
        string: page.lede,
        attributes: [
            .font: uiFont(22.5, .regular),
            .foregroundColor: inkMuted,
            .kern: -0.2,
            .paragraphStyle: paragraph(33),
        ]
    )
    draw(lede, x: left, top: headlineTop - usedHeadline - 24, width: column)

    // Quiet architectural footer bar: hairline rule, free-for-Mac cue, domain.
    let footerRuleY: CGFloat = 104
    let rule = NSBezierPath()
    rule.move(to: NSPoint(x: left, y: footerRuleY))
    rule.line(to: NSPoint(x: left + column - 12, y: footerRuleY))
    rule.lineWidth = 1.25
    ruleColor.setStroke()
    rule.stroke()

    let footerMidY: CGFloat = 68
    let checkCircle = NSRect(x: left, y: footerMidY - 12, width: 24, height: 24)
    okWash.setFill()
    NSBezierPath(ovalIn: checkCircle).fill()
    let tinyCheck = NSBezierPath()
    tinyCheck.move(to: NSPoint(x: checkCircle.minX + 6.5, y: checkCircle.midY + 0.5))
    tinyCheck.line(to: NSPoint(x: checkCircle.minX + 10.5, y: checkCircle.midY - 3.8))
    tinyCheck.line(to: NSPoint(x: checkCircle.maxX - 6.0, y: checkCircle.midY + 4.5))
    tinyCheck.lineWidth = 2.4
    tinyCheck.lineCapStyle = .round
    tinyCheck.lineJoinStyle = .round
    okGreen.setStroke()
    tinyCheck.stroke()

    let badgeAttr = NSAttributedString(
        string: page.badge,
        attributes: [.font: uiFont(19.5, .medium), .foregroundColor: ink, .kern: -0.2]
    )
    badgeAttr.draw(at: NSPoint(x: checkCircle.maxX + 10, y: footerMidY - badgeAttr.size().height / 2))

    let domainAttr = NSAttributedString(
        string: page.domain,
        attributes: [.font: uiFont(19.5, .semibold), .foregroundColor: accent, .kern: -0.2]
    )
    let domainSize = domainAttr.size()
    domainAttr.draw(at: NSPoint(x: left + column - 12 - domainSize.width, y: footerMidY - domainSize.height / 2))

    // Right: Pippa Island hanging flush from the top edge like a MacBook notch.
    let islandX: CGFloat = 640
    let islandWidth: CGFloat = 508
    let pad: CGFloat = 34
    let innerX = islandX + pad
    let innerW = islandWidth - pad * 2

    let answer = NSMutableAttributedString()
    for (text, bold) in page.answer {
        answer.append(NSAttributedString(
            string: text,
            attributes: [
                .font: uiFont(26.5, bold ? .semibold : .regular),
                .foregroundColor: white.withAlphaComponent(bold ? 0.98 : 0.84),
                .kern: -0.25,
                .paragraphStyle: paragraph(36),
            ]
        ))
    }
    let answerHeight = answer.boundingRect(
        with: NSSize(width: innerW, height: 1000),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
    ).height

    // Exact content height so bottom breathing room stays tight and balanced.
    let contentHeight: CGFloat = 32 + 56 + 36 + 10 + 44 + 24 + answerHeight + 22 + 80 + 18 + 50 + 32
    let islandRect = NSRect(x: islandX, y: height - contentHeight, width: islandWidth, height: contentHeight + 46)

    // Layered shadow for realistic depth on warm paper.
    NSGraphicsContext.saveGraphicsState()
    let deepShadow = NSShadow()
    deepShadow.shadowColor = rgb(0x101520, 0.28)
    deepShadow.shadowBlurRadius = 46
    deepShadow.shadowOffset = NSSize(width: 0, height: -16)
    deepShadow.set()
    islandBg.setFill()
    NSBezierPath(roundedRect: islandRect, xRadius: 40, yRadius: 40).fill()
    NSGraphicsContext.restoreGraphicsState()

    // Crisp dark rim highlight inside the Island edge.
    let rimPath = NSBezierPath(roundedRect: islandRect.insetBy(dx: 0.75, dy: 0.75), xRadius: 39.25, yRadius: 39.25)
    rimPath.lineWidth = 1.2
    white.withAlphaComponent(0.11).setStroke()
    rimPath.stroke()

    var y = height - 32

    // Island header: two-ring Pippa mark, "Pippa", and quiet "On this Mac" status pill.
    drawPippaRings(center: NSPoint(x: innerX + 13, y: y - 16), radius: 10.5, lineWidth: 3.1)
    let islandTitle = NSAttributedString(
        string: "Pippa",
        attributes: [.font: uiFont(22, .semibold), .foregroundColor: white, .kern: -0.3]
    )
    islandTitle.draw(at: NSPoint(x: innerX + 34, y: y - 16 - islandTitle.size().height / 2))

    let localAttr = NSAttributedString(
        string: page.localTag,
        attributes: [.font: uiFont(14.5, .medium), .foregroundColor: white.withAlphaComponent(0.62)]
    )
    let localSize = localAttr.size()
    let localPill = NSRect(
        x: islandRect.maxX - pad - localSize.width - 22,
        y: y - 16 - 14,
        width: localSize.width + 22,
        height: 28
    )
    white.withAlphaComponent(0.08).setFill()
    NSBezierPath(roundedRect: localPill, xRadius: 14, yRadius: 14).fill()
    localAttr.draw(at: NSPoint(x: localPill.minX + 11, y: localPill.midY - localSize.height / 2))
    y -= 56

    // Attached letter chip (right-aligned).
    let fileAttr = NSAttributedString(
        string: page.file,
        attributes: [.font: uiFont(16.5, .medium), .foregroundColor: white.withAlphaComponent(0.76)]
    )
    let fSize = fileAttr.size()
    let chipW = fSize.width + 46
    let chip = NSRect(x: islandRect.maxX - pad - chipW, y: y - 34, width: chipW, height: 34)
    white.withAlphaComponent(0.06).setFill()
    NSBezierPath(roundedRect: chip, xRadius: 10, yRadius: 10).fill()
    let chipBorder = NSBezierPath(roundedRect: chip, xRadius: 10, yRadius: 10)
    chipBorder.lineWidth = 1.1
    white.withAlphaComponent(0.18).setStroke()
    chipBorder.stroke()

    if let doc = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)?
        .withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
                .applying(.init(paletteColors: [islandSky]))
        ) {
        doc.draw(in: NSRect(x: chip.minX + 12, y: chip.midY - doc.size.height / 2, width: doc.size.width, height: doc.size.height))
    }
    fileAttr.draw(at: NSPoint(x: chip.minX + 34, y: chip.midY - fSize.height / 2))
    y = chip.minY - 10

    // User question bubble (right-aligned).
    let qAttr = NSAttributedString(
        string: page.question,
        attributes: [.font: uiFont(19.5, .medium), .foregroundColor: white.withAlphaComponent(0.95), .kern: -0.15]
    )
    let qSize = qAttr.size()
    let bubble = NSRect(
        x: islandRect.maxX - pad - qSize.width - 34,
        y: y - 44,
        width: qSize.width + 34,
        height: 44
    )
    white.withAlphaComponent(0.14).setFill()
    NSBezierPath(roundedRect: bubble, xRadius: 22, yRadius: 22).fill()
    qAttr.draw(at: NSPoint(x: bubble.minX + 17, y: bubble.midY - qSize.height / 2))
    y = bubble.minY - 24

    // Answer block.
    y -= draw(answer, x: innerX, top: y, width: innerW) + 22

    // Receipt card with green check badge and Undo button.
    let card = NSRect(x: innerX, y: y - 80, width: innerW, height: 80)
    white.withAlphaComponent(0.08).setFill()
    NSBezierPath(roundedRect: card, xRadius: 18, yRadius: 18).fill()
    let cardBorder = NSBezierPath(roundedRect: card, xRadius: 18, yRadius: 18)
    cardBorder.lineWidth = 1.0
    white.withAlphaComponent(0.10).setStroke()
    cardBorder.stroke()

    let badgeRect = NSRect(x: card.minX + 16, y: card.midY - 20, width: 40, height: 40)
    islandOk.setFill()
    NSBezierPath(roundedRect: badgeRect, xRadius: 11, yRadius: 11).fill()
    let check = NSBezierPath()
    check.move(to: NSPoint(x: badgeRect.minX + 10.5, y: badgeRect.midY + 0.5))
    check.line(to: NSPoint(x: badgeRect.minX + 17, y: badgeRect.midY - 6.5))
    check.line(to: NSPoint(x: badgeRect.maxX - 9.5, y: badgeRect.midY + 7.5))
    check.lineWidth = 3.8
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    white.setStroke()
    check.stroke()

    let cardTitleAttr = NSAttributedString(
        string: page.cardTitle,
        attributes: [.font: uiFont(19.5, .semibold), .foregroundColor: white, .kern: -0.2]
    )
    cardTitleAttr.draw(at: NSPoint(x: badgeRect.maxX + 14, y: card.midY + 2))

    let cardDetailAttr = NSAttributedString(
        string: page.cardDetail,
        attributes: [.font: uiFont(16.5, .regular), .foregroundColor: white.withAlphaComponent(0.62)]
    )
    cardDetailAttr.draw(at: NSPoint(x: badgeRect.maxX + 14, y: card.midY - 24))

    // Undo pill inside receipt card (signature Pippa control).
    let undoAttr = NSAttributedString(
        string: page.undoLabel,
        attributes: [.font: uiFont(14.5, .medium), .foregroundColor: white.withAlphaComponent(0.84)]
    )
    let undoSize = undoAttr.size()
    let undoPill = NSRect(
        x: card.maxX - 16 - undoSize.width - 22,
        y: card.midY - 15,
        width: undoSize.width + 22,
        height: 30
    )
    white.withAlphaComponent(0.11).setFill()
    NSBezierPath(roundedRect: undoPill, xRadius: 15, yRadius: 15).fill()
    undoAttr.draw(at: NSPoint(x: undoPill.minX + 11, y: undoPill.midY - undoSize.height / 2))
    y = card.minY - 18

    // Input field with send arrow button.
    let field = NSRect(x: innerX, y: y - 50, width: innerW, height: 50)
    white.withAlphaComponent(0.09).setFill()
    NSBezierPath(roundedRect: field, xRadius: 25, yRadius: 25).fill()
    let fieldBorder = NSBezierPath(roundedRect: field, xRadius: 25, yRadius: 25)
    fieldBorder.lineWidth = 1.0
    white.withAlphaComponent(0.09).setStroke()
    fieldBorder.stroke()

    let prompt = NSAttributedString(
        string: page.field,
        attributes: [.font: uiFont(18.5, .regular), .foregroundColor: white.withAlphaComponent(0.48)]
    )
    prompt.draw(at: NSPoint(x: field.minX + 20, y: field.midY - prompt.size().height / 2))

    let sendCircle = NSRect(x: field.maxX - 42, y: field.midY - 17, width: 34, height: 34)
    accent.setFill()
    NSBezierPath(ovalIn: sendCircle).fill()
    if let arrow = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)?
        .withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 15, weight: .bold)
                .applying(.init(paletteColors: [white]))
        ) {
        arrow.draw(in: NSRect(
            x: sendCircle.midX - arrow.size.width / 2,
            y: sendCircle.midY - arrow.size.height / 2,
            width: arrow.size.width,
            height: arrow.size.height
        ))
    }

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
