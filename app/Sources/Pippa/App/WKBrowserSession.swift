import AppKit
import PippaCore
import WebKit

/// The local panel uses a persistent `WKWebView` the person can see and use. Each online answer gets an offscreen view
/// with a fresh nonpersistent website data store.
///
/// Guards: every navigation in every frame passes `PippaMCPBrowserTool.isAllowedURL` (no `file:`, no this Mac, no local
/// network, also after redirects); a content rule list blocks local-network subresources; `target="_blank"` opens in
/// this same view. Snapshots and actions run in an isolated content world, so page scripts cannot read or forge
/// Pippa's element refs, and password values are never captured.
@MainActor
final class WKBrowserSession: NSObject, ObservableObject, BrowserOperating, WKNavigationDelegate, WKUIDelegate {
    static let shared = WKBrowserSession()

    @Published var isOpen = false
    @Published private(set) var navigationProblem: String?
    private var manualNavigation = false
    private var modelActions = 0
    @Published private(set) var currentURL: URL?
    @Published private(set) var pageTitle = ""
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    /// The person's step (login, 2FA, CAPTCHA), shown as a banner over the page until they click Done.
    @Published var handoffMessage: String?

    private(set) lazy var webView: WKWebView = makeWebView()
    private var latest: BrowserSnapshot?
    private var counter = 0
    private var blockedNavigation = false
    private var declinedNavigation = false
    private var navigationFailed = false
    private var rulesInstalled = false
    /// The rule list being compiled: concurrent callers wait for it, so it is added to the view only once.
    private var installingRules: Task<Void, Error>?
    private var pendingPolicyDecisions = 0
    private var pendingPopupTasks: [UUID: Task<Void, Never>] = [:]
    private var preapprovedPopupURL: URL?
    private var awaitingNavigationStart = false
    private var activeNavigations: Set<ObjectIdentifier> = []
    private let world = WKContentWorld.world(name: "PippaBrowser")
    private let onlineConfiguration: WKWebViewConfiguration?
    private var isOnline: Bool { onlineConfiguration != nil }

    private init(onlineConfiguration: WKWebViewConfiguration? = nil) {
        self.onlineConfiguration = onlineConfiguration
    }

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

    /// Gates main-frame destinations and popups through turn-scoped host approvals and confirmation.
    var authorizeNavigation: (@MainActor (_ url: URL) async -> Bool)?

