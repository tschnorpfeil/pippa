import Foundation

/// File names and folders are always built by code, never by the model.
public enum Naming {
    /// Removes characters that bother Finder, and shortens.
    public static func sanitize(_ raw: String, maxLength: Int = 100) -> String {
        var s = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "\\", with: "-")
        s = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !"<>|?*\"".unicodeScalars.contains($0) })
        s = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        while s.hasPrefix(".") || s.hasPrefix("-") || s.hasPrefix(" ") { s.removeFirst() }
        while s.hasSuffix(".") || s.hasSuffix(" ") { s.removeLast() }
        if s.count > maxLength {
            // Shorten at a word boundary ("… Julia Hoffmann" instead of "… Julia Hoff") if one is within reach.
            let cut = String(s.prefix(maxLength))
            if let space = cut.lastIndex(of: " "), cut.distance(from: space, to: cut.endIndex) <= 16, space > cut.startIndex {
                s = String(cut[..<space])
            } else { s = cut }
            s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ,-·"))
        }
        return s.precomposedStringWithCanonicalMapping
    }

    static func join(_ parts: [String?]) -> String {
        sanitize(parts.compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " "))
    }

    static func withExt(_ base: String, _ ext: String) -> String {
        let b = base.isEmpty ? "Dokument" : base
        return ext.isEmpty ? b : "\(b).\(ext.lowercased())"
    }

    /// `YYYY-MM Sender Kind.ext`, drafts with "(Entwurf)".
    public static func document(date: DayDate?, sender: String?, kind: String?, ext: String, draft: Bool = false) -> String {
        let senderPart = sender.map { sanitize($0, maxLength: 40) }
        // "Stadtwerke Rechnung", but not "Rechnung Rechnung"
        let kindPart = kind.flatMap { k in senderPart?.localizedCaseInsensitiveContains(k) == true ? nil : k }
        return withExt(join([date?.yearMonth, senderPart, kindPart, draft ? "(Entwurf)" : nil]), ext)
    }

    /// `Mietvertrag Wohnung 2021.pdf`
    public static func contract(kind: String, subject: String?, year: Int?, ext: String, draft: Bool = false) -> String {
        withExt(join([kind, subject.map { sanitize($0, maxLength: 40) }, year.map(String.init), draft ? "(Entwurf)" : nil]), ext)
    }

    /// `YYYY-MM-DD Foto NN.jpg`
    public static func photo(date: DayDate, number: Int, ext: String) -> String {
        withExt("\(date.iso) Foto \(String(format: "%02d", number))", ext)
    }

    /// Target folder relative to the area.
    public static func folder(for category: DocCategory, year: Int?) -> String {
        switch category {
        case .invoice: year.map { "Rechnungen/\($0)" } ?? "Rechnungen"
        case .contract: "Verträge"
        case .photo: year.map { "Fotos/\($0)" } ?? "Fotos"
        case .other: "Sonstiges"
        }
    }

    /// Free name in the folder: "Name.pdf", otherwise "Name (2).pdf", "Name (3).pdf" …
    /// `taken` contains already assigned paths (lowercased, APFS mostly does not distinguish case).
    public static func unique(_ name: String, in folder: URL, taken: inout Set<String>, fileManager: FileManager = .default) -> URL {
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        var n = 1
        while true {
            let candidate = n == 1 ? name : (ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            let url = folder.appendingPathComponent(candidate)
            let key = url.standardizedFileURL.path.lowercased()
            if !taken.contains(key) && !fileManager.fileExists(atPath: url.path) {
                taken.insert(key)
                return url
            }
            n += 1
        }
    }
}
