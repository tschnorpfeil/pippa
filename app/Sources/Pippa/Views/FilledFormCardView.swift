import AppKit
import PippaCore
import SwiftUI
import UniformTypeIdentifiers

/// A form Pippa filled in (fill_pdf), under the answer: the copy, how many answers went in, what is still empty, and
/// Open, Save a copy and Show in Finder. Actions only ever use the copy in Pippa's results folder.
struct FilledFormCardView: View {
    var card: FilledFormCard
    private let problemState = State<String?>(initialValue: nil)
    private var problem: String? { get { problemState.wrappedValue } nonmutating set { problemState.wrappedValue = newValue } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(T("Your form is filled in", table: "Views"), systemImage: "doc.text")
                .font(.scaled(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: card.file.lastPathComponent).font(.scaled(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink).lineLimit(2).truncationMode(.middle)
                Text(T("Answers filled in: %lld", table: "Views", card.filled))
                    .font(.scaled(size: 12)).foregroundStyle(Theme.ink2)
                if !card.stillEmpty.isEmpty {
                    Text(T("Still empty: %@", table: "Views", card.stillEmpty.joined(separator: ", ")))
                        .font(.scaled(size: 12)).foregroundStyle(Theme.ink2).lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // On two rows when the three buttons do not fit (400 points, larger text).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    openButton
                    saveButton
                    finderButton
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        openButton
                        saveButton
                    }
                    finderButton
                }
            }
            Text(T("Please check every answer before you sign and send it. The original is unchanged.", table: "Views"))
                .font(.scaled(size: 11)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
            if let problem {
                Text(problem).font(.scaled(size: 12)).foregroundStyle(Theme.need).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14).resultCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("filled-form-card")
    }

    private var openButton: some View {
        Button(T("Open PDF", table: "FilePreparationUI")) { openFile() }.pippa(.quiet).fixedSize()
    }
    private var saveButton: some View {
        Button(T("Save a copy…", table: "FilePreparationUI")) { saveCopy() }.pippa(.quiet).fixedSize()
    }
    private var finderButton: some View {
        Button(T("Show in Finder", table: "Views")) { showInFinder() }.pippa(.quiet).fixedSize()
    }

    /// Only the copy in Pippa's results folder, and only while it is still there (the card may be from an old answer).
    private func available() -> Bool {
        guard ResultsFolder.contains(card.file), FileManager.default.isReadableFile(atPath: card.file.path) else {
            problem = T("This file is no longer available. Ask me to fill in the form again.", table: "Views")
            return false
        }
        problem = nil
        return true
    }

    private func openFile() {
        guard available(), DevEnvironment.value("PIPPA_DEMO") != "1" else { return }
        if !NSWorkspace.shared.open(card.file) {
            problem = T("I couldn’t open this file. You can still save it or show it in Finder.", table: "NativeFlow")
        }
    }

    private func showInFinder() {
        guard available(), DevEnvironment.value("PIPPA_DEMO") != "1" else { return }
        NSWorkspace.shared.activateFileViewerSelecting([card.file])
    }

    /// "Save a copy…": choose a place, copy the filled form there. Like the chart card's "Save as PNG…".
    private func saveCopy() {
        guard available() else { return }
        NSApp.activate()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = card.file.lastPathComponent
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        // State is written only on the main thread (assumeIsolated below).
        nonisolated(unsafe) let problem = problemState
        let source = card.file
        panel.begin { response in
            MainActor.assumeIsolated {
                guard response == .OK, let target = panel.url else { return }
                do {
                    try Self.copy(source, to: target)
                } catch {
                    problem.wrappedValue = T("Couldn’t save the copy there. Please choose another place.", table: "Views")
                }
            }
        }
    }

    /// The panel already asked before replacing an existing file. That file is replaced in one step, so a failed copy
    /// leaves it as it was.
    static func copy(_ source: URL, to target: URL) throws {
        let files = FileManager.default
        guard source.standardizedFileURL.resolvingSymlinksInPath() != target.standardizedFileURL.resolvingSymlinksInPath() else { return }
        guard files.fileExists(atPath: target.path) else {
            try files.copyItem(at: source, to: target)
            return
        }
        let scratch = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        defer { try? files.removeItem(at: scratch) }
        let staged = scratch.appendingPathComponent(target.lastPathComponent)
        try files.copyItem(at: source, to: staged)
        _ = try files.replaceItemAt(target, withItemAt: staged)
    }
}
