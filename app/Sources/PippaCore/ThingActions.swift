import Foundation

// Eligible actions by format/capability and optional semantic role; habits rank eligibility.
// By folder and extension only, without reading the files. Separate from `DropKind`, whose cases carry many exhaustive `switch`es.

/// An offered button. `id` is the identifier in the task log.
public struct ThingAction: Sendable, Hashable, Identifiable {
    public enum Handler: Sendable, Hashable { case tool(ToolID), skill(String), tidy, invoiceTable }
    /// `ToolID.rawValue`, skill name, "tidy" or "invoice-table".
    public var id: String
    public var handler: Handler
    public var title: String

    public init(id: String, handler: Handler, title: String) {
        self.id = id; self.handler = handler; self.title = title
    }

    public static func tool(_ tool: ToolID) -> ThingAction {
        ThingAction(id: tool.rawValue, handler: .tool(tool), title: tool.title)
    }
    public static var tidy: ThingAction {
        ThingAction(id: "tidy", handler: .tidy, title: L("Tidy Up", table: "TrayCore"))
    }
    public static var invoiceTable: ThingAction {
        ThingAction(id: "invoice-table", handler: .invoiceTable, title: L("Invoices as a Spreadsheet", table: "TrayCore"))
    }
}

public enum ThingActions {
    /// From this total size "Kleiner machen" is offered.
    public static let largeBytes: Int64 = 10 * 1024 * 1024

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "gif", "bmp"]
    static let tableExtensions: Set<String> = ["xlsx", "xls", "csv", "tsv", "ods", "numbers"]
    static let documentExtensions: Set<String> = ["docx", "doc", "odt", "pages", "rtf"]
    static let textExtensions: Set<String> = ["txt", "md", "markdown", "text"]

    /// Rough kind of a thing, by folder and extension only.
    enum Sort: Equatable { case folder, image, pdf, table, document, text, mail, other }

    static func classify(_ url: URL) -> Sort {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if imageExtensions.contains(ext) { return .image }
        if ext == "eml" { return .mail }
        if tableExtensions.contains(ext) { return .table }
        if documentExtensions.contains(ext) { return .document }
        if textExtensions.contains(ext) { return .text }
        if url.hasDirectoryPath { return .folder }
        if ext.isEmpty, (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { return .folder }
        return .other
    }

    /// File size in bytes, 0 if unknown.
    public static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    /// All eligible actions. Semantic roles can enrich format rules; unknown never implies a reply.
    public static func candidates(for urls: [URL], size: (URL) -> Int64 = ThingActions.fileSize,
                                  skills: [PippaSkill] = PippaSkill.bundled, role: DocumentRole = .unknown) -> [ThingAction] {
        guard !urls.isEmpty else { return [] }
        let sorts = urls.map { classify($0) }
        let images = sorts.filter { $0 == .image }.count
        let pdfs = sorts.filter { $0 == .pdf }.count
        let others = urls.count - images - pdfs

        func skill(_ name: String) -> ThingAction? {
            guard let s = skills.first(where: { $0.name == name }), let title = s.title else { return nil }
            return ThingAction(id: s.name, handler: .skill(s.name), title: title)
        }
        var total: Int64 = 0
        for (url, s) in zip(urls, sorts) where s == .image || s == .pdf { total += size(url) }
        let large = total > largeBytes

        // Images and PDFs, nothing else.
        if others == 0 {
            if images >= 2 && pdfs == 0 {
                var out: [ThingAction] = [.tool(.makeOnePDF)]
                if large { out.append(.tool(.makeSmaller)) }
                out.append(.tool(.asPDF))
                return out
            }
            if pdfs >= 2 && images == 0 {
                var out: [ThingAction] = [.tool(.makeOnePDF)]
                if large { out.append(.tool(.makeSmaller)) }
                return out
            }
            if images >= 1 && pdfs >= 1 {
                return [.tool(.makeOnePDF), .tool(.makeSmaller)]
            }
            if images == 1 {
                let ext = urls[0].pathExtension.lowercased()
                let convert: ToolID = (ext == "jpg" || ext == "jpeg") ? .asPNG : .asJPEG
                return [.tool(.asPDF), .tool(convert), .tool(.makeSmaller)]
            }
            // One PDF.
            var out: [ThingAction] = []
            if large { out.append(.tool(.makeSmaller)) }
            if role == .correspondence { out += [skill("brief-verstehen"), skill("antwort-schreiben")].compactMap { $0 } }
            else if role == .report || role == .notes { out += [skill("zusammenfassen")].compactMap { $0 } }
            return out
        }

        // Mixed with at least two images or PDFs: one PDF from them, the rest is skipped with a sentence.
        // A single photo beside a video becomes a PDF on its own. A single PDF beside a document or table
        // has nothing to combine: "Make one PDF" would only copy it, so abstain.
        if images + pdfs >= 2 { return [.tool(.makeOnePDF)] }
        if images == 1, pdfs == 0, zip(urls, sorts).allSatisfy({ $1 == .image || ($1 == .other && !$0.hasDirectoryPath) }) {
            return [.tool(.asPDF)]
        }
        if images + pdfs == 1 { return [] }

        if sorts.allSatisfy({ $0 == .folder }) { return [.tidy] }
        guard urls.count == 1 else { return [] }
        switch sorts[0] {
        case .table: return [skill("tabelle-pruefen")].compactMap { $0 }
        case .mail: return role == .correspondence ? [skill("brief-verstehen"), skill("antwort-schreiben")].compactMap { $0 } : []
        case .document:
            // Editable Word files are often the person's own outgoing draft, which the system model cannot tell
            // apart from a received letter. Explaining is harmless either way; replying to one's own draft is not.
            if role == .correspondence { return [skill("brief-verstehen")].compactMap { $0 } }
            return role == .report || role == .notes ? [skill("zusammenfassen")].compactMap { $0 } : []
        case .text:
            if role == .correspondence { return [skill("brief-verstehen"), skill("antwort-schreiben")].compactMap { $0 } }
            return role == .report || role == .notes ? [skill("zusammenfassen")].compactMap { $0 } : []
        case .folder, .image, .pdf, .other: return []
        }
    }

    /// Kind for habits and log: several images or PDFs are scans, otherwise as before by kind and extension.
    public static func taskKind(for urls: [URL]) -> TaskKind? {
        guard !urls.isEmpty else { return nil }
        let sorts = urls.map { classify($0) }
        if urls.count >= 2, sorts.allSatisfy({ $0 == .image || $0 == .pdf }) { return .scans }
        if sorts.allSatisfy({ $0 == .folder }) { return .folder }
        guard urls.count == 1 else { return nil }  // Mixed: no habit
        let kind: DropKind = sorts[0] == .folder ? .folder : DropKind.guess(for: urls[0])
        return TaskKind.guess(for: kind, fileExtension: urls[0].pathExtension, count: 1)
    }

    /// At most three actions per offer, whatever the type.
    public static let maxOffered = 3

    /// Rank only eligible actions, omit faded actions even when none remain. At most `maxOffered`, after habit ordering,
    /// so a habitually chosen action keeps its place and the least useful one drops off.
    public static func offered(for urls: [URL], records: [TaskRecord], now: Date = Date(), size: (URL) -> Int64 = ThingActions.fileSize,
                               skills: [PippaSkill] = PippaSkill.bundled, role: DocumentRole = .unknown) -> [ThingAction] {
        let all = candidates(for: urls, size: size, skills: skills, role: role)
        guard let kind = taskKind(for: urls) else { return Array(all.prefix(maxOffered)) }
        let hidden = Habits.faded(kind: kind, in: records)
        let ids = Habits.order(all.map(\.id).filter { !hidden.contains($0) }, kind: kind, in: records, now: now)
        return Array(ids.compactMap { id in all.first { $0.id == id } }.prefix(maxOffered))
    }
}
