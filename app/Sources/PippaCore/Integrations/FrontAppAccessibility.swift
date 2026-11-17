import AppKit
import ApplicationServices
import Foundation

// The second way to read the app in front: the visible text of its window via Accessibility (AXUIElement), for apps
// that Apple Events cannot read (Electron apps, Finder, Notes, System Settings …). Apple Events stay first: Safari,
// Chrome and document apps answer there with the real page or file, Accessibility only when that brings nothing.
// Read only: no actions, no attribute is ever written, `AXEnhancedUserInterface` is never set.

/// Reading the window in front via Accessibility. The real one asks macOS; checks use a stand-in.
public protocol AccessibilityFrontReading: Sendable {
    /// May Pippa read other apps' windows? `ask: true` shows the system prompt.
    func accessibilityAccess(ask: Bool) -> IntegrationAccess
    /// `nil`: no window or no readable text.
    func readAccessibility(_ app: FrontApp) async throws -> FrontContent?
}

/// One node of an accessibility tree, as checks build it by hand (`AccessibilityText.collect`).
public struct AXNodeSample: Sendable, Equatable {
    public var role: String
    /// Title, value and description, in that order.
    public var texts: [String]
    public var children: [AXNodeSample]
    public init(role: String, texts: [String] = [], children: [AXNodeSample] = []) {
        self.role = role; self.texts = texts; self.children = children
    }
}

/// The bounded walk over a window's tree: what is read, how deep, how much.
public enum AccessibilityText {
    public static let maxDepth = 12
    public static let maxNodes = 800
    public static let maxChars = 6000

    /// Window chrome, skipped with everything below it. Secure text fields are never read.
    public static let skippedRoles: Set<String> = [
        "AXScrollBar", "AXSplitter", "AXToolbar", "AXMenuBar", "AXMenuBarItem", "AXMenu", "AXMenuItem",
        "AXGrowArea", "AXBusyIndicator", "AXSecureTextField",
    ]

    public struct Walk: Sendable, Equatable {
        public var lines: [String]
        /// Nodes whose attributes were read.
        public var visited: Int
        /// Deepest level reached; the window is 0.
        public var deepest: Int
        /// Stopped early: node or character budget used up.
        public var clipped: Bool
        public var text: String { lines.joined(separator: "\n") }
    }

    public static func collect(_ root: AXNodeSample) -> Walk {
        collect(root, role: \.role, texts: \.texts, children: \.children)
    }

    /// Depth first in reading order. `children` is only called for nodes within the bounds, so a live tree is never
    /// read further than the walk goes. `stop` ends the walk early (a deadline).
    public static func collect<Node>(_ root: Node, role: (Node) -> String, texts: (Node) -> [String], children: (Node) -> [Node],
                                     stop: () -> Bool = { false }) -> Walk {
        var walk = Walk(lines: [], visited: 0, deepest: 0, clipped: false)
        var chars = 0
        var full = false

        func add(_ line: String) {
            guard line != walk.lines.last else { return }
            let cost = line.count + (walk.lines.isEmpty ? 0 : 1)
            if chars + cost > maxChars {
                let room = maxChars - chars - (walk.lines.isEmpty ? 0 : 1)
                if room > 0 { walk.lines.append(String(line.prefix(room))); chars = maxChars }
                walk.clipped = true; full = true
                return
            }
            walk.lines.append(line); chars += cost
        }

        func visit(_ node: Node, depth: Int) {
            if full { return }
            if walk.visited >= maxNodes || stop() { walk.clipped = true; full = true; return }
            walk.visited += 1
            walk.deepest = max(walk.deepest, depth)
            if skippedRoles.contains(role(node)) { return }
            var seen: Set<String> = []
            for text in texts(node) {
                for raw in text.split(whereSeparator: \.isNewline) {
                    let line = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
                    guard !line.isEmpty, seen.insert(line).inserted else { continue }
                    add(line)
                    if full { return }
                }
            }
            guard depth < maxDepth else { return }
            for child in children(node) {
                visit(child, depth: depth + 1)
                if full { return }
            }
        }

        visit(root, depth: 0)
        return walk
    }
}

// MARK: - Real

/// Reads the window in front via AXUIElement, within `AccessibilityText`'s bounds. Never performs an action and never
/// writes an attribute.
public struct SystemAccessibilityFrontReader: AccessibilityFrontReading {
    /// Set once Pippa has shown the system prompt: untrusted after that means "not allowed", not "not asked yet".
    static let promptedKey = "accessibilityPromptShown"
    /// Per attribute call, so a hanging app cannot hold the walk for long.
    static let messagingTimeout: Float = 1
    /// For the whole walk.
    static let walkLimit: TimeInterval = 3

    public init() {}

    public func accessibilityAccess(ask: Bool) -> IntegrationAccess {
        if ask {
            UserDefaults.standard.set(true, forKey: Self.promptedKey)
            // The value of `kAXTrustedCheckOptionPrompt`; the global itself is not concurrency-safe in Swift 6.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options) ? .granted : .denied
        }
        if AXIsProcessTrusted() { return .granted }
        return UserDefaults.standard.bool(forKey: Self.promptedKey) ? .denied : .notDetermined
    }

    public func readAccessibility(_ app: FrontApp) async throws -> FrontContent? {
        await Task.detached(priority: .userInitiated) { Self.read(app) }.value
    }

    static func read(_ app: FrontApp) -> FrontContent? {
        // The chip's app, not whatever process took over its number.
        guard AXIsProcessTrusted(), NSRunningApplication(processIdentifier: app.pid)?.bundleIdentifier == app.bundleID else { return nil }
        let element = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        guard let window = element.ax(kAXFocusedWindowAttribute, as: AXUIElement.self)
                ?? element.ax(kAXMainWindowAttribute, as: AXUIElement.self)
                ?? element.ax(kAXWindowsAttribute, as: [AXUIElement].self)?.first else { return nil }
        let deadline = Date().addingTimeInterval(walkLimit)
        let walk = AccessibilityText.collect(window, role: { $0.ax(kAXRoleAttribute, as: String.self) ?? "" },
                                             texts: { node in
                                                 [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute].compactMap { node.ax($0, as: String.self) }
                                             },
                                             children: { $0.ax(kAXChildrenAttribute, as: [AXUIElement].self) ?? [] },
                                             stop: { Date() > deadline })
        let document = window.ax(kAXDocumentAttribute, as: String.self).flatMap(URL.init(string:)).flatMap { $0.isFileURL ? $0 : nil }
        let address = window.ax(kAXURLAttribute, as: URL.self)
        let text = walk.text
        guard !text.isEmpty || document != nil else { return nil }
        let title = window.ax(kAXTitleAttribute, as: String.self).flatMap { $0.isEmpty ? nil : $0 } ?? app.title ?? app.name
        return FrontContent(kind: .page, title: title, url: address.flatMap { $0.isFileURL ? nil : $0.absoluteString },
                            file: document ?? address.flatMap { $0.isFileURL ? $0 : nil }, text: text)
    }
}

private extension AXUIElement {
    /// One attribute, copied; never written.
    func ax<T>(_ attribute: String, as: T.Type) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! T)
        }
        return value as? T
    }
}
