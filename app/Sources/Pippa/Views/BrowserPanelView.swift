import AppKit
import PippaCore
import SwiftUI
import WebKit

/// Pippa's browser panel beside the chat: back, reload or stop, the page's address, close, the person's step
/// (login, 2FA, CAPTCHA) as a banner, a strip of the conversations' tabs when there are several, and a sign-in window
/// over its page while one is open. The page itself is the shown tab's web view in `WKBrowserSession`.
struct BrowserPanelView: View {
    @ObservedObject var browser: WKBrowserSession
    /// A public page the conversation read (`front_read`, a web source), offered while the panel is empty.
    var suggestion: URL?
    var conversation: String?
    /// A click on another tab: shows its conversation.
    var selectTab: (String) -> Void = { _ in }
    private let addressState = State(initialValue: "")
    private var enteredAddress: String {
        get { addressState.wrappedValue }
        nonmutating set { addressState.wrappedValue = newValue }
    }
    @FocusState private var editingAddress: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.s) {
                Button { browser.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!browser.canGoBack)
                    .help(T("Back", table: "Views"))
                Button { browser.isLoading ? browser.stop() : browser.reload() } label: {
                    Image(systemName: browser.isLoading ? "xmark" : "arrow.clockwise")
                }
                .disabled(browser.currentURL == nil && browser.restorableURL == nil)
                .help(browser.isLoading ? T("Stop loading", table: "Views") : T("Reload", table: "Views"))
                address
                Button { browser.isOpen = false } label: { Image(systemName: "sidebar.trailing") }
                    .help(T("Hide the browser", table: "Views"))
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.m)
            if browser.tabItems.count > 1 { tabStrip }
            if let message = browser.handoffMessage {
                HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                    Image(systemName: "person.badge.key")
                    Text(message).font(Typo.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Space.m)
                    Button(T("Done", table: "Views")) { browser.finishHandoff() }
                }
                .foregroundStyle(Theme.accent)
                .padding(Space.l)
                .background(Theme.accentTint)
            }
            if let host = browser.popupHost { popupHeader(host) }
            Divider()
            if let problem = browser.navigationProblem {
                Text(problem).font(Typo.footnote).foregroundStyle(Theme.need)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(Space.l)
            }
            ZStack {
                BrowserWebView(webView: browser.shownWebView)
                if browser.currentURL == nil && !browser.isLoading { emptyState }
            }
        }
        .onAppear { enteredAddress = browser.currentURL?.absoluteString ?? "" }
        .onChange(of: browser.currentURL) { _, url in
            if !editingAddress { enteredAddress = url?.absoluteString ?? "" }
        }
    }

    /// The person's address field works before any page or AI task is open.
    private var address: some View {
        HStack(spacing: Space.xs) {
            if browser.currentURL?.scheme == "https" { Image(systemName: "lock.fill").font(.system(size: 10)) }
            TextField(T("Website address", table: "Views"), text: addressState.projectedValue)
                .textFieldStyle(.plain)
                .focused($editingAddress)
                .accessibilityLabel(T("Website address", table: "Views"))
                .onSubmit {
                    editingAddress = false
                    Task { await browser.navigateManually(enteredAddress) }
                }
        }
        .font(Typo.footnote)
        .foregroundStyle(Theme.ink2)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.xs)
        .padding(.horizontal, Space.m)
        .background(Theme.fill3, in: Capsule())
        .help(browser.currentURL?.absoluteString ?? "")
    }

    /// One entry per conversation that has a page: its title, a dot while it waits for the person, and a close button.
    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.xs) {
                ForEach(browser.tabItems) { item in
                    let shown = item.id == browser.displayedKey
                    HStack(spacing: Space.xs) {
                        if item.waiting {
                            Circle().fill(Theme.accent).frame(width: 6, height: 6)
                                .help(T("Waiting for you", table: "Views"))
                        }
                        Button { if !shown { selectTab(item.id) } } label: {
                            Text(verbatim: item.title.isEmpty ? "…" : item.title).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: 140, alignment: .leading)
                        }
                        Button { browser.closeTab(item.id) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)) }
                            .help(T("Close tab", table: "Views"))
                    }
                    .font(Typo.caption)
                    .foregroundStyle(shown ? Theme.ink : Theme.ink2)
                    .padding(.horizontal, Space.m)
                    .frame(height: 22)
                    .background(shown ? Theme.fill3 : .clear, in: Capsule())
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Space.l)
        }
        .padding(.bottom, Space.s)
    }

    /// A window the page opened (usually a sign-in), shown over the page until it closes itself or the person closes it.
    private func popupHeader(_ host: String) -> some View {
        HStack(spacing: Space.m) {
            Image(systemName: "macwindow.on.rectangle")
            Text(host.isEmpty ? T("New window", table: "Views") : T("Window from %@", table: "Views", host))
                .font(Typo.footnote).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: Space.m)
            Button { browser.closePopup() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help(T("Close this window and go back to the page", table: "Views"))
        }
        .foregroundStyle(Theme.ink2)
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.s)
        .background(Theme.fill3)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(T("Open a website", table: "Views"), systemImage: "globe")
        } description: {
            Text(T("Enter a web address above.", table: "Views"))
        } actions: {
            // An evicted tab's own page first, else a page the conversation read.
            if let url = browser.restorableURL ?? suggestion, let host = PippaMCPBrowserTool.normalizedHost(url) {
                Button {
                    if browser.restorableURL != nil { browser.reload() }
                    else { Task { await browser.openFromBridge(url, in: conversation) } }
                } label: {
                    Label(T("Open %@ in Pippa", table: "Views", host.hasPrefix("www.") ? String(host.dropFirst(4)) : host), systemImage: "globe")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }
        }
    }
}

/// Holds the shown tab's web view and swaps it when the conversation, or its popup, changes; SwiftUI only places it.
private struct BrowserWebView: NSViewRepresentable {
    let webView: WKWebView?
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        show(in: container)
        return container
    }
    func updateNSView(_ container: NSView, context: Context) { show(in: container) }

    private func show(in container: NSView) {
        if let webView, webView.superview === container, container.subviews.count == 1 { return }
        for view in container.subviews { view.removeFromSuperview() }
        guard let webView else { return }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}
