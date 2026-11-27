import AppKit
import PippaCore
import WebKit

/// The local panel keeps one tab per conversation: each a `WKWebView` the person can see and use, all sharing the
/// persistent `WKWebsiteDataStore.default()`, so a sign-in survives other tabs, other conversations and a restart. At
/// most `maxActiveWebViews` tabs keep a live view; the least recently used idle tab gives its view back and keeps only
/// its address and title. Each online answer gets one offscreen view with a fresh nonpersistent website data store.
///
/// Guards: every navigation in every frame, in a tab or in its popup, passes `PippaMCPBrowserTool.isAllowedURL` and the
/// private-address check (no `file:`, no this Mac, no local network, also after redirects); a content rule list blocks
/// local-network subresources. A sign-in window (`window.open`, `target="_blank"`) opens as the tab's real popup view,
/// so `window.opener` keeps working; online it loads in the same view. Snapshots and actions run in an isolated content
/// world, so page scripts cannot read or forge Pippa's element refs, and password values are never captured.
@MainActor
final class WKBrowserSession: NSObject, ObservableObject, BrowserOperating, WKNavigationDelegate, WKUIDelegate {
    static let shared = WKBrowserSession()
    /// Live local web views at most (Macs with 16 GB): opening one more gives back the oldest idle tab's view.
    static let maxActiveWebViews = 3
    /// The tab for calls without a conversation, and the online session's only tab.
    static let defaultKey = "_default"

    /// One conversation's page. Everything about a navigation in flight belongs to its tab, so one conversation's
    /// approvals, refs and loads never mix with another's.
    @MainActor
    final class Tab {
        let key: String
        /// `nil` once evicted: `lastURL` and `lastTitle` stay, so the tab can load its page again.
        var webView: WKWebView?
        /// A window the page opened (sign-in), shown over the tab until it closes.
        var popupWebView: WKWebView?
        var lastURL: URL?
        var lastTitle = ""
        var latestSnapshot: BrowserSnapshot?
        var handoffMessage: String?
        var navigationProblem: String?
        var modelActions = 0
        var lastUsedAt = Date.distantPast
        var manualNavigation = false
        var blockedNavigation = false
        var declinedNavigation = false
        var navigationFailed = false
        var pendingPolicyDecisions = 0
        var pendingPopupTasks: [UUID: Task<Void, Never>] = [:]
        var preapprovedPopupURL: URL?
        var awaitingViews: Set<ObjectIdentifier> = []
        var activeNavigations: [ObjectIdentifier: Set<ObjectIdentifier>] = [:]

        init(key: String) { self.key = key }

        /// What the panel shows and the tool reads: the popup while one is open.
        var shownView: WKWebView? { popupWebView ?? webView }
        var isLoading: Bool { (webView?.isLoading ?? false) || (popupWebView?.isLoading ?? false) }
        var hasContent: Bool { webView != nil || lastURL != nil }
    }

    /// One entry of the panel's tab strip.
    struct TabItem: Equatable, Identifiable {
        let id: String
        let title: String
        let waiting: Bool
    }

    @Published var isOpen = false
    // The shown tab's state, mirrored for SwiftUI.
    @Published private(set) var navigationProblem: String?
    @Published private(set) var currentURL: URL?
    @Published private(set) var pageTitle = ""
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    /// The person's step (login, 2FA, CAPTCHA), shown as a banner over the page until they click Done.
    @Published private(set) var handoffMessage: String?
    /// The view the panel shows: the shown tab's popup, else its page; `nil` before it opened anything.
    @Published private(set) var shownWebView: WKWebView?
    /// The popup's host while the shown tab has one open ("" before it loaded).
    @Published private(set) var popupHost: String?
    /// The address an evicted shown tab can load again.
    @Published private(set) var restorableURL: URL?
    @Published private(set) var tabItems: [TabItem] = []
    @Published private(set) var displayedKey = WKBrowserSession.defaultKey

    private(set) var tabs: [String: Tab] = [:]
    /// Tabs in the order they were opened, for the strip.
    private var order: [String] = []
    private var lastStamp = Date.distantPast
    private var counter = 0
    /// All local tabs share it, so the rule list is added once for all of them.
    private let localContent = WKUserContentController()
    private var ruleList: WKContentRuleList?
    /// The rule list being compiled: concurrent callers wait for it, so it is added only once.
    private var installingRules: Task<Void, Error>?
    private let world = WKContentWorld.world(name: "PippaBrowser")
    private let onlineConfiguration: WKWebViewConfiguration?
    private var isOnline: Bool { onlineConfiguration != nil }
    /// The private-address check after `isAllowedURL`; checks put a stand-in here.
    var resolvesToPrivateAddress: @Sendable (String) async -> Bool = { await PippaMCPBrowserTool.resolvesToPrivateAddress($0) }

    private init(onlineConfiguration: WKWebViewConfiguration? = nil) {
        self.onlineConfiguration = onlineConfiguration
    }

    /// A separate local pool with the same rules as `shared`, for checks.
    static func makeLocalPool() -> WKBrowserSession { WKBrowserSession() }

