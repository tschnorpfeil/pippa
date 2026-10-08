import AppKit
import PippaCore

// Pill and tray: a click on the pill, the one line, and the handover to the conversation.

extension AppModel {
    /// Click on the pill: with Mail in front, a call in Mail; with Excel in front, a call in Excel;
    /// otherwise `openPillDefault` (AppModel+Call.swift).
    func activatePill() {
        call(.pill, front: FrontmostTracker.shared.capture())
    }

    /// The one line at the pill.
    func openLine() {
        tray.lineOpened()
        if sheet.isActive { sheet.lineOpened() } else if letter.isActive { letter.lineOpened() }
        show(.line)
    }

    /// Give things to the conversation (like a tray before), without overview; then `then` (skill, tidy, question).
    /// If the shell is still in the line afterwards, the input opens.
    func handOver(_ urls: [URL], then: @MainActor () -> Void) {
        if !urls.isEmpty { attach(.files(urls), items: urls, startsFresh: true, open: false) }
        then()
        if mode.key == "line" { openInput() }
    }

    /// Files at the pill, in the line, and at the first Give in Welcome go directly to Pippa.
    /// In an open conversation they stay conversation attachments. New native product recordings
    /// use the real Give path; only older flow recordings bypass the tray.
    var dropsOnTray: Bool {
        let snapshotUsesTray = ["scans", "product", "attachments", "mailcards", "ctxsug"]
            .contains(DevEnvironment.value("PIPPA_SNAPSHOT_ONLY") ?? "")
        guard DevEnvironment.value("PIPPA_SNAPSHOT") == nil || snapshotUsesTray else { return false }
        switch mode {
        case .pill, .target, .line, .onboarding: return true
        case .resume: return false
        default: return false
        }
    }
}
