import Foundation

/// Conservative, offline-deterministic triage fallback when the Tier-0 reflex model is unavailable or returns `nil`.
public enum WatchedFolderTriageFallback {
    private static let strongActionSignals: [String] = [
        "zahlungsfrist",
        "mahnung",
        "zahlungserinnerung",
        "fällig bis",
        "faellig bis",
        "zahlbar bis",
        "bitte überweisen",
        "bitte ueberweisen",
        "steuerbescheid",
        "widerspruchsfrist",
        "kündigungsfrist",
        "kuendigungsfrist",
        "einspruchsfrist",
        "letzte erinnerung",
        "frist bis",
        "nachzahlung",
        "offener betrag",
        "invoice due",
        "payment due",
        "overdue",
        "final notice",
        "past due",
        "action required",
        "due date",
        "pay by",
        "tax notice",
        "please remit",
        "balance due",
        "deadline",
    ]

    private static let invoiceNouns: [String] = [
        "rechnung",
        "invoice",
        "finanzamt",
        "bescheid",
        "beitragsbescheid",
    ]

    private static let paymentTriggers: [String] = [
        "fällig",
        "faellig",
        "zahlbar",
        "überweisen",
        "ueberweisen",
        "frist",
        "offen",
        "iban",
        "due",
        "payable",
        "remit",
    ]

    private static let newsletterOrMarketingSignals: [String] = [
        "unsubscribe",
        "abmelden",
        "newsletter",
        "werbung",
        "angebot der woche",
        "weekly digest",
        "rabattcode",
        "view in browser",
    ]

    private static let alreadyPaidSignals: [String] = [
        "bereits bezahlt",
        "bezahlt am",
        "paid in full",
        "payment received",
        "zahlungsbestätigung",
        "zahlungsbestaetigung",
        "vielen dank für ihre zahlung",
        "vielen dank fuer ihre zahlung",
        "thank you for your payment",
        "quittung",
    ]

    public static func evaluate(
        fileName: String,
        excerpt: String,
        language: String = "de"
    ) -> LocalReflexTriageResult {
        let combined = "\(fileName)\n\(excerpt)".lowercased()
        let isGerman = language.lowercased().hasPrefix("de")

        let hasStrongSignal = strongActionSignals.contains { combined.contains($0) }
        let hasInvoiceWithPayment = invoiceNouns.contains { combined.contains($0) }
            && paymentTriggers.contains { combined.contains($0) }

        let isPaid = alreadyPaidSignals.contains { combined.contains($0) }
        let isNewsletter = newsletterOrMarketingSignals.contains { combined.contains($0) }

        // Stay silent on newsletters/marketing and already-paid receipts unless an explicit overdue/final notice is present.
        let isOverdueNotice = combined.contains("mahnung")
            || combined.contains("overdue")
            || combined.contains("final notice")
            || combined.contains("letzte erinnerung")
            || combined.contains("past due")

        if (isNewsletter || isPaid) && !isOverdueNotice {
            return LocalReflexTriageResult(actionable: false)
        }

        guard hasStrongSignal || hasInvoiceWithPayment else {
            return LocalReflexTriageResult(actionable: false)
        }

        let baseName = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        let title = isGerman ? "Prüfen: \(baseName)" : "Review: \(baseName)"
        let reason = isGerman
            ? "Das Dokument enthält einen möglichen Frist- oder Zahlungshinweis."
            : "This document may contain a deadline or payment due date."
        return LocalReflexTriageResult(
            actionable: true,
            title: String(title.prefix(LocalReflexTriageParser.maxTitleLength)),
            reason: reason,
            deadlineHint: nil
        )
    }
}

/// Summary of one single-level watched-folder scan.
public struct WatchedFolderScanReport: Sendable, Equatable {
    public let scannedFiles: Int
    public let skippedUnchanged: Int
    public let ignoredEntries: Int
    public let triagedFiles: Int
    public let actionableMatters: [ProactiveMatter]
    public let silentFiles: [String]
}

