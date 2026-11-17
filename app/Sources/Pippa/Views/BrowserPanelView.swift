import AppKit
import SwiftUI
import WebKit

/// Pippa's browser panel beside the chat: back, reload or stop, the page's address, close, and the person's step
/// (login, 2FA, CAPTCHA) as a banner. The page itself is `WKBrowserSession`'s one web view.
struct BrowserPanelView: View {
    @ObservedObject var browser: WKBrowserSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.s) {
                Button { browser.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!browser.canGoBack)
                    .help(T("Back", table: "Views"))
                Button { browser.isLoading ? browser.stop() : browser.reload() } label: {
                    Image(systemName: browser.isLoading ? "xmark" : "arrow.clockwise")
                }
                .disabled(browser.currentURL == nil)
                .help(browser.isLoading ? T("Stop loading", table: "Views") : T("Reload", table: "Views"))
                address
                Button { browser.isOpen = false } label: { Image(systemName: "sidebar.trailing") }
                    .help(T("Hide the browser", table: "Views"))
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.m)
            if let message = browser.handoffMessage {
                HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                    Image(systemName: "person.badge.key")
                    Text(message).font(Typo.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Space.m)
                    Button(T("Done", table: "Views")) { browser.handoffMessage = nil }
                }
                .foregroundStyle(Theme.accent)
                .padding(Space.l)
                .background(Theme.accentTint)
            }
            Divider()
            BrowserWebView(webView: browser.webView)
        }
    }

    /// The host only, like Safari's compact address field; the full address as a tooltip.
    private var address: some View {
        HStack(spacing: Space.xs) {
            if browser.currentURL?.scheme == "https" { Image(systemName: "lock.fill").font(.system(size: 10)) }
            Text(verbatim: host ?? T("No page open", table: "Views"))
                .lineLimit(1).truncationMode(.middle)
        }
        .font(Typo.footnote)
        .foregroundStyle(Theme.ink2)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.xs)
        .padding(.horizontal, Space.m)
        .background(Theme.fill3, in: Capsule())
        .help(browser.currentURL?.absoluteString ?? "")
    }

    private var host: String? {
        guard let host = browser.currentURL?.host(percentEncoded: false) else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// The session's persistent web view; SwiftUI only places it.
private struct BrowserWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
