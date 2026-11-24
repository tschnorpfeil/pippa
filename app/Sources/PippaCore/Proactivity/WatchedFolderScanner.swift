import CryptoKit
import Darwin
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
        let resolvedFolder = folderURL.standardizedFileURL.resolvingSymlinksInPath()
        let entries = try FileManager.default.contentsOfDirectory(
            at: resolvedFolder,
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

            // Defend against symlink TOCTOU swaps: verify entry stays directly inside `resolvedFolder` and is not a symlink via O_NOFOLLOW.
            let candidateURL = resolvedFolder.appendingPathComponent(url.lastPathComponent)
            guard Self.isRegularNonSymlink(candidateURL),
                  candidateURL.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent().path == resolvedFolder.path
            else {
                ignoredEntries += 1
                continue
            }
            let canonicalPath = candidateURL.standardizedFileURL.path
            guard let identity = try? DurableFileIdentity.capture(candidateURL) else {
                ignoredEntries += 1
                continue
            }
            guard identity.size <= maxFileSizeBytes else {
                ignoredEntries += 1
                continue
            }

            scannedFiles += 1

            // Zero-token fast path: content-identical files (even after mtime/inode touch) skip triage.
            if let existing = try? await store.watchedFile(atPath: canonicalPath),
               existing.matchesContent(identity) {
                if !existing.matches(identity) {
                    try? await store.upsertWatchedFile(path: canonicalPath, identity: identity, seenAt: now)
                }
                skippedUnchanged += 1
                continue
            }

            let excerpt = extractExcerpt(from: candidateURL)
            triagedFiles += 1

            let triageInput = LocalReflexTriageInput(
                fileName: candidateURL.lastPathComponent,
                fileExtension: candidateURL.pathExtension.lowercased(),
                excerpt: excerpt,
                language: language
            )
            let reflexVerdict = await reflex.triage(triageInput, timeout: reflexTimeout)
            let verdict = reflexVerdict ?? WatchedFolderTriageFallback.evaluate(
                fileName: candidateURL.lastPathComponent,
                excerpt: excerpt,
                language: language
            )

            do {
                if verdict.actionable {
                    let draft = Self.makeMatterDraft(
                        fileURL: candidateURL,
                        identity: identity,
                        verdict: verdict,
                        language: language
                    )
                    let upsert = try await store.upsertPrepared(draft, now: now)
                    // Mark watched_files ONLY after upsertPrepared succeeded so transient store errors never lose a file.
                    try await store.upsertWatchedFile(path: canonicalPath, identity: identity, seenAt: now)
                    if case .keptClosed = upsert {
                        continue
                    }
                    if let matter = upsert.matter {
                        actionableMatters.append(matter)
                    }
                } else {
                    try await store.upsertWatchedFile(path: canonicalPath, identity: identity, seenAt: now)
                    silentFiles.append(canonicalPath)
                }
            } catch {
                // Isolate per-file persistence errors so remaining files in the folder are still scanned.
                ignoredEntries += 1
                continue
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

        // Prepared prompt is strictly a fixed template with no filename or document text interpolation;
        // the file is handed over exclusively as an attachment in `preparedFiles`.
        let preparedPrompt = isGerman
            ? "Bitte lies die angehängte Datei und fasse wichtige Fristen oder nächste Schritte kurz zusammen."
            : "Please read the attached file and briefly summarize any deadlines or next steps."

        let pathDigest = SHA256.hash(data: Data(fileURL.path.utf8)).hexString
        return ProactiveMatterDraft(
            kind: .watchedFile,
            matterKey: "watched-file:\(pathDigest)",
            sourceRef: fileURL.path,
            sourceVersion: identity.sha256,
            title: title,
            summary: summary,
            preparedPrompt: preparedPrompt,
            preparedFiles: [fileURL.path]
        )
    }

    private static func isRegularNonSymlink(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFREG
    }

    private static func stripUnsafeChars(_ raw: String) -> String {
        let filteredScalars = raw.unicodeScalars.filter { scalar in
            let v = scalar.value
            // Reject control chars, DEL, and Unicode bidi override/isolate controls.
            if v < 0x20 || v == 0x7F { return false }
            if v == 0x200E || v == 0x200F { return false }
            if (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v) { return false }
            return true
        }
        return String(String.UnicodeScalarView(filteredScalars))
    }

    private static func sanitizeFilename(_ raw: String) -> String {
        let clean = stripUnsafeChars(raw)
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "„", with: "")
            .replacingOccurrences(of: "“", with: "")
            .replacingOccurrences(of: "”", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(clean.prefix(80))
    }

    private static func sanitizeSnippet(_ raw: String, maxLength: Int) -> String? {
        let collapsed = stripUnsafeChars(raw)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maxLength))
    }
}
