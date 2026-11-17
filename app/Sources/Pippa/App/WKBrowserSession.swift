import AppKit
import PippaCore
import WebKit

/// Pippa's browser panel: one persistent `WKWebView` that `browse` (PippaMCPBrowser.swift) drives and the person can
/// see and use. Cookies and logins persist in the default website data store, so the person signs in once, here.
///
/// Guards: every navigation in every frame passes `PippaMCPBrowserTool.isAllowedURL` (no `file:`, no this Mac, no local
/// network, also after redirects); a content rule list blocks local-network subresources; `target="_blank"` opens in
/// this same view. Snapshots and actions run in an isolated content world, so page scripts cannot read or forge
/// Pippa's element refs, and password values are never captured.
@MainActor
final class WKBrowserSession: NSObject, ObservableObject, BrowserOperating, WKNavigationDelegate, WKUIDelegate {
    static let shared = WKBrowserSession()

    @Published var isOpen = false
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
    private var pendingPopupTask: Task<Void, Never>?
    private let world = WKContentWorld.world(name: "PippaBrowser")

    /// Gates main-frame destinations and popups through turn-scoped host approvals and confirmation.
    var authorizeNavigation: (@MainActor (_ url: URL) async -> Bool)?

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: configuration)
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

    func goBack() { if webView.canGoBack { webView.goBack() } }
    func reload() { if currentURL != nil { webView.reload() } }
    func stop() { webView.stopLoading() }

    private func sync() {
        let url = webView.url.flatMap { $0.scheme?.lowercased() == "about" ? nil : $0 }
        currentURL = url
        pageTitle = url == nil ? "" : webView.title ?? ""
        isLoading = webView.isLoading
        canGoBack = webView.canGoBack
    }

    // MARK: BrowserOperating

    func currentSnapshot() async -> BrowserSnapshot? { latest }

    func perform(_ action: BrowserAction) async throws -> BrowserSnapshot? {
        switch action {
        case .open(let url):
            guard PippaMCPBrowserTool.isAllowedURL(url), let host = PippaMCPBrowserTool.normalizedHost(url) else {
                throw BrowserError.blockedAddress
            }
            if await PippaMCPBrowserTool.resolvesToPrivateAddress(host) { throw BrowserError.blockedAddress }
            try await installRules()
            isOpen = true
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
            if webView.canGoBack { webView.goBack(); await settle(after: .milliseconds(150), timeout: .seconds(10)) }
            if blockedNavigation { throw BrowserError.blockedAddress }
            if declinedNavigation { throw BrowserError.declinedNavigation }
        case .close:
            webView.stopLoading()
            pendingPopupTask?.cancel()
            pendingPopupTask = nil
            latest = nil
            handoffMessage = nil
            isOpen = false
            webView.load(URLRequest(url: URL(string: "about:blank")!))
            sync()
            return nil
        }
        return try await capture()
    }

    /// Waits for the page to load (bounded), so a snapshot sees the result of a click or an address.
    private func settle(after delay: Duration, timeout: Duration) async {
        try? await Task.sleep(for: delay)
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let popup = pendingPopupTask {
                pendingPopupTask = nil
                await popup.value
            }
            if !webView.isLoading { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // Scripts often render after load; a short pause catches most of it.
        try? await Task.sleep(for: .milliseconds(250))
        if let popup = pendingPopupTask {
            pendingPopupTask = nil
            await popup.value
            while webView.isLoading, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        }
        sync()
    }

    private func act(_ kind: String, ref: String, snapshotId: String?, text: String) async throws {
        guard currentURL != nil else { throw BrowserError.nothingOpen }
        guard let snapshotId = snapshotId ?? latest?.snapshotId else { throw BrowserError.staleRef }
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
        blockedNavigation = false; declinedNavigation = false; navigationFailed = false
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
            "0x[0-9a-f]+\\\\.[0-9a-fx]+\\\\.*[:/]",
            "0x[0-9a-f]+\\\\.[0-9a-fx]+\\\\.[0-9a-fx]+\\\\.*[:/]",
            "0x[0-9a-f]+\\\\.[0-9a-fx]+\\\\.[0-9a-fx]+\\\\.[0-9a-fx]+\\\\.*[:/]",
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
        guard let list = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "PippaBrowserLocalBlock", encodedContentRuleList: Self.localContentRuleJSON) else {
            throw BrowserError.failed
        }
        webView.configuration.userContentController.add(list)
        rulesInstalled = true
    }

    private func allowNavigation(_ url: URL, mainFrame: Bool, isPopup: Bool) async -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "about" { return !isPopup }
        if !mainFrame && !isPopup && (scheme == "blob" || scheme == "data") { return true }
        guard PippaMCPBrowserTool.isAllowedURL(url), let host = PippaMCPBrowserTool.normalizedHost(url),
              !(await PippaMCPBrowserTool.resolvesToPrivateAddress(host)) else {
            if mainFrame || isPopup { blockedNavigation = true }
            return false
        }
        if mainFrame || isPopup {
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

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        let isPopup = navigationAction.targetFrame == nil
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        guard await allowNavigation(url, mainFrame: mainFrame, isPopup: isPopup) else { return .cancel }
        // `target="_blank"` and window.open: the same view, never a new window.
        if isPopup {
            webView.load(navigationAction.request)
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard let url = navigationResponse.response.url else { return .cancel }
        guard await allowNavigation(url, mainFrame: navigationResponse.isForMainFrame, isPopup: false) else { return .cancel }
        return .allow
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        pendingPopupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.allowNavigation(url, mainFrame: true, isPopup: true) else { return }
            self.webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { sync() }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // A new document: refs of the old one are gone.
        latest = nil
        sync()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { sync() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }

    /// A load replaced by another one (a redirect by script, a policy decision) is no failure.
    private func failed(_ error: Error) {
        let error = error as NSError
        let replaced = (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
            || (error.domain == "WebKitErrorDomain" && error.code == 102)
        if !replaced { navigationFailed = true }
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
    const labelOf = (el) => {
      const aria = el.getAttribute('aria-label');
      if (aria) return aria;
      const by = el.getAttribute('aria-labelledby');
      if (by) {
        const text = by.split(/\s+/).map((id) => document.getElementById(id)?.innerText || '').join(' ').trim();
        if (text) return text;
      }
      if (el.labels && el.labels.length) {
        const text = Array.from(el.labels).map((label) => label.innerText).join(' ').trim();
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
      const hints = [el.getAttribute('name'), el.id, el.getAttribute('aria-label'), el.getAttribute('placeholder'),
                     el.labels ? Array.from(el.labels).map((l) => l.innerText).join(' ') : ''].join(' ');
      return /(^|[^a-z0-9])(otp|totp|2fa|mfa|one[-_ ]?time[-_ ]?code|passcode|security[-_ ]?code|verification[-_ ]?code|auth[-_ ]?code|best[aä]tigungscode|einmalcode|sicherheitscode|tan)([^a-z0-9]|$)/i.test(hints);
    };
    const selectSignature = (el) => el.tagName === 'SELECT'
      ? Array.from(el.options).map((o) => o.value + ':' + o.text.trim()).join('\n')
      : null;
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
      const baseName = clean(labelOf(el), 80);
      const role = roleOf(el);
      refs.set(ref, el);
      meta.set(ref, {
        url: location.href,
        tagName: el.tagName,
        role,
        type,
        name: baseName,
        href: el.getAttribute('href'),
        formaction: el.getAttribute('formaction'),
        formAction: el.form ? (el.form.getAttribute('action') ?? '') : null,
        options: selectSignature(el),
      });
      let name = baseName;
      let value = null;
      if (sensitive) value = null;
      else if (el.tagName === 'SELECT') {
        value = el.options[el.selectedIndex]?.text ?? null;
        const options = Array.from(el.options).slice(0, 8).map((option) => clean(option.text, 30)).filter(Boolean);
        if (options.length) name = clean(name + ' [' + options.join(' | ') + ']', 160);
      } else if (type === 'checkbox' || type === 'radio') value = el.checked ? 'checked' : 'unchecked';
      else if (el.tagName === 'TEXTAREA' || (type && !['submit', 'button', 'reset', 'image'].includes(type))) value = el.value || null;
      out.push({ ref, role, name, type, sensitive, value: value == null ? null : clean(value, 80) });
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
    if (location.href !== expected.url) return { error: 'stale' };
    if (el.tagName !== expected.tagName || roleOf(el) !== expected.role || typeOf(el) !== expected.type) return { error: 'stale' };
    if (clean(labelOf(el), 80) !== expected.name) return { error: 'stale' };
    if ((el.getAttribute('href') ?? null) !== expected.href) return { error: 'stale' };
    if ((el.getAttribute('formaction') ?? null) !== expected.formaction) return { error: 'stale' };
    if ((el.form ? (el.form.getAttribute('action') ?? '') : null) !== expected.formAction) return { error: 'stale' };
    if (selectSignature(el) !== expected.options) return { error: 'stale' };
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
