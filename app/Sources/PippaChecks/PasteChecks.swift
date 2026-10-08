import Foundation
import PippaCore

func runPasteChecks() {
    check("paste: plain text stays text") {
        PasteDecision.decide(hasFileURLs: false, hasImage: false, plainText: "Hallo") == .text
    }
    check("paste: empty clipboard stays text") {
        PasteDecision.decide(hasFileURLs: false, hasImage: false, plainText: nil) == .text
    }
    check("paste: Finder files (with names as text) become files") {
        PasteDecision.decide(hasFileURLs: true, hasImage: false, plainText: "Bericht.pdf") == .files
    }
    check("paste: Finder files with a preview picture are still files") {
        PasteDecision.decide(hasFileURLs: true, hasImage: true, plainText: nil) == .files
    }
    check("paste: screenshot (picture only) becomes image") {
        PasteDecision.decide(hasFileURLs: false, hasImage: true, plainText: nil) == .image
    }
    check("paste: picture with blank text becomes image") {
        PasteDecision.decide(hasFileURLs: false, hasImage: true, plainText: " \n") == .image
    }
    check("paste: rich text with a picture stays text") {
        PasteDecision.decide(hasFileURLs: false, hasImage: true, plainText: "Tabelle 1") == .text
    }
    check("paste: time stamp is two-digit hour-minute") {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return PasteDecision.timeStamp(Date(timeIntervalSince1970: 23 * 3600 + 41 * 60), calendar: cal) == "23-41"
            && PasteDecision.timeStamp(Date(timeIntervalSince1970: 9 * 3600 + 5 * 60), calendar: cal) == "09-05"
    }
}
