import AppKit
import PippaCore
import SwiftUI

/// What Pippa is currently working on: last dropped or chosen.
struct WorkContext {
    var name: String
    var items: [URL]
    var payload: DropPayload

    /// Folder for tidying and for new files (table). Only an unambiguous place: if the items lie
    /// in different folders, `nil`, and Pippa asks before tidying or creating.
    var folder: URL? {
        // Dropped mails and images land in the cache: new files then preferably in "Downloads".
        if !items.isEmpty, items.allSatisfy({ $0.deletingLastPathComponent().path.hasPrefix(Inbox.directory.path) }) {
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        }
        return ConversationContext.commonFolder(items)
    }

    /// Common parent folder, as the starting point of the folder choice.
    var commonAncestor: URL? {
        let parts = items.map { $0.deletingLastPathComponent().standardizedFileURL.pathComponents }
        guard var prefix = parts.first else { return nil }
        for p in parts.dropFirst() { prefix = Array(zip(prefix, p).prefix { $0 == $1 }.map(\.0)) }
        return prefix.count > 1 ? URL(fileURLWithPath: NSString.path(withComponents: prefix), isDirectory: true) : nil
    }

    var isFolder: Bool { items.count == 1 && (items.first?.hasDirectoryPath ?? false) }
}

/// The forms of the one shell.
enum ShellMode {
    case pill
    case target(hot: Bool)
    case input
    /// Compact reopening of the same topic after a quiet interval.
    case resume
    /// A line at the pill for things on Pippa: thumbnails, input, up to three actions,
    /// progress, result ("given" through "result"). No conversation, no window.
    case line
    /// `writes`: base sentence when the step changes something (then no "Stop" and no "read only").
    case working(title: String, subtitle: String, writes: String?)
    case onboarding
    case overview(Overview)
    case sortSheet
    case invoiceSheet
    case deadlines                                   // deadlines with source passage
    case entryPreview                                // preview of an entry (reminders/calendar)
    case permission(Integration, denied: Bool)       // a sentence before the system prompt, or the way to Settings
    case message(title: String, body: String, isError: Bool)
    case notice(title: String, detail: String, buttons: [ToastButton])

    enum Shape { case pill, target, input, panel, sheet }

    var shape: Shape {
        switch self {
        case .pill: .pill
        case .target: .target
        case .input, .resume, .line: .input
        case .sortSheet, .invoiceSheet: .sheet
        default: .panel
        }
    }

    /// Stable key for transitions.
    var key: String {
        switch self {
        case .pill: "pill"
        case .target: "target"
        case .input: "input"
        case .resume: "resume"
        case .line: "line"
        case .working: "working"
        case .onboarding: "onboarding"
        case .overview: "overview"
        case .sortSheet: "sort"
        case .invoiceSheet: "invoice"
        case .deadlines: "deadlines"
        case .entryPreview: "entry"
        case .permission: "permission"
        case .message: "message"
        case .notice: "notice"
        }
    }

    var isExpanded: Bool { shape != .pill && shape != .target }

    var isConversation: Bool {
        switch self {
        case .pill, .target, .onboarding, .line, .resume: false
        default: true
        }
    }

    /// Pending decisions retain the full conversation on reopen; completed results may compact.
    var requiresReviewOnReopen: Bool {
        switch self {
        case .sortSheet, .invoiceSheet, .entryPreview, .permission: true
        default: false
        }
    }

    /// Results that may wait when the shell is closed.
    var isResult: Bool {
        switch self {
        case .overview, .sortSheet, .invoiceSheet, .deadlines, .notice: true
        default: false
        }
    }

    /// Cards that stay open on follow-up questions: the answer appears below them in the conversation.
    var staysWhileChatting: Bool {
        switch self {
        case .overview, .sortSheet, .invoiceSheet, .deadlines, .entryPreview, .notice: true
        default: false
        }
    }
}