    private func makeWebView() -> WKWebView {
        let configuration = onlineConfiguration ?? WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let viewport: CGRect = isOnline ? CGRect(x: 0, y: 0, width: 1024, height: 768) : .zero
        let view = WKWebView(frame: viewport, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        return view
    }

    // MARK: Panel

    func showHandoff(_ message: String) {
        handoffMessage = message
        isOpen = true
    }

    /// A web address typed by the person uses the panel without requiring an active AI turn.
    func navigateManually(_ text: String) async {
        guard !isOnline else { return }
        guard modelActions == 0, !ChatModel.shared.isAnswering else {
            navigationProblem = T("Wait for Pippa to finish before opening a website.", table: "Views")
            return
        }
        navigationProblem = nil
        guard let url = Self.webAddress(text),
              let host = PippaMCPBrowserTool.normalizedHost(url),
              !(await PippaMCPBrowserTool.resolvesToPrivateAddress(host)) else {
            navigationProblem = T("Enter a public website address, such as https://example.com.", table: "Views")
            return
        }
        do { try await installRules() }
        catch { navigationProblem = T("The website couldn’t be loaded. Try again.", table: "Views"); return }
        guard modelActions == 0, !ChatModel.shared.isAnswering else {
            navigationProblem = T("Wait for Pippa to finish before opening a website.", table: "Views")
            return
        }
        manualNavigation = true
        isOpen = true
        webView.load(URLRequest(url: url))
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

    func goBack() { if webView.canGoBack { webView.goBack() } }
    func reload() { if currentURL != nil { webView.reload() } }
    func stop() { webView.stopLoading() }

    private func sync() {
        let url = webView.url.flatMap { $0.scheme?.lowercased() == "about" ? nil : $0 }
        // Navigation callbacks fire often with nothing new: assign only changes, so SwiftUI redraws only then.
        let title = url == nil ? "" : webView.title ?? ""
        if currentURL != url { currentURL = url }
        if pageTitle != title { pageTitle = title }
        if isLoading != webView.isLoading { isLoading = webView.isLoading }
        if canGoBack != webView.canGoBack { canGoBack = webView.canGoBack }
    }

    // MARK: BrowserOperating

    func currentSnapshot() async -> BrowserSnapshot? { latest }

    func perform(_ action: BrowserAction) async throws -> BrowserSnapshot? {
        modelActions += 1
        defer { modelActions -= 1 }
        manualNavigation = false
        navigationProblem = nil
        switch action {
        case .open(let url):
            guard PippaMCPBrowserTool.isAllowedURL(url), let host = PippaMCPBrowserTool.normalizedHost(url) else {
                throw BrowserError.blockedAddress
            }
            if await PippaMCPBrowserTool.resolvesToPrivateAddress(host) { throw BrowserError.blockedAddress }
            try await installRules()
            if !isOnline { isOpen = true }
            preapprovedPopupURL = nil
            awaitingNavigationStart = isCrossDocumentDestination(url)
            blockedNavigation = false; declinedNavigation = false; navigationFailed = false
            webView.load(URLRequest(url: url))
            await settle(after: .milliseconds(150), timeout: .seconds(15))
            if blockedNavigation { throw BrowserError.blockedAddress }
            if declinedNavigation { throw BrowserError.declinedNavigation }
            if navigationFailed { throw BrowserError.failed }
        case .snapshot:
            break
        case .click(let ref, let snapshotId):
            try await act("click", ref: ref, snapshotId: snapshotId, text: "")
        case .fill(let ref, let text, let snapshotId):
            try await act("fill", ref: ref, snapshotId: snapshotId, text: text)
        case .select(let ref, let value, let snapshotId):
            try await act("select", ref: ref, snapshotId: snapshotId, text: value)
        case .back:
            guard currentURL != nil else { throw BrowserError.nothingOpen }
            blockedNavigation = false; declinedNavigation = false; navigationFailed = false
            if webView.canGoBack {
                if let backURL = webView.backForwardList.backItem?.url, isCrossDocumentHistoryDestination(backURL) {
                    awaitingNavigationStart = true
                }
                webView.goBack()
                await settle(after: .milliseconds(150), timeout: .seconds(10))
            }
            if blockedNavigation { throw BrowserError.blockedAddress }
            if declinedNavigation { throw BrowserError.declinedNavigation }
        case .close:
            webView.stopLoading()
            for task in pendingPopupTasks.values { task.cancel() }
            pendingPopupTasks.removeAll()
            preapprovedPopupURL = nil
            awaitingNavigationStart = false
            activeNavigations.removeAll()
            latest = nil
            handoffMessage = nil
            isOpen = false
            webView.load(URLRequest(url: URL(string: "about:blank")!))
            sync()
            return nil
        }
        return try await capture()
    }

    private func drainPending(timeout: Duration) async {
        var deadline = ContinuousClock.now + timeout
        while !Task.isCancelled {
            if !pendingPopupTasks.isEmpty {
                for task in Array(pendingPopupTasks.values) { await task.value }
                // Confirmation or popup waits do not consume the post-approval page-load timeout.
                deadline = ContinuousClock.now + timeout
                continue
            }
            if pendingPolicyDecisions > 0 {
                try? await Task.sleep(for: .milliseconds(50))
                deadline = ContinuousClock.now + timeout
                continue
            }
            if awaitingNavigationStart || !activeNavigations.isEmpty || webView.isLoading, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            break
        }
    }

    /// Waits for confirmations, popups and page loads (bounded after approval), so the tool sees any navigation decision.
    private func settle(after delay: Duration, timeout: Duration) async {
        try? await Task.sleep(for: delay)
        await drainPending(timeout: timeout)
        // Scripts often render or navigate after load; a short pause catches most of it.
        try? await Task.sleep(for: .milliseconds(250))
        await drainPending(timeout: timeout)
        sync()
    }

    private func act(_ kind: String, ref: String, snapshotId: String?, text: String) async throws {
        guard currentURL != nil else { throw BrowserError.nothingOpen }
        guard let snapshotId = snapshotId ?? latest?.snapshotId else { throw BrowserError.staleRef }
        awaitingNavigationStart = false
        blockedNavigation = false; declinedNavigation = false; navigationFailed = false
        let reply = try? await webView.callAsyncJavaScript(Self.actionScript, arguments: ["kind": kind, "ref": ref, "snapshotId": snapshotId, "text": text],
                                                           in: nil, contentWorld: world) as? [String: Any]
        switch reply?["error"] as? String {
        case nil where reply?["ok"] as? Bool == true: break
        case "stale": throw BrowserError.staleRef
        case "password": throw BrowserError.passwordField
        case "option": throw BrowserError.noSuchOption
        default: throw BrowserError.failed
        }
        latest = nil
        await settle(after: .milliseconds(400), timeout: .seconds(10))
        if blockedNavigation { throw BrowserError.blockedAddress }
        if declinedNavigation { throw BrowserError.declinedNavigation }
    }

    private func capture() async throws -> BrowserSnapshot {
        guard let url = currentURL else { throw BrowserError.nothingOpen }
        counter += 1
        let id = "s\(counter)-" + UUID().uuidString.prefix(8).lowercased()
        let arguments: [String: Any] = ["snapshotId": id, "maxRefs": PippaMCPBrowserTool.maxRefs, "maxText": PippaMCPBrowserTool.maxText]
        guard let raw = try? await webView.callAsyncJavaScript(Self.snapshotScript, arguments: arguments, in: nil, contentWorld: world)
                as? [String: Any] else { throw BrowserError.failed }
        let refs = (raw["refs"] as? [[String: Any]] ?? []).compactMap { item -> BrowserElementRef? in
            guard let ref = item["ref"] as? String else { return nil }
            let type = item["type"] as? String
            let sensitive = (item["sensitive"] as? Bool ?? false) || type?.lowercased() == "password"
            return BrowserElementRef(ref: ref, role: item["role"] as? String ?? "", name: item["name"] as? String ?? "", type: type,
                                     value: sensitive ? nil : item["value"] as? String, sensitive: sensitive)
        }
        let snapshot = BrowserSnapshot(snapshotId: id, url: (raw["url"] as? String) ?? url.absoluteString, title: raw["title"] as? String ?? "",
                                       text: raw["text"] as? String ?? "", refs: refs, truncated: raw["truncated"] as? Bool ?? false,
                                       loginDetected: raw["loginDetected"] as? Bool ?? false,
                                       captchaDetected: raw["captchaDetected"] as? Bool ?? false)
        latest = snapshot
        sync()
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
    private func installRules() async throws {
        guard !rulesInstalled else { return }
        if let installingRules { return try await installingRules.value }
        let task = Task { @MainActor in
            guard let list = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "PippaBrowserLocalBlock", encodedContentRuleList: Self.localContentRuleJSON) else {
                throw BrowserError.failed
            }
            webView.configuration.userContentController.add(list)
            rulesInstalled = true
        }
        installingRules = task
        // A failed compile is tried again by the next caller.
        defer { installingRules = nil }
        try await task.value
    }

    private func allowNavigation(_ url: URL, mainFrame: Bool, isPopup: Bool, confirmHost: Bool = true) async -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "about" { return !isPopup }
        if !mainFrame && !isPopup && (scheme == "blob" || scheme == "data") { return true }
        guard PippaMCPBrowserTool.isAllowedURL(url), let host = PippaMCPBrowserTool.normalizedHost(url),
              !(await PippaMCPBrowserTool.resolvesToPrivateAddress(host)) else {
            if mainFrame || isPopup { blockedNavigation = true }
            return false
        }
        if confirmHost && (mainFrame || isPopup) && !manualNavigation {
            guard let authorizeNavigation else {
                declinedNavigation = true
                return false
            }
            if !(await authorizeNavigation(url)) {
                declinedNavigation = true
                return false
            }
        }
        return true
    }

    private func isCrossDocumentDestination(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { return false }
        guard url.fragment != nil,
              let current = webView.url,
              var destination = URLComponents(url: url, resolvingAgainstBaseURL: true),
              var currentComponents = URLComponents(url: current, resolvingAgainstBaseURL: true) else { return true }
        destination.fragment = nil
        currentComponents.fragment = nil
        return destination.string != currentComponents.string
    }

    private func isCrossDocumentHistoryDestination(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { return false }
        guard let current = webView.url,
              url.fragment != nil || current.fragment != nil,
              var destination = URLComponents(url: url, resolvingAgainstBaseURL: true),
              var currentComponents = URLComponents(url: current, resolvingAgainstBaseURL: true) else { return true }
        destination.fragment = nil
        currentComponents.fragment = nil
        return destination.string != currentComponents.string
    }

    private func isCrossDocumentMainAction(_ action: WKNavigationAction) -> Bool {
        guard !action.shouldPerformDownload, let url = action.request.url else { return false }
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { return false }
        if action.navigationType == .reload || action.navigationType == .formSubmitted
            || (action.request.httpMethod ?? "GET").uppercased() != "GET" { return true }
        return isCrossDocumentDestination(url)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        pendingPolicyDecisions += 1
        defer { pendingPolicyDecisions -= 1 }
        guard let url = navigationAction.request.url else {
            if activeNavigations.isEmpty { awaitingNavigationStart = false }
            return .cancel
        }
        let isPopup = navigationAction.targetFrame == nil
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        let skipConfirm = !isPopup && mainFrame && preapprovedPopupURL == url
        if skipConfirm { preapprovedPopupURL = nil }
        guard await allowNavigation(url, mainFrame: mainFrame, isPopup: isPopup, confirmHost: !skipConfirm) else {
            if mainFrame && !isPopup && activeNavigations.isEmpty { awaitingNavigationStart = false }
            return .cancel
        }
        // `target="_blank"` and window.open: the same view, never a new window.
        if isPopup {
            preapprovedPopupURL = url
            awaitingNavigationStart = true
            webView.load(navigationAction.request)
            return .cancel
        }
        if mainFrame && activeNavigations.isEmpty && isCrossDocumentMainAction(navigationAction) {
            awaitingNavigationStart = true
        }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        pendingPolicyDecisions += 1
        defer { pendingPolicyDecisions -= 1 }
        guard let url = navigationResponse.response.url else { return .cancel }
        guard await allowNavigation(url, mainFrame: navigationResponse.isForMainFrame, isPopup: false) else { return .cancel }
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
        guard let url = navigationAction.request.url else { return nil }
        let id = UUID()
        pendingPopupTasks[id] = Task { @MainActor [weak self] in
            defer { self?.pendingPopupTasks.removeValue(forKey: id) }
            guard let self else { return }
            guard await self.allowNavigation(url, mainFrame: true, isPopup: true) else { return }
            self.preapprovedPopupURL = url
            self.awaitingNavigationStart = true
            self.webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        awaitingNavigationStart = false
        if let navigation { activeNavigations.insert(ObjectIdentifier(navigation)) }
        sync()
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        awaitingNavigationStart = false
        navigationProblem = nil
        // A new document: refs of the old one are gone.
        latest = nil
        sync()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        awaitingNavigationStart = false
        if let navigation { activeNavigations.remove(ObjectIdentifier(navigation)) }
        sync()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        awaitingNavigationStart = false
        if let navigation { activeNavigations.remove(ObjectIdentifier(navigation)) }
        failed(error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        awaitingNavigationStart = false
        if let navigation { activeNavigations.remove(ObjectIdentifier(navigation)) }
        failed(error)
    }

    /// A load replaced by another one (a redirect by script, a policy decision) is no failure.
    private func failed(_ error: Error) {
        let error = error as NSError
        let replaced = (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
            || (error.domain == "WebKitErrorDomain" && error.code == 102)
        if !replaced {
            navigationFailed = true
            navigationProblem = T("The website couldn’t be loaded. Try again.", table: "Views")
        }
        sync()
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
      out.push({ ref, role: captured.role, name, type, sensitive, value: value == null ? null : clean(value, 80) });
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

    /// One click, fill or select on an element of exactly this snapshot whose meaning hasn't changed. Never fills
    /// password or verification-code fields.
    static let actionScript = sharedPageHelpers + #"""
    if (window.__pippaSnapshot !== snapshotId || !window.__pippaRefs || !window.__pippaRefMeta) return { error: 'stale' };
    const el = window.__pippaRefs.get(ref);
    const expected = window.__pippaRefMeta.get(ref);
    if (!el || !expected || !el.isConnected || el.disabled || !visible(el)) return { error: 'stale' };
    const current = metaOf(el);
    for (const key of Object.keys(expected)) {
      if (current[key] !== expected[key]) return { error: 'stale' };
    }
    const fire = () => {
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    };
    if (kind === 'fill') {
      if (isSensitive(el)) return { error: 'password' };
      el.focus();
      if (el.isContentEditable) el.textContent = text;
      else {
        const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
        if (!setter || !(el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement)) return { error: 'failed' };
        setter.call(el, text);
      }
      fire();
    } else if (kind === 'select') {
      if (el.tagName !== 'SELECT') return { error: 'option' };
      const option = Array.from(el.options).find((o) => o.value === text || o.text.trim() === text.trim());
      if (!option) return { error: 'option' };
      el.value = option.value;
      fire();
    } else {
      el.scrollIntoView({ block: 'center' });
      el.click();
    }
    return { ok: true };
    """#
}
