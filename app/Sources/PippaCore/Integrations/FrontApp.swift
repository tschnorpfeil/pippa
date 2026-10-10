import AppKit
import ApplicationServices
import Foundation

// "Pippa knows the app in front." When the person calls Pippa, the app they were in is remembered before Pippa
// takes the focus (FrontmostTracker in the app). Only a label goes into Pi's message: app name and window title,
// 10 to 20 tokens (`FrontApp.label`). The content comes only on request, through Pippa's read tool `front_read`
// (PippaMCPTools.swift), when the question is about it ("was steht hier?", "fass das zusammen").
// The person sees the label as a chip above the input field and can remove it with one click; without the chip,
// neither the label nor the content goes anywhere, also not with the online model.

/// The app the person was in when they called Pippa.
public struct FrontApp: Sendable, Equatable {
    public var name: String
    public var bundleID: String
    public var pid: pid_t
    /// Window or tab title, if Pippa could see it without asking (`FrontAppProbe.title`).
    public var title: String?

    public init(name: String, bundleID: String, pid: pid_t, title: String? = nil) {
        self.name = name; self.bundleID = bundleID; self.pid = pid; self.title = title
    }

    /// Titles longer than this are cut (a label, not content).
    public static let titleLimit = 80

    /// The title on one line, cut to `titleLimit`; `nil` if empty or only the app name.
    public var shortTitle: String? {
        let one = (title ?? "").split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !one.isEmpty, one != name else { return nil }
        return one.count > Self.titleLimit ? String(one.prefix(Self.titleLimit - 1)) + "…" : one
    }

    /// The line before the question in Pi's message. A hint, not content: `front_read` reads the content.
    public func label(german: Bool) -> String {
        let title = shortTitle.map { german ? " – „\($0)“" : " – “\($0)”" } ?? ""
        return (german ? "[Im Vordergrund: " : "[In front: ") + name + title + "]"
    }

    /// Apps whose chip would only be noise: Finder is in front after every click on the desktop.
    public static let ignoredBundles: Set<String> = ["com.apple.finder"]

    public static let safari = "com.apple.Safari"
    public static let chrome = "com.google.Chrome"
}

/// What `front_read` found.
public struct FrontContent: Sendable, Equatable {
    public enum Kind: String, Sendable { case page, document }
    public var kind: Kind
    public var title: String
    /// Web address (browser tab).
    public var url: String?
    /// Path of the front document, if the app names one.
    public var file: URL?
    /// The text; empty if the app did not hand it out (Chrome without JavaScript from Apple Events, a scanned PDF).
    public var text: String
    public init(kind: Kind, title: String, url: String? = nil, file: URL? = nil, text: String) {
        self.kind = kind; self.title = title; self.url = url; self.file = file; self.text = text
    }
}

/// Reading the app in front, for Pippa's MCP server. The real one asks the apps via Apple Events; checks use a stand-in.
public protocol FrontAppReading: Sendable {
    /// May Pippa ask this app? `ask: true` shows the system prompt.
    func frontAccess(_ app: FrontApp, ask: Bool) async -> IntegrationAccess
    /// `nil`: the app shows nothing Pippa can read (no window, not scriptable).
    func readFront(_ app: FrontApp) async throws -> FrontContent?
}

/// The chip of the running answer: set by the app for one answer (PiRPCChat+Shown.swift), read by `front_read`.
/// `nil`: no chip (none, or removed by the person), so `front_read` reads nothing.
public final class FrontAppStage: @unchecked Sendable {
    public static let shared = FrontAppStage()
    private let lock = NSLock()
    private var app: FrontApp?
    public init() {}
    public var current: FrontApp? {
        get { lock.withLock { app } }
        set { lock.withLock { app = newValue } }
    }
}

// MARK: - Real

/// Safari, Chrome and every app with a front document (TextEdit, Preview, Pages …), via Apple Events in Pippa's process.
public struct SystemFrontApp: FrontAppReading {
    public init() {}

    public func frontAccess(_ app: FrontApp, ask: Bool) async -> IntegrationAccess {
        await AppleEvents.permission(bundle: app.bundleID, appName: app.name, ask: ask)
    }

    public func readFront(_ app: FrontApp) async throws -> FrontContent? {
        switch app.bundleID {
        case FrontApp.safari: return try await FrontAppScript.page(FrontAppScript.safari, app: app)
        case FrontApp.chrome: return try await FrontAppScript.page(FrontAppScript.chrome, app: app)
        default: return try await FrontAppScript.document(app)
        }
    }
}

