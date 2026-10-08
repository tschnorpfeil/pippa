import AppKit
import SwiftUI

struct ToastButton: Identifiable {
    let id = UUID()
    var title: String
    var primary: Bool
    var action: @MainActor () -> Void
}

/// In an open task, messages stay in the shell. Only in the background
/// is there a small message right at the entry point, never in another corner.
@MainActor
final class ToastController {
    private let model: AppModel
    private var panel: ShellPanel?
    /// Developer captures only.
    var currentPanel: NSWindow? { panel }

    init(model: AppModel) { self.model = model }

    /// `receipt`: receipt of a task; "Undo" then stays reachable on the line in the conversation.
    /// `log`: also record in the conversation while the shell is closed (not for transient notices).
    func show(title: String, detail: String, buttons: [ToastButton], receipt: UUID? = nil, log: Bool = true) {
        dismiss(animated: false)
        if model.isExpanded {
            model.show(.notice(title: title, detail: detail, buttons: buttons), recordResult: log, receipt: receipt)
            if let panel = model.shell?.panel {
                NSAccessibility.post(element: panel, notification: .announcementRequested,
                                     userInfo: [.announcement: "\(title). \(detail)", .priority: NSAccessibilityPriorityLevel.high.rawValue])
            }
            return
        }
        // What happened in the background also appears in the conversation afterwards.
        if log { model.conversations.append(.system, title + (detail.isEmpty ? "" : "\n" + detail), notice: true, receipt: receipt) }
        let panel = ShellPanel(contentRect: NSRect(x: 0, y: 0, width: 344, height: 80),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.onCancel = { [weak self] in self?.dismiss() }

        // Transparent window with a margin for the shadow; the shape itself rounds (no square corners).
        let margin: CGFloat = 28
        let w = Theme.toastWidth
        let view = ToastView(title: title, detail: detail, buttons: buttons.map { b in
            ToastButton(title: b.title, primary: b.primary) { [weak self] in
                self?.dismiss()
                b.action()
            }
        }, onClose: { [weak self] in self?.dismiss() })
        let size = NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: w, height: 1000))
        let h = ceil(size.height)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: w + 2 * margin, height: h + 2 * margin))
        root.wantsLayer = true
        panel.setContentSize(root.frame.size)
        panel.contentView = root
        let body = NSRect(x: margin, y: margin, width: w, height: h)
        let radius = ShellTokens.toastRadius
        let dark = root.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let shadow = ShadowView(frame: root.bounds)
        root.addSubview(shadow)
        shadow.fit()
        shadow.setAppearance(dark: dark)
        shadow.shadowLayer.shadowRadius = 14
        shadow.shadowLayer.shadowOffset = CGSize(width: 0, height: -8)
        shadow.setShape(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
        let cutPath = CGMutablePath()
        cutPath.addRect(root.bounds.insetBy(dx: -50, dy: -50))
        cutPath.addPath(CGPath(roundedRect: body.insetBy(dx: 1, dy: 1), cornerWidth: radius - 1, cornerHeight: radius - 1, transform: nil))
        shadow.cutout.path = cutPath

        let clip = NSView(frame: body)
        clip.wantsLayer = true
        clip.layer?.cornerRadius = radius
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        clip.layer?.borderWidth = ShellTokens.edgeWidth
        clip.layer?.borderColor = (dark ? ShellTokens.edgeDark : ShellTokens.edgeLight).cgColor
        root.addSubview(clip)
        let effect = NSVisualEffectView(frame: clip.bounds)
        effect.material = ShellTokens.material
        effect.blendingMode = .behindWindow
        effect.state = .active
        clip.addSubview(effect)
        let tint = TintView(frame: clip.bounds)
        tint.wantsLayer = true
        clip.addSubview(tint)
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        hosting.frame = clip.bounds
        clip.addSubview(hosting)

        let screen = model.shell?.shellScreen ?? NSScreen.main ?? NSScreen.screens[0]
        let vis = screen.visibleFrame
        let anchor = model.shell?.shellScreenRect ?? NSRect(x: vis.maxX - 110, y: vis.minY + 20, width: 90, height: 46)
        let x = anchor.midX > vis.midX ? anchor.maxX - w : anchor.minX
        let y = anchor.midY < vis.midY ? anchor.maxY + 12 : anchor.minY - h - 12
        let bodyOrigin = CGPoint(x: max(vis.minX + 12, min(x, vis.maxX - w - 12)),
                                 y: max(vis.minY + 12, min(y, vis.maxY - h - 12)))
        let frame = NSRect(x: bodyOrigin.x - margin, y: bodyOrigin.y - margin,
                           width: w + 2 * margin, height: h + 2 * margin)
        let reduced = MarkHub.shared.reduced
        panel.setFrame(frame, display: false)
        panel.alphaValue = reduced ? 1 : 0
        panel.orderFrontRegardless()
        self.panel = panel
        model.toastShowing = true
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: "\(title). \(detail)", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        if !reduced {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                panel.animator().alphaValue = 1
            }
        }
    }

    func dismiss(animated: Bool = true) {
        guard let panel else { return }
        self.panel = nil
        model.toastShowing = false
        if !animated || MarkHub.shared.reduced {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }
}

struct ToastView: View {
    var title: String
    var detail: String
    var buttons: [ToastButton]
    var onClose: () -> Void

    /// Undo tinted, Continue primary, everything else quiet; quiet first.
    /// Compares against the translated button titles (table "App"), as AppModel sets them.
    private func kind(_ b: ToastButton) -> ButtonKind {
        if b.title.hasPrefix(T("Undo", table: "App")) { return .tinted }
        if b.title == T("Continue", table: "App") || b.title == T("Keep Going", table: "App") { return .primary }
        return .quiet
    }

    private func label(_ b: ToastButton) -> String {
        if b.title == T("Show in Finder", table: "App") { return T("Show", table: "App") }
        if b.title == T("Continue", table: "App") { return T("Keep Going", table: "App") }
        return b.title
    }

    var body: some View {
        let sorted = buttons.sorted { (kind($0) == .quiet ? 0 : 1) < (kind($1) == .quiet ? 0 : 1) }
        VStack(alignment: .trailing, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                PippaMarkView(size: 32)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15.5, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.ink2)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 3)
                Spacer(minLength: 0)
                CloseButton(action: onClose)
            }
            .padding(.top, 16)
            .padding(.leading, 16)
            .padding(.trailing, 14)
            if !sorted.isEmpty {
                HStack(spacing: 8) {
                    ForEach(sorted) { b in
                        let k = kind(b)
                        if k == .tinted {
                            Button { b.action() } label: { Label(label(b), systemImage: "arrow.uturn.backward") }.pippa(k)
                        } else {
                            Button(label(b)) { b.action() }.pippa(k)
                        }
                    }
                }
                .padding(14)
            } else {
                Color.clear.frame(height: 16)
            }
        }
        .frame(width: Theme.toastWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(T("Notice", table: "App"))
    }
}