/// Calm, zero-token-deduplicated single-level watched-folder scanner.
/// Never scans recursively, never calls write/external tools, and never runs the model on unchanged files.
public struct WatchedFolderScanner: Sendable {
    public static let maxFileSizeBytes: Int64 = 25 * 1024 * 1024
    public static let maxExcerptLength = 2000

    public static let supportedExtensions: Set<String> = [
        "pdf", "txt", "md", "rtf", "docx", "png", "jpg", "jpeg",
    ]

    public static let ignoredExtensions: Set<String> = [
        "download", "crdownload", "part", "tmp", "icloud",
    ]

    private let store: ProactiveMatterStore
    private let reflex: any LocalReflexModel
    private let language: String
    private let reflexTimeout: Duration
    private let maxFileSizeBytes: Int64
    private let enableImageOCR: Bool

    public init(
        store: ProactiveMatterStore,
        reflex: any LocalReflexModel = AppleFoundationReflex(),
        language: String = "de",
        reflexTimeout: Duration = .seconds(4),
        maxFileSizeBytes: Int64 = WatchedFolderScanner.maxFileSizeBytes,
        enableImageOCR: Bool = true
    ) {
        self.store = store
        self.reflex = reflex
        self.language = language
        self.reflexTimeout = reflexTimeout
        self.maxFileSizeBytes = maxFileSizeBytes
        self.enableImageOCR = enableImageOCR
    }

    /// Scans exactly one directory level of `folderURL`.
    public func scan(folderURL: URL, now: Date = Date()) async throws -> WatchedFolderScanReport {
        let accessed = folderURL.startAccessingSecurityScopedResource()
        defer { if accessed { folderURL.stopAccessingSecurityScopedResource() } }

        let resourceKeys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ]
        let entries = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: resourceKeys,
            options: []
        ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        var scannedFiles = 0
        var skippedUnchanged = 0
        var ignoredEntries = 0
        var triagedFiles = 0
        var actionableMatters: [ProactiveMatter] = []
        var silentFiles: [String] = []

        for url in entries {
            guard Self.shouldConsider(url, maxFileSizeBytes: maxFileSizeBytes) else {
                ignoredEntries += 1
                continue
            }

            let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
            let canonicalPath = canonicalURL.path
            guard let identity = try? DurableFileIdentity.capture(canonicalURL) else {
                ignoredEntries += 1
                continue
            }
            guard identity.size <= maxFileSizeBytes else {
                ignoredEntries += 1
                continue
            }

            scannedFiles += 1

            // Zero-token fast path: unchanged files never reach excerpt extraction or any model.
            if let existing = try await store.watchedFile(atPath: canonicalPath),
               existing.matches(identity) {
                skippedUnchanged += 1
                continue
            }

            let excerpt = extractExcerpt(from: canonicalURL)
            triagedFiles += 1

            let triageInput = LocalReflexTriageInput(
                fileName: canonicalURL.lastPathComponent,
                fileExtension: canonicalURL.pathExtension.lowercased(),
                excerpt: excerpt,
                language: language
            )
            let reflexVerdict = await reflex.triage(triageInput, timeout: reflexTimeout)
            let verdict = reflexVerdict ?? WatchedFolderTriageFallback.evaluate(
                fileName: canonicalURL.lastPathComponent,
                excerpt: excerpt,
                language: language
            )

            // Persist file identity after triage so future scans stay zero-token for unchanged content.
            try await store.upsertWatchedFile(path: canonicalPath, identity: identity, seenAt: now)

            guard verdict.actionable else {
                silentFiles.append(canonicalPath)
                continue
            }

            let draft = Self.makeMatterDraft(
                fileURL: canonicalURL,
                identity: identity,
                verdict: verdict,
                language: language
            )
            let upsert = try await store.upsertPrepared(draft, now: now)
            if case .keptClosed = upsert {
                // Respect human-closed permanence: do not report as newly actionable.
                continue
            }
            if let matter = upsert.matter {
                actionableMatters.append(matter)
            }
        }

