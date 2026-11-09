import AppKit
import PippaCore
import SwiftUI

/// Where the online-AI settings save, and whether an answer is running (then they wait).
@MainActor
final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()
    @Published private(set) var inferenceSettings = InferenceSettings.load(from: PiSession.settingsDirectory)
    var isActiveWork: Bool { ChatModel.shared.isAnswering }

    func saveInferenceSettings(_ settings: InferenceSettings) throws {
        guard !isActiveWork else { throw InferenceError.busy }
        try settings.save(to: PiSession.settingsDirectory)
        inferenceSettings = settings
        PiSession.shared.settingsChanged()
        SetupModel.shared.objectWillChange.send()
    }
}

/// The pages of the settings window, in toolbar order.
enum SettingsTab: String, CaseIterable {
    case general, ai, permissions, updates

    /// The tab chosen last, so the window opens where the person left it.
    static let defaultsKey = "settingsTab"

    var title: String {
        switch self {
        case .general: T("General", table: "Settings")
        case .ai: T("AI", table: "Settings")
        case .permissions: T("Permissions", table: "Settings")
        case .updates: T("Updates", table: "Settings")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .ai: "sparkles"
        case .permissions: "hand.raised"
        case .updates: "arrow.down.circle"
        }
    }
}

/// Settings like the Mac's own apps: one window, a tab per page in the toolbar, the window as tall as the page.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    static let width: CGFloat = 600
    private(set) var window: NSWindow?
    private var tabs: SettingsTabsController?
    var isVisible: Bool { window?.isVisible == true }

    /// Opens on `tab`, or where the person left it.
    func show(_ tab: SettingsTab? = nil) {
        if window == nil {
            let tabs = SettingsTabsController()
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            self.window = window
            self.tabs = tabs
            tabs.fitWindow(animated: false)
            window.center()
        }
        if let tab, let index = SettingsTab.allCases.firstIndex(of: tab) { tabs?.selectedTabViewItemIndex = index }
        NSApp.unhide(nil)
        NSApp.activate()
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        // A closed window keeps its pages, and SwiftUI does not show them again (no onAppear): the page may have grown or
        // shrunk meanwhile, and the permissions may have changed in System Settings.
        tabs?.fitWindow(animated: false)
        if tabs?.selectedTab == .permissions { PermissionStatus.shared.refresh() }
    }
}

/// Toolbar tabs, each page a SwiftUI form. The window takes the title and the height of the chosen page.
private final class SettingsTabsController: NSTabViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        for tab in SettingsTab.allCases {
            let page = SettingsPage(rootView: SettingsView(tab: tab, settings: .shared, setup: .shared))
            page.sizingOptions = [.preferredContentSize]
            page.tabs = self
            page.title = tab.title
            let item = NSTabViewItem(viewController: page)
            item.identifier = tab.rawValue
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil)
            addTabViewItem(item)
        }
        let saved = UserDefaults.standard.string(forKey: SettingsTab.defaultsKey).flatMap(SettingsTab.init(rawValue:)) ?? .general
        selectedTabViewItemIndex = SettingsTab.allCases.firstIndex(of: saved) ?? 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var selectedTab: SettingsTab { SettingsTab.allCases[selectedTabViewItemIndex] }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.title = tabViewItems[selectedTabViewItemIndex].label
    }

    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        guard let item, let id = item.identifier as? String else { return }
        UserDefaults.standard.set(id, forKey: SettingsTab.defaultsKey)
        view.window?.title = item.label
        fitWindow(animated: true)
    }

    /// The most a page may ask for: the screen's height and, while the window is on screen, the room below its top edge
    /// (never less than it has), so a page that grows while open scrolls instead of reaching under the Dock.
    var pageLimit: CGFloat? {
        guard let window = view.window, let content = window.contentView,
              let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return nil }
        let room = window.isVisible ? max(window.frame.maxY - visible.minY, window.frame.height) : visible.height
        return room - (window.frame.height - content.frame.height)
    }

    /// As tall as the page, at most as tall as the screen (then the page scrolls). The top edge stays where it is unless
    /// the page would reach below the Dock; then the window moves up as far as needed.
    func fitWindow(animated: Bool) {
        guard let window = view.window, let page = tabViewItems[selectedTabViewItemIndex].viewController as? SettingsPage,
              let content = window.contentView else { return }
        var height = ceil(max(page.naturalHeight, 1)) + window.frame.height - content.frame.height
        var top = window.frame.maxY
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            height = min(height, visible.height)
            top = min(max(top, visible.minY + height), visible.maxY)
        }
        let frame = NSRect(x: window.frame.minX, y: top - height, width: SettingsWindow.width, height: height)
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true, animate: animated && !Theme.reduceMotion)
    }
}

/// One page. While it is shown, AppKit sizes the window from its preferred size whenever the content grows, without
/// asking the controller, so the page itself keeps to the controller's limit.
private final class SettingsPage: NSHostingController<SettingsView> {
    weak var tabs: SettingsTabsController?

    /// The height the page would like, without the limit.
    var naturalHeight: CGFloat { super.preferredContentSize.height }

    override var preferredContentSize: NSSize {
        get {
            var size = super.preferredContentSize
            if let limit = tabs?.pageLimit { size.height = min(size.height, limit) }
            return size
        }
        set { super.preferredContentSize = newValue }
    }
}

/// One page of the settings window.
struct SettingsView: View {
    var tab: SettingsTab
    @ObservedObject var settings: SettingsModel
    @ObservedObject var setup: SetupModel
    /// The permissions page reads the real state; snapshots pass a fixed one.
    var permissions = PermissionStatus.shared

    var body: some View {
        Group {
            switch tab {
            case .general: GeneralSettings()
            case .ai: AISettings(settings: settings, setup: setup)
            case .permissions: PermissionSettings(status: permissions)
            case .updates: UpdateSettings()
            }
        }
        .formStyle(.grouped)
        .tint(Theme.accent)
        .frame(width: SettingsWindow.width)
    }

    /// Read once: `ModelCatalog.bundled()` decodes a file, and views ask for the name on every redraw.
    static let localModelName: String = ModelCatalog.bundled().models.first?.label ?? ""
}

/// One row in a settings group: title, explanation, control.
struct SettingsRow<Trailing: View>: View {
    var title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(Typo.callout)
                if let detail {
                    Text(detail).font(Typo.footnote).foregroundStyle(Theme.ink2).monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: Space.m)
            trailing
        }
    }
}

enum ButtonKind { case primary, secondary, quiet }

extension View {
    @ViewBuilder func pippa(_ kind: ButtonKind, large: Bool = false) -> some View {
        switch kind {
        case .primary: buttonStyle(.borderedProminent)
        case .secondary: buttonStyle(.bordered)
        case .quiet: buttonStyle(.borderless)
        }
    }
}