    static func makeOnline() -> WKBrowserSession? {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // WebKit's managed SSO can authenticate independently of the cookie store and HTTP challenges.
        // Its opt-out is SPI. Decline online browsing when the installed WebKit cannot disable it.
        let preferences = configuration.preferences
        let setter = NSSelectorFromString("_setExtensibleSSOEnabled:")
        let getter = NSSelectorFromString("_isExtensibleSSOEnabled")
        guard preferences.responds(to: setter), preferences.responds(to: getter),
              let setMethod = preferences.method(for: setter), let getMethod = preferences.method(for: getter) else { return nil }
        typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool) -> Void
        typealias IsEnabled = @convention(c) (AnyObject, Selector) -> Bool
        unsafeBitCast(setMethod, to: SetEnabled.self)(preferences, setter, false)
        guard !unsafeBitCast(getMethod, to: IsEnabled.self)(preferences, getter) else { return nil }
        return WKBrowserSession(onlineConfiguration: configuration)
    }

    /// Gates main-frame destinations and popups through turn-scoped host approvals and confirmation. `tabKey`:
    /// the conversation that owns the tab. `personsStep`: the tab waits for the person's login, 2FA or CAPTCHA.
    var authorizeNavigation: (@MainActor (_ url: URL, _ tabKey: String, _ personsStep: Bool) async -> Bool)?

    // MARK: Tabs

    private func key(for conversation: String?) -> String { isOnline ? Self.defaultKey : conversation ?? Self.defaultKey }

    /// The conversation's tab, made on first use (without a web view yet).
    func tab(for conversation: String?) -> Tab { tab(key: key(for: conversation)) }

    private func tab(key: String) -> Tab {
        if let tab = tabs[key] { return tab }
        let tab = Tab(key: key)
        tabs[key] = tab
        order.append(key)
        return tab
    }

    /// The tab the person sees, or will see when the chat shows its conversation: only it may open the panel.
    private func isInFront(_ tab: Tab) -> Bool {
        !isOnline && (tab.key == displayedKey || tab.key == key(for: ChatModel.shared.currentID))
    }

    private func tab(of view: WKWebView) -> Tab? {
        tabs.values.first { $0.webView === view || $0.popupWebView === view }
    }

    /// Strictly increasing, so the least recently used tab is never a tie.
    private func touch(_ tab: Tab) {
        let now = Date()
        lastStamp = now > lastStamp ? now : lastStamp.addingTimeInterval(0.001)
        tab.lastUsedAt = lastStamp
    }

    /// The online session's one view (checks look at its configuration).
    var webView: WKWebView { materialize(tab(key: Self.defaultKey)) }

    /// The tab's live view, made now if it has none (after giving back the oldest idle tab's view when the pool is full).
    @discardableResult
    func materialize(_ tab: Tab) -> WKWebView {
        touch(tab)
        if let view = tab.webView { return view }
        if !isOnline { evictIfNeeded(keeping: tab) }
        let view = makeWebView()
        tab.webView = view
        publish()
        return view
    }

    /// Before a new view: while the pool is full, the least recently used tab that is not `target`, not shown, not
    /// acting for Pippa, not waiting for the person and without an open popup gives its view back. Without such a tab
    /// the pool grows.
    private func evictIfNeeded(keeping target: Tab) {
        while tabs.values.filter({ $0.webView != nil }).count >= Self.maxActiveWebViews {
            let idle = tabs.values.filter {
                $0 !== target && $0.key != displayedKey && $0.webView != nil && $0.modelActions == 0
                    && $0.handoffMessage == nil && $0.popupWebView == nil
            }
            guard let oldest = idle.min(by: { $0.lastUsedAt < $1.lastUsedAt }) else { return }
            evict(oldest)
        }
    }

    /// Releases the tab's web content (its RAM); its address and title stay, its refs go.
    func evict(_ tab: Tab) {
        if let view = tab.webView { sync(tab, from: view) }
        closePopupView(of: tab)
        cancelNavigations(of: tab)
        tab.webView?.stopLoading()
        tab.webView?.navigationDelegate = nil
        tab.webView?.uiDelegate = nil
        tab.webView?.removeFromSuperview()
        tab.webView = nil
        tab.latestSnapshot = nil
        publish()
    }

    private func cancelNavigations(of tab: Tab) {
        for task in tab.pendingPopupTasks.values { task.cancel() }
        tab.pendingPopupTasks.removeAll()
        tab.preapprovedPopupURL = nil
        tab.awaitingViews.removeAll()
        tab.activeNavigations.removeAll()
    }

    /// Removes the tab: `browse close`, or the close button of its entry in the strip.
    private func discard(_ tab: Tab) {
        evict(tab)
        tab.lastURL = nil
        tab.lastTitle = ""
        tab.handoffMessage = nil
        tab.navigationProblem = nil
        tabs[tab.key] = nil
        order.removeAll { $0 == tab.key }
        publish()
    }

    private func makeWebView() -> WKWebView {
        let configuration: WKWebViewConfiguration
        if let onlineConfiguration {
            configuration = onlineConfiguration
        } else {
            configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .default()
            configuration.userContentController = localContent
        }
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let viewport: CGRect = isOnline ? CGRect(x: 0, y: 0, width: 1024, height: 768) : .zero
        let view = WKWebView(frame: viewport, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        return view
    }

    /// Switching chats switches the panel to that conversation's tab, and reloads an evicted tab when the panel is open.
    func selectConversation(_ id: String?, autoRestore: Bool = true) {
        guard !isOnline else { return }
        let tab = tab(for: id)
        touch(tab)
        if displayedKey != tab.key { displayedKey = tab.key }
        publish()
        if autoRestore, isOpen, tab.webView == nil, let url = tab.lastURL, tab.modelActions == 0, !ChatModel.shared.isAnswering {
            Task { await self.loadManually(url, in: tab, quietly: true) }
        }
    }

    /// Drops a deleted conversation's tab so its view and strip entry do not linger.
    func forgetConversation(_ id: String) {
        guard !isOnline, let tab = tabs[id], tab.modelActions == 0 else { return }
        let wasDisplayed = displayedKey == id
        discard(tab)
        if wasDisplayed {
            displayedKey = Self.defaultKey
            isOpen = false
            publish()
        }
    }

    /// The strip's close button. A tab Pippa is using stays.
    func closeTab(_ key: String) {
        guard let tab = tabs[key], tab.modelActions == 0 else { return }
        discard(tab)
    }

    /// Closes the shown tab's popup and returns to its page.
    func closePopup() {
        guard let tab = tabs[displayedKey] else { return }
        closePopupView(of: tab)
    }

    private func closePopupView(of tab: Tab) {
        guard let popup = tab.popupWebView else { return }
        let popupID = ObjectIdentifier(popup)
        tab.awaitingViews.remove(popupID)
        tab.activeNavigations[popupID] = nil
        popup.stopLoading()
        popup.navigationDelegate = nil
        popup.uiDelegate = nil
        popup.removeFromSuperview()
        tab.popupWebView = nil
        // The refs belonged to what was shown.
        tab.latestSnapshot = nil
        publish()
    }

    // MARK: Panel

    func showHandoff(_ message: String, conversation: String? = nil) {
        let tab = tab(for: conversation)
        tab.handoffMessage = message
        if isInFront(tab) { isOpen = true }
        publish()
    }

    /// The person clicked Done on the banner.
    func finishHandoff() {
        tabs[displayedKey]?.handoffMessage = nil
        publish()
    }

    /// A web address typed by the person uses the panel without requiring an active AI turn.
    func navigateManually(_ text: String) async {
        guard !isOnline else { return }
        let tab = tab(key: displayedKey)
        guard tab.modelActions == 0, !ChatModel.shared.isAnswering else {
            return setProblem(T("Wait for Pippa to finish before opening a website.", table: "Views"), in: tab)
        }
        guard let url = Self.webAddress(text) else {
            return setProblem(T("Enter a public website address, such as https://example.com.", table: "Views"), in: tab)
        }
        await loadManually(url, in: tab)
    }

    /// "Open in Pippa" for a page the answer read (`front_read`, a source chip): the same guards as a typed address,
    /// in that conversation's tab.
    func openFromBridge(_ url: URL, in conversationID: String?) async {
        guard !isOnline, ProcessInfo.processInfo.environment["PIPPA_DEMO"] != "1" else { return }
        selectConversation(conversationID, autoRestore: false)
        let tab = tab(for: conversationID)
        isOpen = true
        guard tab.modelActions == 0, !ChatModel.shared.isAnswering else {
            return setProblem(T("Wait for Pippa to finish before opening a website.", table: "Views"), in: tab)
        }
        guard PippaMCPBrowserTool.isAllowedURL(url) else {
            return setProblem(T("Enter a public website address, such as https://example.com.", table: "Views"), in: tab)
        }
        await loadManually(url, in: tab)
    }

    /// The person's own load: allowed public address, then rules, then (still nobody acting) the page.
    private func loadManually(_ url: URL, in tab: Tab, quietly: Bool = false) async {
        if !quietly { setProblem(nil, in: tab) }
        guard let host = PippaMCPBrowserTool.normalizedHost(url), PippaMCPBrowserTool.isAllowedURL(url),
              !(await resolvesToPrivateAddress(host)) else {
            if !quietly { setProblem(T("Enter a public website address, such as https://example.com.", table: "Views"), in: tab) }
            return
        }
        do { try await installRules() }
        catch { if !quietly { setProblem(T("The website couldn’t be loaded. Try again.", table: "Views"), in: tab) }; return }
        guard tabs[tab.key] === tab else { return }
        guard tab.modelActions == 0, !ChatModel.shared.isAnswering else {
            if !quietly { setProblem(T("Wait for Pippa to finish before opening a website.", table: "Views"), in: tab) }
            return
        }
        if quietly {
            guard tab.key == displayedKey, isOpen, tab.webView == nil else { return }
        }
        tab.manualNavigation = true
        closePopupView(of: tab)
        if !quietly, tab.key == displayedKey { isOpen = true }
        materialize(tab).load(URLRequest(url: url))
        sync(tab)
    }

    static func webAddress(_ text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }) else { return nil }
        if let scheme = URLComponents(string: text)?.scheme, !["http", "https"].contains(scheme.lowercased()) {
            let hostAndPort = URLComponents(string: "https://" + text)
            guard hostAndPort?.port != nil, hostAndPort?.host?.contains(".") == true else { return nil }
        }
        let address = text.contains("://") ? text : "https://" + text
        guard let url = URL(string: address), PippaMCPBrowserTool.isAllowedURL(url) else { return nil }
        return url
    }

    func goBack() { if let view = tabs[displayedKey]?.shownView, view.canGoBack { view.goBack() } }
    func reload() {
        guard let tab = tabs[displayedKey] else { return }
        if let view = tab.shownView, Self.pageURL(view) != nil { view.reload() }
        else if tab.webView == nil, let url = tab.lastURL { Task { await self.loadManually(url, in: tab) } }
    }
    func stop() { tabs[displayedKey]?.shownView?.stopLoading() }

    private func setProblem(_ problem: String?, in tab: Tab) {
        tab.navigationProblem = problem
        publish()
    }

    private static func pageURL(_ view: WKWebView) -> URL? { view.url.flatMap { $0.scheme?.lowercased() == "about" ? nil : $0 } }

    /// A view's callback: the tab remembers its page's address and title (for after an eviction), then the panel.
    private func sync(_ tab: Tab, from view: WKWebView? = nil) {
        if let page = tab.webView, view == nil || view === page, let url = Self.pageURL(page) {
            tab.lastURL = url
            tab.lastTitle = page.title ?? ""
        }
        publish()
    }

    /// The shown tab's state for SwiftUI. Navigation callbacks fire often with nothing new: only changes are assigned,
    /// so SwiftUI redraws only then.
    private func publish() {
        let tab = tabs[displayedKey]
        let view = tab?.shownView
        let url = view.flatMap(Self.pageURL)
        let title = url == nil ? "" : view?.title ?? ""
        if currentURL != url { currentURL = url }
        if pageTitle != title { pageTitle = title }
        if isLoading != (tab?.isLoading ?? false) { isLoading = tab?.isLoading ?? false }
        if canGoBack != (view?.canGoBack ?? false) { canGoBack = view?.canGoBack ?? false }
        if handoffMessage != tab?.handoffMessage { handoffMessage = tab?.handoffMessage }
        if navigationProblem != tab?.navigationProblem { navigationProblem = tab?.navigationProblem }
        if shownWebView !== view { shownWebView = view }
        let popup = tab?.popupWebView.map { popup in
            popup.url.flatMap(PippaMCPBrowserTool.normalizedHost).map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? ""
        }
        if popupHost != popup { popupHost = popup }
        let restorable = tab?.webView == nil ? tab?.lastURL : nil
        if restorableURL != restorable { restorableURL = restorable }
        let items = order.compactMap { key -> TabItem? in
            guard let tab = tabs[key], tab.hasContent else { return nil }
            let host = tab.lastURL.flatMap(PippaMCPBrowserTool.normalizedHost).map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
            let title = tab.lastTitle.isEmpty ? host ?? "" : tab.lastTitle
            return TabItem(id: key, title: title, waiting: tab.handoffMessage != nil)
        }
        if tabItems != items { tabItems = items }
    }

    // MARK: BrowserOperating

    func currentSnapshot() async -> BrowserSnapshot? { await currentSnapshot(conversation: nil) }

    func currentSnapshot(conversation: String?) async -> BrowserSnapshot? { tabs[key(for: conversation)]?.latestSnapshot }

    func perform(_ action: BrowserAction) async throws -> BrowserSnapshot? { try await perform(action, conversation: nil) }

    func perform(_ action: BrowserAction, conversation: String?) async throws -> BrowserSnapshot? {
        let tab = tab(for: conversation)
        tab.modelActions += 1
        defer { tab.modelActions -= 1 }
        touch(tab)
        tab.manualNavigation = false
        setProblem(nil, in: tab)
        switch action {
        case .open(let url):
            guard PippaMCPBrowserTool.isAllowedURL(url), let host = PippaMCPBrowserTool.normalizedHost(url) else {
                throw BrowserError.blockedAddress
            }
            if await resolvesToPrivateAddress(host) { throw BrowserError.blockedAddress }
            try await installRules()
            guard tabs[tab.key] === tab else { throw BrowserError.failed }
            if isInFront(tab) { isOpen = true }
            // Pippa opens addresses in the tab itself, never in a window the page opened.
            closePopupView(of: tab)
            let view = materialize(tab)
            tab.preapprovedPopupURL = nil
            let viewID = ObjectIdentifier(view)
            if isCrossDocumentDestination(url, from: view) { tab.awaitingViews.insert(viewID) } else { tab.awaitingViews.remove(viewID) }
            tab.blockedNavigation = false; tab.declinedNavigation = false; tab.navigationFailed = false
            view.load(URLRequest(url: url))
            await settle(tab, after: .milliseconds(150), timeout: .seconds(15))
            if tab.blockedNavigation { throw BrowserError.blockedAddress }
            if tab.declinedNavigation { throw BrowserError.declinedNavigation }
            if tab.navigationFailed { throw BrowserError.failed }
        case .snapshot:
            break
        case .click(let ref, let snapshotId):
            try await act(tab, "click", ref: ref, snapshotId: snapshotId, text: "")
        case .fill(let ref, let text, let snapshotId):
            try await act(tab, "fill", ref: ref, snapshotId: snapshotId, text: text)
        case .select(let ref, let value, let snapshotId):
            try await act(tab, "select", ref: ref, snapshotId: snapshotId, text: value)
        case .form(let fields, let submit, let snapshotId):
            try await act(tab, "form", ref: submit ?? "", snapshotId: snapshotId, text: "", fields: fields)
        case .back:
            guard let view = tab.shownView, Self.pageURL(view) != nil else { throw BrowserError.nothingOpen }
            tab.blockedNavigation = false; tab.declinedNavigation = false; tab.navigationFailed = false
            if view.canGoBack {
                if let backURL = view.backForwardList.backItem?.url, isCrossDocumentHistoryDestination(backURL, from: view) {
                    tab.awaitingViews.insert(ObjectIdentifier(view))
                }
                view.goBack()
                await settle(tab, after: .milliseconds(150), timeout: .seconds(10))
            }
            if tab.blockedNavigation { throw BrowserError.blockedAddress }
            if tab.declinedNavigation { throw BrowserError.declinedNavigation }
        case .close:
            // Only this conversation's tab: other conversations keep theirs.
            if tab.key == displayedKey { isOpen = false }
            discard(tab)
            return nil
        }
        return try await capture(tab)
    }

    private func drainPending(_ tab: Tab, timeout: Duration) async {
        var deadline = ContinuousClock.now + timeout
        while !Task.isCancelled {
            if !tab.pendingPopupTasks.isEmpty {
                for task in Array(tab.pendingPopupTasks.values) { await task.value }
                // Confirmation or popup waits do not consume the post-approval page-load timeout.
                deadline = ContinuousClock.now + timeout
                continue
            }
            if tab.pendingPolicyDecisions > 0 {
                try? await Task.sleep(for: .milliseconds(50))
                deadline = ContinuousClock.now + timeout
                continue
            }
            let hasActiveNavigation = tab.activeNavigations.values.contains { !$0.isEmpty }
            if !tab.awaitingViews.isEmpty || hasActiveNavigation || tab.isLoading, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            break
        }
    }

    /// Waits for confirmations, popups and page loads (bounded after approval), so the tool sees any navigation decision.
    private func settle(_ tab: Tab, after delay: Duration, timeout: Duration) async {
        try? await Task.sleep(for: delay)
        await drainPending(tab, timeout: timeout)
        // Scripts often render or navigate after load; a short pause catches most of it.
        try? await Task.sleep(for: .milliseconds(250))
        await drainPending(tab, timeout: timeout)
        sync(tab)
    }

    private func act(_ tab: Tab, _ kind: String, ref: String, snapshotId: String?, text: String, fields: [BrowserFormField] = []) async throws {
        guard let view = tab.shownView, Self.pageURL(view) != nil else { throw BrowserError.nothingOpen }
        guard let snapshotId = snapshotId ?? tab.latestSnapshot?.snapshotId else { throw BrowserError.staleRef }
        tab.awaitingViews.remove(ObjectIdentifier(view))
        tab.blockedNavigation = false; tab.declinedNavigation = false; tab.navigationFailed = false
        let steps: [[String: String]] = fields.map { ["ref": $0.ref, "kind": $0.choose ? "select" : "fill", "text": $0.text] }
        let arguments: [String: Any] = ["kind": kind, "ref": ref, "snapshotId": snapshotId, "text": text, "fields": steps]
        let reply = try? await view.callAsyncJavaScript(Self.actionScript, arguments: arguments, in: nil, contentWorld: world) as? [String: Any]
        switch reply?["error"] as? String {
        case nil where reply?["ok"] as? Bool == true: break
        case "stale": throw BrowserError.staleRef
        case "password": throw BrowserError.passwordField
        case "option": throw BrowserError.noSuchOption
        default:
            // The step may have changed the page before it stopped: its refs are no longer trusted.
            tab.latestSnapshot = nil
            throw BrowserError.failed
        }
        tab.latestSnapshot = nil
        await settle(tab, after: .milliseconds(400), timeout: .seconds(10))
        if tab.blockedNavigation { throw BrowserError.blockedAddress }
        if tab.declinedNavigation { throw BrowserError.declinedNavigation }
    }

    private func capture(_ tab: Tab) async throws -> BrowserSnapshot {
        guard let view = tab.shownView, let url = Self.pageURL(view) else { throw BrowserError.nothingOpen }
        counter += 1
        let id = "s\(counter)-" + UUID().uuidString.prefix(8).lowercased()
        let arguments: [String: Any] = ["snapshotId": id, "maxRefs": PippaMCPBrowserTool.maxRefs, "maxText": PippaMCPBrowserTool.maxPageText]
        guard let raw = try? await view.callAsyncJavaScript(Self.snapshotScript, arguments: arguments, in: nil, contentWorld: world)
                as? [String: Any] else { throw BrowserError.failed }
        // The tab was closed or evicted, or its popup came or went, while the page was read: these refs are not its own.
        guard tabs[tab.key] === tab, tab.shownView === view else { throw BrowserError.staleRef }
        let refs = (raw["refs"] as? [[String: Any]] ?? []).compactMap { item -> BrowserElementRef? in
            guard let ref = item["ref"] as? String else { return nil }
            let type = item["type"] as? String
            let sensitive = (item["sensitive"] as? Bool ?? false) || type?.lowercased() == "password"
            return BrowserElementRef(ref: ref, role: item["role"] as? String ?? "", name: item["name"] as? String ?? "", type: type,
                                     value: sensitive ? nil : item["value"] as? String, sensitive: sensitive,
                                     submitsForm: item["submitsForm"] as? Bool ?? false, formAction: item["formAction"] as? String,
                                     href: item["href"] as? String)
        }
        let snapshot = BrowserSnapshot(snapshotId: id, url: (raw["url"] as? String) ?? url.absoluteString, title: raw["title"] as? String ?? "",
                                       text: raw["text"] as? String ?? "", refs: refs, truncated: raw["truncated"] as? Bool ?? false,
                                       loginDetected: raw["loginDetected"] as? Bool ?? false,
                                       captchaDetected: raw["captchaDetected"] as? Bool ?? false)
        tab.latestSnapshot = snapshot
        sync(tab)
        return snapshot
    }

    // MARK: Guards

    static let localContentRuleJSON: String = {
        let quad = "\\\\.[0-9]+\\\\.[0-9]+\\\\.[0-9]+\\\\.*[:/]"
        let pair = "\\\\.[0-9]+\\\\.[0-9]+\\\\.*[:/]"
        let hosts = [
            "[^/]*@",
            "[^./:]+\\\\.*[:/]",
            "[^/]*\\\\.localhost\\\\.*[:/]",
            "[^/]*\\\\.local\\\\.*[:/]",
            "[^/]*\\\\.internal\\\\.*[:/]",
            "[^/]*\\\\.lan\\\\.*[:/]",
            "[^/]*\\\\.home\\\\.arpa\\\\.*[:/]",
            "[^/]*\\\\.arpa\\\\.*[:/]",
            "[^/]*\\\\.localdomain\\\\.*[:/]",
            "fritz\\\\.box\\\\.*[:/]",
            "[^/]*\\\\.fritz\\\\.box\\\\.*[:/]",
            "\\\\[",
            "[0-9]+\\\\.[0-9]+\\\\.*[:/]",
            "[0-9]+\\\\.[0-9]+\\\\.[0-9]+\\\\.*[:/]",
            "0[0-9]+\\\\.[0-9]+\\\\.[0-9]+\\\\.[0-9]+\\\\.*[:/]",
            "[0-9]+\\\\.0[0-9]+\\\\.[0-9]+\\\\.[0-9]+\\\\.*[:/]",
            "[0-9]+\\\\.[0-9]+\\\\.0[0-9]+\\\\.[0-9]+\\\\.*[:/]",
            "[0-9]+\\\\.[0-9]+\\\\.[0-9]+\\\\.0[0-9]+\\\\.*[:/]",
            "0x[0-9a-f]+\\\\.[0-9]+\\\\.*[:/]",
            "0x[0-9a-f]+\\\\.0x[0-9a-f]+\\\\.*[:/]",
            "[0-9]+\\\\.0x[0-9a-f]+\\\\.*[:/]",
            "0x[0-9a-f]+\\\\.[0-9]+\\\\.[0-9]+\\\\.*[:/]",
            "[0-9]+\\\\.0x[0-9a-f]+\\\\.[0-9]+\\\\.*[:/]",
            "[0-9]+\\\\.[0-9]+\\\\.0x[0-9a-f]+\\\\.*[:/]",
            "0x[0-9a-f]+\\\\.[0-9a-fx]+\\\\.[0-9a-fx]+\\\\.[0-9a-fx]+\\\\.*[:/]",
            "[0-9]+\\\\.0x[0-9a-f]+\\\\.[0-9a-fx]+\\\\.[0-9a-fx]+\\\\.*[:/]",
            "[0-9]+\\\\.[0-9]+\\\\.0x[0-9a-f]+\\\\.[0-9a-fx]+\\\\.*[:/]",
            "[0-9]+\\\\.[0-9]+\\\\.[0-9]+\\\\.0x[0-9a-f]+\\\\.*[:/]",
            "0" + quad, "10" + quad, "127" + quad, "192\\\\.168" + pair, "169\\\\.254" + pair,
            "172\\\\.1[6-9]" + pair, "172\\\\.2[0-9]" + pair, "172\\\\.3[01]" + pair,
            "100\\\\.6[4-9]" + pair, "100\\\\.[7-9][0-9]" + pair, "100\\\\.1[01][0-9]" + pair, "100\\\\.12[0-7]" + pair,
            "22[4-9]" + quad, "23[0-9]" + quad, "24[0-9]" + quad, "25[0-5]" + quad,
        ]
        let rules = hosts.map { #"{"trigger":{"url-filter":"^[a-z]+://"# + $0 + #""},"action":{"type":"block"}}"# }
        return "[" + rules.joined(separator: ",") + "]"
    }()

    /// Subresources (images, scripts, fetch) are not navigations: block this Mac and private networks for them too.
    /// Local tabs share one content controller; the online view has its own.
    private func installRules() async throws {
        guard ruleList == nil else { return }
        if let installingRules { return try await installingRules.value }
        let task = Task { @MainActor in
            guard let list = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "PippaBrowserLocalBlock", encodedContentRuleList: Self.localContentRuleJSON) else {
                throw BrowserError.failed
            }
            if isOnline { webView.configuration.userContentController.add(list) } else { localContent.add(list) }
            ruleList = list
        }
        installingRules = task
        // A failed compile is tried again by the next caller.
        defer { installingRules = nil }
        try await task.value
    }

    private func allowNavigation(_ url: URL, in tab: Tab, mainFrame: Bool, isPopup: Bool, confirmHost: Bool = true) async -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "about" { return !isPopup }
        if !mainFrame && !isPopup && (scheme == "blob" || scheme == "data") { return true }
        guard PippaMCPBrowserTool.isAllowedURL(url), let host = PippaMCPBrowserTool.normalizedHost(url),
              !(await resolvesToPrivateAddress(host)) else {
            if mainFrame || isPopup { tab.blockedNavigation = true }
            return false
        }
        // The person's own browsing (a typed address, Open in Pippa) needs no card; neither does their sign-in.
        if confirmHost && (mainFrame || isPopup) && !tab.manualNavigation {
            guard let authorizeNavigation else {
                tab.declinedNavigation = true
                return false
            }
            if !(await authorizeNavigation(url, tab.key, tab.handoffMessage != nil)) {
                tab.declinedNavigation = true
                return false
            }
        }
        return true
    }

    private func isCrossDocumentDestination(_ url: URL, from view: WKWebView) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { return false }
        guard url.fragment != nil,
              let current = view.url,
              var destination = URLComponents(url: url, resolvingAgainstBaseURL: true),
              var currentComponents = URLComponents(url: current, resolvingAgainstBaseURL: true) else { return true }
        destination.fragment = nil
        currentComponents.fragment = nil
        return destination.string != currentComponents.string
    }

    private func isCrossDocumentHistoryDestination(_ url: URL, from view: WKWebView) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { return false }
        guard let current = view.url,
              url.fragment != nil || current.fragment != nil,
              var destination = URLComponents(url: url, resolvingAgainstBaseURL: true),
              var currentComponents = URLComponents(url: current, resolvingAgainstBaseURL: true) else { return true }
        destination.fragment = nil
        currentComponents.fragment = nil
        return destination.string != currentComponents.string
    }

    private func isCrossDocumentMainAction(_ action: WKNavigationAction, in view: WKWebView) -> Bool {
        guard !action.shouldPerformDownload, let url = action.request.url else { return false }
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { return false }
        if action.navigationType == .reload || action.navigationType == .formSubmitted
            || (action.request.httpMethod ?? "GET").uppercased() != "GET" { return true }
        return isCrossDocumentDestination(url, from: view)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // A view that left the pool (evicted, closed) loads nothing more.
        guard let tab = tab(of: webView) else { return .cancel }
        tab.pendingPolicyDecisions += 1
        defer { tab.pendingPolicyDecisions -= 1 }
        let viewID = ObjectIdentifier(webView)
        let hasActiveForView = !(tab.activeNavigations[viewID]?.isEmpty ?? true)
        guard let url = navigationAction.request.url else {
            if !hasActiveForView { tab.awaitingViews.remove(viewID) }
            return .cancel
        }
        let isPopup = navigationAction.targetFrame == nil
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        let skipConfirm = !isPopup && mainFrame && tab.preapprovedPopupURL == url
        if skipConfirm { tab.preapprovedPopupURL = nil }
        guard await allowNavigation(url, in: tab, mainFrame: mainFrame, isPopup: isPopup, confirmHost: !skipConfirm),
              tab.webView === webView || tab.popupWebView === webView else {
            let stillActive = !(tab.activeNavigations[viewID]?.isEmpty ?? true)
            if mainFrame && !isPopup && !stillActive { tab.awaitingViews.remove(viewID) }
            // A popup whose first page is refused (still empty or about:blank) closes again, back to its tab.
            if webView === tab.popupWebView, Self.pageURL(webView) == nil { closePopupView(of: tab) }
            return .cancel
        }
        if isPopup {
            tab.preapprovedPopupURL = url
            // Online, and a popup's own popups: the same view, never a new window.
            if isOnline || webView === tab.popupWebView {
                tab.awaitingViews.insert(viewID)
                webView.load(navigationAction.request)
                return .cancel
            }
            // A local tab: WebKit asks for the popup's view next (`createWebViewWith`), so `window.opener` stays.
            return .allow
        }
        let stillActive = !(tab.activeNavigations[viewID]?.isEmpty ?? true)
        if mainFrame && !stillActive && isCrossDocumentMainAction(navigationAction, in: webView) {
            tab.awaitingViews.insert(viewID)
        }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard let tab = tab(of: webView) else { return .cancel }
        tab.pendingPolicyDecisions += 1
        defer { tab.pendingPolicyDecisions -= 1 }
        guard let url = navigationResponse.response.url else { return .cancel }
        guard await allowNavigation(url, in: tab, mainFrame: navigationResponse.isForMainFrame, isPopup: false) else { return .cancel }
        return .allow
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if isOnline && challenge.protectionSpace.authenticationMethod != NSURLAuthenticationMethodServerTrust {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.performDefaultHandling, nil)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let tab = tab(of: webView) else { return nil }
        let url = navigationAction.request.url
        if isOnline || webView === tab.popupWebView {
            // Online browsing never opens a second view: the page loads in the same one, after the same checks.
            guard let url else { return nil }
            let id = UUID()
            tab.pendingPopupTasks[id] = Task { @MainActor [weak self, weak tab] in
                defer { tab?.pendingPopupTasks.removeValue(forKey: id) }
                guard let self, let tab, let view = tab.shownView, view === webView else { return }
                guard await self.allowNavigation(url, in: tab, mainFrame: true, isPopup: true), tab.shownView === view else { return }
                tab.preapprovedPopupURL = url
                tab.awaitingViews.insert(ObjectIdentifier(view))
                view.load(navigationAction.request)
            }
            return nil
        }
        // Checked now (the view is needed synchronously); its every navigation and redirect then passes
        // `allowNavigation` like the tab's own.
        if let url, url.absoluteString.lowercased() != "about:blank", !PippaMCPBrowserTool.isAllowedURL(url) {
            tab.blockedNavigation = true
            return nil
        }
        closePopupView(of: tab)
        // WebKit's own configuration: the popup shares the opener's process, so `window.opener` and `postMessage` work.
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        popup.allowsBackForwardNavigationGestures = true
        if let ruleList, popup.configuration.userContentController !== localContent {
            popup.configuration.userContentController.add(ruleList)
        }
        tab.popupWebView = popup
        tab.latestSnapshot = nil
        if tab.key == displayedKey { isOpen = true }
        publish()
        return popup
    }

    /// `window.close()` in the popup (a sign-in that finished): back to the tab's page.
    func webViewDidClose(_ webView: WKWebView) {
        guard let tab = tab(of: webView), tab.popupWebView === webView else { return }
        closePopupView(of: tab)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let tab = tab(of: webView) else { return }
        let viewID = ObjectIdentifier(webView)
        tab.awaitingViews.remove(viewID)
        if let navigation { tab.activeNavigations[viewID, default: []].insert(ObjectIdentifier(navigation)) }
        sync(tab, from: webView)
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab = tab(of: webView) else { return }
        tab.awaitingViews.remove(ObjectIdentifier(webView))
        tab.navigationProblem = nil
        // A new document: refs of the old one are gone.
        tab.latestSnapshot = nil
        sync(tab, from: webView)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab = tab(of: webView) else { return }
        let viewID = ObjectIdentifier(webView)
        tab.awaitingViews.remove(viewID)
        if let navigation { tab.activeNavigations[viewID]?.remove(ObjectIdentifier(navigation)) }
        sync(tab, from: webView)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let tab = tab(of: webView) else { return }
        let viewID = ObjectIdentifier(webView)
        tab.awaitingViews.remove(viewID)
        if let navigation { tab.activeNavigations[viewID]?.remove(ObjectIdentifier(navigation)) }
        failed(error, in: tab, from: webView)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let tab = tab(of: webView) else { return }
        let viewID = ObjectIdentifier(webView)
        tab.awaitingViews.remove(viewID)
        if let navigation { tab.activeNavigations[viewID]?.remove(ObjectIdentifier(navigation)) }
        failed(error, in: tab, from: webView)
    }

    /// A load replaced by another one (a redirect by script, a policy decision) is no failure.
    private func failed(_ error: Error, in tab: Tab, from view: WKWebView) {
        let error = error as NSError
        let replaced = (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
            || (error.domain == "WebKitErrorDomain" && error.code == 102)
        if !replaced {
            tab.navigationFailed = true
            tab.navigationProblem = T("The website couldn’t be loaded. Try again.", table: "Views")
        }
        sync(tab, from: view)
    }

    // MARK: Page scripts (isolated content world)

    private static let sharedPageHelpers = #"""
    const clean = (text, limit) => String(text || '').replace(/\s+/g, ' ').trim().slice(0, limit);
    const visible = (el) => {
      const box = el.getBoundingClientRect();
      if (box.width <= 0 || box.height <= 0) return false;
      const style = getComputedStyle(el);
      return style.visibility !== 'hidden' && style.display !== 'none' && Number(style.opacity) !== 0;
    };
    const typeOf = (el) => el.tagName === 'INPUT' ? String(el.type || 'text').toLowerCase() : null;
    const roleOf = (el) => {
      const role = el.getAttribute('role');
      if (role) return role;
      switch (el.tagName) {
        case 'A': return 'link';
        case 'BUTTON': return 'button';
        case 'SELECT': return 'combobox';
        case 'TEXTAREA': return 'textbox';
      }
      const type = typeOf(el);
      if (['button', 'submit', 'reset', 'image'].includes(type)) return 'button';
      if (type === 'checkbox' || type === 'radio') return type;
      return 'textbox';
    };
    const textFromIds = (el, attr) => {
      const ids = el.getAttribute(attr);
      if (!ids) return '';
      return ids.split(/\s+/).map((id) => {
        const target = document.getElementById(id);
        return target ? (target.innerText || target.textContent || '') : '';
      }).join(' ').trim();
    };
    const labelOf = (el) => {
      const aria = el.getAttribute('aria-label');
      if (aria) return aria;
      const by = textFromIds(el, 'aria-labelledby');
      if (by) return by;
      if (el.labels && el.labels.length) {
        const text = Array.from(el.labels).map((label) => label.innerText || label.textContent || '').join(' ').trim();
        if (text) return text;
      }
      const type = typeOf(el);
      const own = type && ['submit', 'button', 'reset'].includes(type) ? el.value : el.innerText;
      return own || el.getAttribute('placeholder') || el.getAttribute('title') || el.getAttribute('alt') || el.getAttribute('name') || '';
    };
    const isSensitive = (el) => {
      const type = typeOf(el);
      if (type === 'password') return true;
      const ac = String(el.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/).filter(Boolean);
      if (ac.some((token) => token === 'one-time-code' || token === 'current-password' || token === 'new-password')) return true;
      const nonText = ['hidden', 'button', 'submit', 'reset', 'image', 'checkbox', 'radio', 'file'];
      const isTextControl = el.tagName === 'TEXTAREA' || el.isContentEditable || (el.tagName === 'INPUT' && !nonText.includes(type));
      if (!isTextControl) return false;
      const hints = [
        labelOf(el),
        textFromIds(el, 'aria-labelledby'),
        textFromIds(el, 'aria-describedby'),
        el.getAttribute('name'),
        el.id,
        el.getAttribute('aria-label'),
        el.getAttribute('aria-description'),
        el.getAttribute('placeholder'),
        el.getAttribute('title'),
        el.labels ? Array.from(el.labels).map((l) => l.innerText || l.textContent || '').join(' ') : ''
      ].join(' ');
      return /(^|[^a-z0-9])(otp|totp|2fa|mfa|two[-_ ]?factor|2[-_ ]?factor|zwei[-_ ]?faktor|one[-_ ]?time[-_ ]?code|passcode|security[-_ ]?(code|pin)|verification[-_ ]?(code|pin)|auth[-_ ]?code|best[aä]tigungscode|einmalcode|sicherheitscode|tan)([^a-z0-9]|$)/i.test(hints);
    };
    const selectSignature = (el) => el.tagName === 'SELECT'
      ? Array.from(el.options).map((o) => o.value + ':' + o.text.trim()).join('\n')
      : null;
    const resolvedHref = (el) => {
      if (!el) return null;
      if (typeof el.href === 'string') return el.href;
      return el.href && typeof el.href.baseVal === 'string' ? el.href.baseVal : null;
    };
    const resolvedFormAction = (el) => {
      if (typeof el.formAction === 'string' && el.hasAttribute('formaction')) return el.formAction;
      if (el.form) return String(Object.getOwnPropertyDescriptor(HTMLFormElement.prototype, 'action')?.get?.call(el.form) ?? '');
      if (typeof el.action === 'string') return el.action;
      return null;
    };
    const metaOf = (el) => ({
      url: location.href,
      baseURI: document.baseURI,
      baseTarget: document.querySelector('base[target]')?.getAttribute('target') ?? null,
      tagName: el.tagName,
      role: roleOf(el),
      type: typeOf(el),
      buttonType: el.tagName === 'BUTTON' ? String(el.type || 'submit').toLowerCase() : null,
      name: clean(labelOf(el), 80),
      hrefAttr: el.getAttribute('href'),
      href: resolvedHref(el),
      ancestorHref: resolvedHref(el.closest('a[href]')),
      formactionAttr: el.getAttribute('formaction'),
      formAction: resolvedFormAction(el),
      formActionAttr: el.form ? (el.form.getAttribute('action') ?? '') : null,
      target: el.getAttribute('target'),
      formTarget: el.getAttribute('formtarget'),
      formTargetAttr: el.form ? (el.form.getAttribute('target') ?? '') : null,
      options: selectSignature(el),
    });
    """#

    /// Up to `maxRefs` visible interactive elements, bounded readable text, login/2FA and CAPTCHA signs. Sensitive
    /// values (passwords and verification codes) are never read.
    static let snapshotScript = sharedPageHelpers + #"""
    const selector = 'a[href], button, input, select, textarea, [role=button], [role=link], [role=textbox], [role=checkbox], [role=combobox]';
    const refs = new Map();
    const meta = new Map();
    const out = [];
    let login = false;
    for (const el of document.querySelectorAll(selector)) {
      const type = typeOf(el);
      if (type === 'hidden' || el.disabled || !visible(el)) continue;
      const sensitive = isSensitive(el);
      if (sensitive) login = true;
      if (out.length >= maxRefs) continue;
      const ref = '@e' + (out.length + 1);
      const captured = metaOf(el);
      refs.set(ref, el);
      meta.set(ref, captured);
      let name = captured.name;
      let value = null;
      if (sensitive) value = null;
      else if (el.tagName === 'SELECT') {
        value = el.options[el.selectedIndex]?.text ?? null;
        const options = Array.from(el.options).slice(0, 8).map((option) => clean(option.text, 30)).filter(Boolean);
        if (options.length) name = clean(name + ' [' + options.join(' | ') + ']', 160);
      } else if (type === 'checkbox' || type === 'radio') value = el.checked ? 'checked' : 'unchecked';
      else if (el.tagName === 'TEXTAREA' || (type && !['submit', 'button', 'reset', 'image'].includes(type))) value = el.value || null;
      const submitsForm = Boolean(
        (el.form || captured.formactionAttr !== null) &&
        ((el.tagName === 'BUTTON' && captured.buttonType === 'submit') ||
         (el.tagName === 'INPUT' && (captured.type === 'submit' || captured.type === 'image'))));
      out.push({
        ref, role: captured.role, name, type, sensitive, value: value == null ? null : clean(value, 80),
        submitsForm, formAction: submitsForm ? captured.formAction : null, href: captured.href || captured.ancestorHref || null,
      });
    }
    window.__pippaRefs = refs;
    window.__pippaRefMeta = meta;
    window.__pippaSnapshot = snapshotId;
    const body = String(document.body ? document.body.innerText : '').replace(/[ \t\f\v\u00a0]+/g, ' ').replace(/\s*\n\s*/g, '\n').trim().slice(0, maxText + 1);
    const captchaFrame = Array.from(document.querySelectorAll('iframe')).some((frame) =>
      /recaptcha|hcaptcha|turnstile|challenges\.cloudflare\.com|captcha/i.test(frame.src || ''));
    const captcha = captchaFrame || !!document.querySelector('.g-recaptcha, .h-captcha, .cf-turnstile, [id*="captcha" i], [class*="captcha" i]');
    return {
      url: location.href, title: clean(document.title, 200), text: body.slice(0, maxText), truncated: body.length > maxText,
      refs: out, loginDetected: login, captchaDetected: captcha,
    };
    """#

    /// One click, fill or select, or a whole form (`kind` "form": every field of `fields`, then a click on `ref` when it
    /// is set), on elements of exactly this snapshot whose meaning hasn't changed. Every element is checked before the
    /// first one changes. Never fills password or verification-code fields.
    static let actionScript = sharedPageHelpers + #"""
    if (window.__pippaSnapshot !== snapshotId || !window.__pippaRefs || !window.__pippaRefMeta) return { error: 'stale' };
    const resolve = (key) => {
      if (window.__pippaSnapshot !== snapshotId) return null;
      const el = window.__pippaRefs.get(key);
      const expected = window.__pippaRefMeta.get(key);
      if (!el || !expected || !el.isConnected || el.disabled || !visible(el)) return null;
      const current = metaOf(el);
      for (const name of Object.keys(expected)) {
        if (current[name] !== expected[name]) return null;
      }
      return el;
    };
    const optionFor = (el, wanted) => Array.from(el.options).find((o) => o.value === wanted || o.text.trim() === wanted.trim());
    const problem = (el, step) => {
      if (step.kind === 'fill') {
        if (isSensitive(el)) return 'password';
        if (el.isContentEditable) return null;
        const setter = Object.getOwnPropertyDescriptor(el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype, 'value')?.set;
        return setter && (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) ? null : 'failed';
      }
      if (step.kind === 'select') return el.tagName === 'SELECT' && optionFor(el, step.text) ? null : 'option';
      return null;
    };
    const fire = (el) => {
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    };
    const apply = (el, step) => {
      if (step.kind === 'fill') {
        el.focus();
        if (el.isContentEditable) el.textContent = step.text;
        else Object.getOwnPropertyDescriptor(el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype, 'value').set.call(el, step.text);
        fire(el);
      } else if (step.kind === 'select') {
        el.value = optionFor(el, step.text).value;
        fire(el);
      } else {
        el.scrollIntoView({ block: 'center' });
        el.click();
      }
    };
    const steps = kind === 'form' ? fields.map((field) => ({ ref: field.ref, kind: field.kind, text: field.text })) : [{ ref, kind, text }];
    const submit = kind === 'form' && ref ? { ref, kind: 'click', text: '' } : null;
    const targets = [];
    for (const step of submit ? steps.concat([submit]) : steps) {
      const el = resolve(step.ref);
      if (!el) return { error: 'stale' };
      const why = problem(el, step);
      if (why) return { error: why };
      targets.push([el, step]);
    }
    const button = submit ? targets.pop()[0] : null;
    // Typing runs the page's own scripts: before each further step the element must still be the one the card
    // named (same meaning, still not a password or code field), or the step stops there.
    for (const [index, [el, step]] of targets.entries()) {
      if (index > 0 && (resolve(step.ref) !== el || problem(el, step))) return { error: 'failed' };
      apply(el, step);
    }
    if (submit) {
      // Pages often re-render after typing: give them a moment, then click only the very same, unchanged button.
      await new Promise((done) => setTimeout(done, 150));
      if (resolve(submit.ref) !== button) return { error: 'failed' };
      apply(button, submit);
    }
    return { ok: true };
    """#
}