        return WatchedFolderScanReport(
            scannedFiles: scannedFiles,
            skippedUnchanged: skippedUnchanged,
            ignoredEntries: ignoredEntries,
            triagedFiles: triagedFiles,
            actionableMatters: actionableMatters,
            silentFiles: silentFiles
        )
    }

    /// Pure eligibility check for one direct child entry before hashing or reading.
    public static func shouldConsider(_ url: URL, maxFileSizeBytes: Int64 = maxFileSizeBytes) -> Bool {
        let name = url.lastPathComponent
        guard !name.isEmpty, !name.hasPrefix(".") else { return false }

        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, !ignoredExtensions.contains(ext), supportedExtensions.contains(ext) else {
            return false
        }

        if FileFacts.isCloudPlaceholder(url) {
            return false
        }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            return false
        }
        guard values.isDirectory != true,
              values.isSymbolicLink != true,
              values.isRegularFile == true
        else {
            return false
        }
        if let size = values.fileSize, Int64(size) > maxFileSizeBytes {
            return false
        }
        return true
    }

    private func extractExcerpt(from url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        let rawText: String
        switch ext {
        case "txt", "md":
            rawText = Self.readBoundedPlainText(url, maxBytes: 65_536) ?? ""
        case "pdf":
            rawText = TextReader.read(url, options: .init(maxPages: 3, ocr: false)).fullText
        case "rtf", "docx":
            rawText = TextReader.read(url, options: .quick).fullText
        case "png", "jpg", "jpeg":
            if enableImageOCR {
                rawText = TextReader.read(url, options: .init(maxPages: 1, ocr: true)).fullText
            } else {
                rawText = ""
            }
        default:
            rawText = ""
        }
        return LocalReflexTitleSanitizer.truncateInput(rawText, limit: Self.maxExcerptLength)
    }

    private static func readBoundedPlainText(_ url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes), !data.isEmpty else { return nil }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1)
    }

    private static func makeMatterDraft(
        fileURL: URL,
        identity: DurableFileIdentity,
        verdict: LocalReflexTriageResult,
        language: String
    ) -> ProactiveMatterDraft {
        let isGerman = language.lowercased().hasPrefix("de")
        let safeFileName = sanitizeFilename(fileURL.lastPathComponent)
        let defaultTitle = isGerman
            ? "Neues Dokument: \(safeFileName)"
            : "New document: \(safeFileName)"
        let title = verdict.title.flatMap { sanitizeSnippet($0, maxLength: 80) } ?? defaultTitle

        var summaryParts: [String] = []
        if let reason = verdict.reason.flatMap({ sanitizeSnippet($0, maxLength: 200) }) {
            summaryParts.append(reason)
        } else {
            summaryParts.append(isGerman
                ? "Neu im überwachten Ordner: \(safeFileName)."
                : "New in watched folder: \(safeFileName).")
        }
        if let deadline = verdict.deadlineHint.flatMap({ sanitizeSnippet($0, maxLength: 40) }) {
            summaryParts.append(isGerman ? "Frist: \(deadline)" : "Deadline: \(deadline)")
        }
        let summary = summaryParts.joined(separator: " ")

        // Prepared prompt is strictly a safe template referencing only the sanitized filename,
        // never raw untrusted document text.
        let preparedPrompt = isGerman
            ? "Bitte lies die Datei „\(safeFileName)“ und fasse wichtige Fristen oder nächste Schritte kurz zusammen."
            : "Please read the file \"\(safeFileName)\" and briefly summarize any deadlines or next steps."

        return ProactiveMatterDraft(
            kind: .watchedFile,
            matterKey: "watched-file:\(fileURL.path)",
            sourceRef: fileURL.path,
            sourceVersion: identity.sha256,
            title: title,
            summary: summary,
            preparedPrompt: preparedPrompt,
            preparedFiles: [fileURL.path]
        )
    }

    private static func sanitizeFilename(_ raw: String) -> String {
        let clean = raw
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(clean.prefix(80))
    }

    private static func sanitizeSnippet(_ raw: String, maxLength: Int) -> String? {
        let collapsed = raw
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maxLength))
    }
}
