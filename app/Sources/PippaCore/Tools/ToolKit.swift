import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

// Single-answer tools: one click, one new file in Caches/Pippa/Results/<uuid>/.
// The originals are never touched, only read. No model, no network.

/// Which tool. The raw value is the identifier in the job log.
public enum ToolID: String, Sendable, Codable, CaseIterable {
    case makeOnePDF = "make-one-pdf", makeSmaller = "make-smaller", asPDF = "as-pdf"
}

/// Progress in pages (One PDF) or files (all other tools).
public struct ToolProgress: Sendable, Equatable {
    public var done: Int
    public var total: Int
    public init(done: Int, total: Int) { self.done = done; self.total = total }
}

/// What a tool leaves behind.
public struct ToolOutput: Sendable {
    /// All in `ResultsFolder.directory`.
    public var files: [URL]
    /// Exact source URLs successfully used; names alone are not unique.
    public var consumedInputs: [URL]
    /// What stayed in place, one plain sentence per name.
    public var skipped: [FileReason]
    /// e.g. "Scans 06.10.2026.pdf" or "2 images as JPG".
    public var summary: String
    /// One more sentence for the person, e.g. "Please check the yellow cells (2 invoices)."
    public var note: String?

    public init(files: [URL], consumedInputs: [URL], skipped: [FileReason], summary: String, note: String? = nil) {
        self.files = files; self.consumedInputs = consumedInputs; self.skipped = skipped; self.summary = summary; self.note = note
    }

    /// A sentence under the result when something stayed in place ("I skipped video.mov. I can only turn …"); otherwise nil.
    public var skippedSentence: String? { ToolText.skipped(skipped) }

    /// What goes under the result: the note, then what stayed in place; nil when there is neither.
    public var detailSentence: String? {
        let parts = [note, skippedSentence].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// Errors the row answers with one sentence (and for passwords with a field).
public enum ToolFailure: Error, Sendable, Equatable, LocalizedError {
    case locked(URL)
    case wrongPassword(URL)
    case nothingUsable(skipped: [FileReason])
    case alreadySmall
    case notEnoughSpace
    case unreadable(name: String)
    case cannotProcess(name: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .locked: L("This PDF is locked. Type the password and I’ll continue.", table: "Tools")
        case .wrongPassword: L("That password didn’t open it. Please try again.", table: "Tools")
        case .nothingUsable(let skipped): ToolText.skipped(skipped) ?? L("There’s nothing here I can use for this.", table: "Tools")
        case .alreadySmall: L("This is already as small as I can make it.", table: "Tools")
        case .notEnoughSpace: L("Not enough space to write this.", table: "Tools")
        case .unreadable(let name): L("I couldn’t open %@.", table: "Tools", name)
        case .cannotProcess(let name, let reason): L("I skipped %@. %@", table: "Tools", name, reason)
        }
    }
}

/// Pippa's own location for results: ~/Library/Caches/Pippa/Results/<uuid>/<name>.
public enum ResultsFolder {
    public static var directory: URL {
        // Checks redirect it (like PIPPA_LOG_DIR) so nothing lands in the real cache.
        if let raw = getenv("PIPPA_RESULTS_DIR") {
            let custom = String(cString: raw)
            if !custom.isEmpty { return URL(fileURLWithPath: custom, isDirectory: true) }
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("Pippa/Results", isDirectory: true)
    }

    /// A fresh, created subfolder per run.
    public static func fresh() throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Is `url` in Pippa's results folder (then Undo may delete the file instead of moving it to the Trash)?
    public static func contains(_ url: URL, durableBaseDirectory: URL = Pippa.supportDirectory) -> Bool {
        let base = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if path.hasPrefix(base + "/") && path.count > base.count + 1 { return true }
        // Durable outputs share the native Open / Save / Undo pipeline, but never the cache cleanup.
        let clean = url.standardizedFileURL
        let root = DurableJobStore.artifactsDirectory(baseDirectory: durableBaseDirectory)
        guard clean == clean.resolvingSymlinksInPath().standardizedFileURL,
              clean.path.hasPrefix(root.path + "/") else { return false }
        let parts = clean.pathComponents.dropFirst(root.pathComponents.count)
        guard parts.count == 3 else { return false }
        let components = Array(parts)
        return UUID(uuidString: components[0]) != nil && UUID(uuidString: components[1]) != nil
            && !components[2].isEmpty
    }

    /// Deletes Results/<uuid> folders older than `maxAge` that contain no file from `keeping`.
    @discardableResult
    public static func prune(keeping: [URL], maxAge: TimeInterval = 86_400, now: Date = Date()) -> Int {
        InboxCleanup.prune(directory, keeping: keeping, maxAge: maxAge, now: now)
    }
}

/// Names of the results. Always via `Naming.sanitize`, extension separate, so shortening never cuts it off.
public enum ResultNaming {
    /// German locale: "Scans 06.10.2026.pdf", otherwise "Scans 2026-10-06.pdf"; PDFs only merged: "Combined …".
    /// A single input: "<Name> (smaller).pdf", "<Name>.jpg".
    public static func name(for tool: ToolID, inputs: [URL], date: Date = Date(), locale: Locale = .current) -> String {
        name(for: tool, inputs: inputs, ext: nil, date: date, locale: locale)
    }

    /// As above, with the extension the tool actually writes (nil = guessed from the input).
    static func name(for tool: ToolID, inputs: [URL], ext: String?, date: Date = Date(), locale: Locale = .current) -> String {
        let german = locale.language.languageCode?.identifier == "de"
        switch tool {
        case .makeOnePDF:
            let allPDF = !inputs.isEmpty && inputs.allSatisfy { $0.pathExtension.lowercased() == "pdf" }
            let word = allPDF ? (german ? "Zusammengefügt" : "Combined") : "Scans"
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = german ? "dd.MM.yyyy" : "yyyy-MM-dd"
            return compose(word + " " + formatter.string(from: date), ext: "pdf")
        case .makeSmaller:
            return compose(base(inputs) + (german ? " (kleiner)" : " (smaller)"), ext: ext ?? guessedExt(tool, inputs.first))
        case .asPDF:
            return compose(base(inputs), ext: "pdf")
        }
    }

    private static func base(_ inputs: [URL]) -> String {
        inputs.first?.deletingPathExtension().lastPathComponent ?? ""
    }

    private static func compose(_ base: String, ext: String) -> String {
        var clean = Naming.sanitize(base, maxLength: 90)
        if clean.isEmpty { clean = "Pippa" }
        return clean + "." + ext.lowercased()
    }

    /// Extension that shrinking writes for this input (HEIC and unknown become JPG).
    static func guessedExt(_ tool: ToolID, _ input: URL?) -> String {
        let ext = input?.pathExtension.lowercased() ?? ""
        switch ext {
        case "pdf", "png": return ext
        case "tif", "tiff": return "jpg"
        default: return "jpg"
        }
    }
}

/// Which files a tool can use.
public enum OneAnswerTools {
    /// Can `tool` do anything with this file?
    public static func accepts(_ tool: ToolID, _ url: URL) -> Bool {
        let kind = ToolFiles.kind(of: url)
        switch tool {
        case .makeOnePDF, .makeSmaller: return kind != .other
        case .asPDF: return kind == .image
        }
    }
}
