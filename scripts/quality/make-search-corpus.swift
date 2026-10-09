import Foundation
import CoreText
import AppKit
// Invented PDFs with opaque filenames; requires an explicit fake HOME. Never reads personal files.
guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], home.hasSuffix("/dist/tool-search-home") else {
    fatalError("Set CFFIXED_USER_HOME to the isolated dist/tool-search-home fixture directory.")
}
let base = URL(fileURLWithPath: home)
let cases = [("Documents/a.pdf", "Zahnarzt Rechnung 18.03.2023. Betrag 87,40 EUR. Steuer 2023."), ("Desktop/b.pdf", "Mietvertrag vom 01.02.2024. Kaution 1800 EUR."), ("Downloads/c.pdf", "Nebenkostenabrechnung für das Abrechnungsjahr 2024. Nachzahlung 120 EUR."), ("Library/Mobile Documents/com~apple~CloudDocs/d.pdf", "Hausratversicherung. Vertragsbeginn 2025. Steuer 2025."), ("Library/CloudStorage/TestDrive/e.pdf", "Spendenbescheinigung 2025. Steuer 2025. Betrag 50 EUR."), ("Documents/f.pdf", "Steuer 2025. Lohnsteuerbescheinigung."), ("Downloads/2023.pdf", "Urlaub 2026. Keine Rechnung, kein Zahnarzt."), ("Documents/g.pdf", "Zahnarzt Rechnung 2024. Betrag 99 EUR.")]
for (path, text) in cases {
 let url = base.appendingPathComponent(path)
 try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
 var box = CGRect(x:0,y:0,width:595,height:842)
 let ctx=CGContext(url as CFURL,mediaBox:&box,nil)!
 ctx.beginPDFPage(nil)
 let string=NSAttributedString(string:text,attributes:[.font:NSFont.systemFont(ofSize:14)])
 let frame=CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(string),CFRange(location:0,length:0),CGPath(rect:box.insetBy(dx:50,dy:50),transform:nil),nil)
 CTFrameDraw(frame,ctx);ctx.endPDFPage();ctx.closePDF()
}

let manifest = Dictionary(uniqueKeysWithValues: cases.map { (base.appendingPathComponent($0.0).path, $0.1) })
try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: base.appendingPathComponent(".search-corpus.json"))
