import AppKit
import PDFKit

/// Small window of its own: shows the PDF at the cited spot, with the quote highlighted.
@MainActor
enum PDFViewerWindow {
    private static var windows: [NSWindow] = []

    static func open(url: URL, location: String?, quote: String?) {
        guard let document = PDFDocument(url: url) else {
            NSWorkspace.shared.open(url)
            return
        }
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 780),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = url.lastPathComponent
        window.representedURL = url
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("PippaPDF")
        windows.append(window)
        let id = ObjectIdentifier(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                windows.removeAll { ObjectIdentifier($0) == id }
            }
        }

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)

        let pageIndex = pageNumber(from: location).map { max(0, min(document.pageCount - 1, $0 - 1)) }
        if let i = pageIndex, let page = document.page(at: i) { view.go(to: page) }

        guard let quote, !quote.isEmpty else { return }
        let selection = find(quote, in: document, preferring: pageIndex)
        if let selection {
            selection.color = NSColor.systemYellow.withAlphaComponent(0.55)
            view.highlightedSelections = [selection]
            DispatchQueue.main.async {
                view.go(to: selection)
                view.setCurrentSelection(selection, animate: true)
            }
        }
    }

    /// „S. 4“, „Seite 4 · § 8“ → 4
    static func pageNumber(from location: String?) -> Int? {
        guard let location,
              let r = location.range(of: #"(?:S\.|Seite)\s*(\d+)"#, options: .regularExpression) else { return nil }
        let digits = location[r].filter(\.isNumber)
        return Int(digits)
    }

    private static func find(_ quote: String, in document: PDFDocument, preferring page: Int?) -> PDFSelection? {
        let candidates = [quote, String(quote.prefix(80)), String(quote.prefix(40))]
        for text in candidates where !text.isEmpty {
            let hits = document.findString(text, withOptions: [.caseInsensitive, .diacriticInsensitive])
            if hits.isEmpty { continue }
            if let page, let hit = hits.first(where: { s in s.pages.contains { document.index(for: $0) == page } }) { return hit }
            return hits[0]
        }
        return nil
    }
}
