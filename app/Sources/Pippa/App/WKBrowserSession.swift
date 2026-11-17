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
    private var navigationFailed = false
    private var rulesInstalled = false
    private let world = WKContentWorld.world(name: "PippaBrowser")

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
            guard PippaMCPBrowserTool.isAllowedURL(url) else { throw BrowserError.blockedAddress }
            await installRules()
            isOpen = true
            blockedNavigation = false; navigationFailed = false
            webView.load(URLRequest(url: url))
            await settle(after: .milliseconds(150), timeout: .seconds(15))
            if blockedNavigation { throw BrowserError.blockedAddress }
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
            if webView.canGoBack { webView.goBack(); await settle(after: .milliseconds(150), timeout: .seconds(10)) }
        case .close:
            webView.stopLoading()
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
        while webView.isLoading, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        // Scripts often render after load; a short pause catches most of it.
        try? await Task.sleep(for: .milliseconds(250))
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
        await settle(after: .milliseconds(400), timeout: .seconds(10))
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
            return BrowserElementRef(ref: ref, role: item["role"] as? String ?? "", name: item["name"] as? String ?? "", type: type,
                                     value: type?.lowercased() == "password" ? nil : item["value"] as? String)
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

    /// Subresources (images, scripts, fetch) are not navigations: block this Mac and private networks for them too.
    private func installRules() async {
        guard !rulesInstalled else { return }
        rulesInstalled = true
        let quad = "\\\\.[0-9]+\\\\.[0-9]+\\\\.[0-9]+[:/]", pair = "\\\\.[0-9]+\\\\.[0-9]+[:/]"
        let hosts = ["localhost[:/]", "[^/]*\\\\.localhost[:/]", "[^/]*\\\\.local[:/]", "\\\\[", "[0-9]+[:/]",
                     "0" + quad, "10" + quad, "127" + quad, "192\\\\.168" + pair, "169\\\\.254" + pair,
                     "172\\\\.1[6-9]" + pair, "172\\\\.2[0-9]" + pair, "172\\\\.3[01]" + pair,
                     "100\\\\.6[4-9]" + pair, "100\\\\.[7-9][0-9]" + pair, "100\\\\.1[01][0-9]" + pair, "100\\\\.12[0-7]" + pair]
        let rules = hosts.map { #"{"trigger":{"url-filter":"^[a-z]+://"# + $0 + #""},"action":{"type":"block"}}"# }
        guard let list = try? await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "PippaBrowserLocalBlock", encodedContentRuleList: "[" + rules.joined(separator: ",") + "]") else { return }
        webView.configuration.userContentController.add(list)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        let scheme = url.scheme?.lowercased() ?? ""
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if scheme == "about" { return .allow }
        if !mainFrame && (scheme == "blob" || scheme == "data") { return .allow }
        guard PippaMCPBrowserTool.isAllowedURL(url) else {
            if mainFrame { blockedNavigation = true }
            return .cancel
        }
        // `target="_blank"` and window.open: the same view, never a new window.
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, PippaMCPBrowserTool.isAllowedURL(url) { webView.load(navigationAction.request) }
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

    /// Up to `maxRefs` visible interactive elements, bounded readable text, login and CAPTCHA signs. Password values
    /// are never read.
    static let snapshotScript = #"""
    const selector = 'a[href], button, input, select, textarea, [role=button], [role=link], [role=textbox], [role=checkbox], [role=combobox]';
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
    const refs = new Map();
    const out = [];
    let login = false;
    for (const el of document.querySelectorAll(selector)) {
      const type = typeOf(el);
      if (type === 'hidden' || el.disabled || !visible(el)) continue;
      if (type === 'password') login = true;
      if (out.length >= maxRefs) continue;
      const ref = '@e' + (out.length + 1);
      refs.set(ref, el);
      let name = clean(labelOf(el), 80);
      let value = null;
      if (type === 'password') value = null;
      else if (el.tagName === 'SELECT') {
        value = el.options[el.selectedIndex]?.text ?? null;
        const options = Array.from(el.options).slice(0, 8).map((option) => clean(option.text, 30)).filter(Boolean);
        if (options.length) name = clean(name + ' [' + options.join(' | ') + ']', 160);
      } else if (type === 'checkbox' || type === 'radio') value = el.checked ? 'checked' : 'unchecked';
      else if (el.tagName === 'TEXTAREA' || (type && !['submit', 'button', 'reset', 'image'].includes(type))) value = el.value || null;
      out.push({ ref, role: roleOf(el), name, type, value: value == null ? null : clean(value, 80) });
    }
    window.__pippaRefs = refs;
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

    /// One click, fill or select on an element of exactly this snapshot. Never fills a password field.
    static let actionScript = #"""
    if (window.__pippaSnapshot !== snapshotId || !window.__pippaRefs) return { error: 'stale' };
    const el = window.__pippaRefs.get(ref);
    if (!el || !el.isConnected) return { error: 'stale' };
    const fire = () => {
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    };
    if (kind === 'fill') {
      if (el.tagName === 'INPUT' && String(el.type || '').toLowerCase() === 'password') return { error: 'password' };
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