/// Invented data only (PIPPA_DEMO=1, checks): never touches real apps.
public final class DemoFrontApp: FrontAppReading, @unchecked Sendable {
    public var access: IntegrationAccess
    public var content: FrontContent?
    public init(access: IntegrationAccess = .granted,
                content: FrontContent? = FrontContent(kind: .page, title: "Mietkaution – Beispielseite", url: "https://beispiel.example/kaution",
                                                      text: "Die Kaution darf höchstens drei Nettokaltmieten betragen (Beispieltext).")) {
        self.access = access; self.content = content
    }
    public func frontAccess(_ app: FrontApp, ask: Bool) async -> IntegrationAccess {
        if access == .notDetermined && ask { access = .granted }
        return access
    }
    public func readFront(_ app: FrontApp) async throws -> FrontContent? { content }
}

/// Window title at call time, only from sources that never ask: the window list (with screen recording allowed),
/// Accessibility (if already allowed), Safari and Chrome (if automation is already allowed).
public enum FrontAppProbe {
    public static func title(for app: FrontApp) async -> String? {
        if let title = windowListTitle(pid: app.pid) { return title }
        if let title = accessibilityTitle(pid: app.pid) { return title }
        guard [FrontApp.safari, FrontApp.chrome].contains(app.bundleID),
              await AppleEvents.permission(bundle: app.bundleID, appName: app.name, ask: false) == .granted else { return nil }
        let source = app.bundleID == FrontApp.safari ? FrontAppScript.safari : FrontAppScript.chrome
        let name = app.name
        return try? await AppleEvents.perform { () throws -> String? in
            try AppleEvents.call(source, handler: "frontTitle", appName: name).stringValue
        }
    }

    /// Without screen recording the window list has no names: then `nil`, no prompt.
    static func windowListTitle(pid: pid_t) -> String? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        return windows.first { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
            && !(($0[kCGWindowName as String] as? String) ?? "").isEmpty }?[kCGWindowName as String] as? String
    }

    /// Only if Pippa already may use Accessibility; never asks.
    static func accessibilityTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let element = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }
}

/// Read only: the front tab's title, address and text; the front document's path. Never changes anything.
enum FrontAppScript {
    static let safari = """
    on frontTitle()
        tell application id "com.apple.Safari"
            if (count of documents) is 0 then return ""
            return name of front document
        end tell
    end frontTitle

    on frontPage()
        tell application id "com.apple.Safari"
            if (count of documents) is 0 then return {}
            set d to front document
            set theURL to ""
            try
                set theURL to (URL of d) as text
            end try
            set theText to ""
            try
                set theText to text of d
            end try
            return {name of d, theURL, theText}
        end tell
    end frontPage
    """

    /// The page text needs Chrome's "Allow JavaScript from Apple Events"; without it title and address only.
    static let chrome = """
    on frontTitle()
        tell application id "com.google.Chrome"
            if (count of windows) is 0 then return ""
            return title of active tab of front window
        end tell
    end frontTitle

    on frontPage()
        tell application id "com.google.Chrome"
            if (count of windows) is 0 then return {}
            set t to active tab of front window
            set theText to ""
            try
                set theText to execute t javascript "document.body.innerText"
            end try
            return {title of t, (URL of t) as text, theText}
        end tell
    end frontPage
    """

    /// Any app with documents (Cocoa standard suite): raw codes, so it compiles without the app's dictionary.
    /// `ppth` = path (TextEdit, Preview), `file` = file (Pages, Numbers, Keynote).
    static let documentSource = """
    on frontFile(appID)
        tell application id appID
            set theName to ""
            try
                set theName to (name of «class docu» 1) as text
            end try
            try
                set p to «property ppth» of «class docu» 1
                if p is not missing value then return {theName, p as text}
            end try
            try
                set f to «property file» of «class docu» 1
                if f is not missing value then return {theName, POSIX path of f}
            end try
            return {theName, ""}
        end tell
    end frontFile
    """

    static func page(_ source: String, app: FrontApp) async throws -> FrontContent? {
        let parts = try await AppleEvents.perform { () throws -> [String] in
            let reply = try AppleEvents.call(source, handler: "frontPage", appName: app.name)
            return AppleEvents.strings(reply)
        }
        guard parts.count >= 3 else { return nil }
        return FrontContent(kind: .page, title: parts[0], url: parts[1].isEmpty ? nil : parts[1], text: parts[2])
    }

    /// The front document's file, read with Pippa's text reader (text layer only; scans go to `read_document`).
    static func document(_ app: FrontApp) async throws -> FrontContent? {
        let parts = try await AppleEvents.perform { () throws -> [String] in
            let reply = try AppleEvents.call(documentSource, handler: "frontFile", [NSAppleEventDescriptor(string: app.bundleID)], appName: app.name)
            return AppleEvents.strings(reply)
        }
        guard parts.count >= 2, !parts[1].isEmpty else { return nil }
        let url = URL(fileURLWithPath: parts[1])
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let text = await Task.detached(priority: .userInitiated) {
            TextReader.read(url, options: .init(maxPages: 5, ocr: false)).fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
        return FrontContent(kind: .document, title: parts[0].isEmpty ? url.lastPathComponent : parts[0], file: url, text: text)
    }
}
