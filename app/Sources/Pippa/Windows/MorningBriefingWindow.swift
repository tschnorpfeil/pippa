import AppKit
import SwiftUI

/// Opening a saved overview is a read-only action and never triggers a new scheduled run.
@MainActor
final class MorningBriefingWindowController {
    private var window: NSWindow?
    private let controller: MorningBriefingController

    init(controller: MorningBriefingController) { self.controller = controller }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: TextScaleRoot {
                MorningBriefingLatestView(controller: controller)
                .frame(minWidth: 400, idealWidth: 520, maxWidth: .infinity, minHeight: 300, idealHeight: 560)
                .background(Color(nsColor: Theme.materialTintSolid))
            })
            let window = NSWindow(contentViewController: host)
            window.title = T("Morning overview", table: "MorningBriefing")
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
