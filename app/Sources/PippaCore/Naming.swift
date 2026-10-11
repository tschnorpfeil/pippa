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

    /// The Mac's own folders under the name Pippa's folders have: in the home folder "Dokumente" is ~/Documents (Finder shows it
    /// as "Dokumente" on a German Mac, "Documents" elsewhere). Also "Filme" (~/Movies), Finder's German name, for "Videos".
    static let systemFolders: [String: [String]] = [
        "dokumente": ["documents"], "bilder": ["pictures"], "musik": ["music"], "videos": ["movies", "filme"],
    ]

    /// Every name a folder answers to, lowercased: its real name, the name Finder shows (localized system folders) and,
    /// for the Mac's own folders, Pippa's name for them ("documents" also answers to "dokumente").
    static func names(of folder: URL, fileManager: FileManager = .default) -> Set<String> {
        let real = folder.lastPathComponent
        var names: Set<String> = [key(real), key(fileManager.displayName(atPath: folder.path))]
        for (pippa, system) in systemFolders where names.contains(where: { system.contains($0) }) { names.insert(pippa) }
        return names
    }

    static func key(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased() }

    /// The folder that already stands for `name` in `parent`, by its real name; `nil` if there is none.
    /// "Dokumente" in the home folder is ~/Documents, "rechnungen" is "Rechnungen": nothing is created twice.
    public static func existing(_ name: String, in parent: URL, fileManager: FileManager = .default) -> String? {
        let wanted = Set([key(name)] + (systemFolders[key(name)] ?? []))
        guard let children = try? fileManager.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return nil }
        let folders = children.filter {
            let v = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return v?.isDirectory == true && v?.isSymbolicLink != true
        }
        // The Mac's own folder Finder shows under this name first (if an earlier Pippa already made a second "Dokumente"
        // next to ~/Documents, files still go to the real one), then the same name, then the Mac's own folder by its real name.
        if let shown = folders.first(where: {
            let label = key(fileManager.displayName(atPath: $0.path))
            return label == key(name) && label != key($0.lastPathComponent)
        }) { return shown.lastPathComponent }
        if let same = folders.first(where: { key($0.lastPathComponent) == key(name) }) { return same.lastPathComponent }
        return folders.first(where: { wanted.contains(key($0.lastPathComponent)) })?.lastPathComponent
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
