import Foundation

/// What ⌘V should do, decided from what the clipboard holds (no AppKit, so it can be checked).
public enum PasteDecision: Equatable, Sendable {
    /// Normal paste into the text field.
    case text
    /// Copied files or folders (Finder): attach them like a drop.
    case files
    /// A picture without a file (screenshot, "Copy Image"): save it, then attach it.
    case image

    /// - `hasFileURLs`: the clipboard holds file or folder URLs.
    /// - `hasImage`: it holds picture data (PNG/TIFF).
    /// - `plainText`: its plain text, if any.
    /// Finder also puts the file names on the clipboard as text, so files win over text.
    /// Rich text from Word, Pages, Mail or a spreadsheet often carries a picture next to its text: text wins.
    public static func decide(hasFileURLs: Bool, hasImage: Bool, plainText: String?) -> PasteDecision {
        if hasFileURLs { return .files }
        let hasText = plainText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if hasImage && !hasText { return .image }
        return .text
    }

    /// "23-41" for the file name of a pasted picture.
    public static func timeStamp(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d-%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
