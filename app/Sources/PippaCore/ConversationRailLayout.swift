import CoreGraphics

/// The two side rails of the open conversation.
public enum ConversationRail: String, Sendable, CaseIterable {
    case sessions, details
}

/// Which rails the person wants. Saved by the app; ConversationRailLayout decides what fits the window.
public struct ConversationRails: Equatable, Sendable {
    public var sessions: Bool
    public var details: Bool
    /// The rail switched on last keeps the room when only one fits.
    public var prefersDetails: Bool

    public static let plain = ConversationRails(sessions: false, details: false)
    public static let both = ConversationRails(sessions: true, details: true)

    public init(sessions: Bool, details: Bool, prefersDetails: Bool = false) {
        self.sessions = sessions; self.details = details; self.prefersDetails = prefersDetails
    }

    public var isEmpty: Bool { !sessions && !details }

    public func wants(_ rail: ConversationRail) -> Bool { rail == .sessions ? sessions : details }

    public mutating func set(_ rail: ConversationRail, shown: Bool) {
        switch rail {
        case .sessions: sessions = shown
        case .details: details = shown
        }
        if shown { prefersDetails = rail == .details }
    }
}

/// Widths of the three-pane conversation, pure geometry so it can be checked. Rails have fixed widths (scaled like
/// every width with the text size); the conversation between them never gets narrower than `centerMinimum`, the
/// narrowest window the views are checked at. Without room for one rail the window is the plain conversation.
public struct ConversationRailLayout: Equatable, Sendable {
    public static let sessionBase: CGFloat = 232
    public static let detailBase: CGFloat = 288
    /// ShellTokens.workspaceMin.width: the 400-point captures.
    public static let centerMinimum: CGFloat = 400
    /// The conversation's default width beside rails.
    public static let centerWithRails: CGFloat = 660
    /// Theme.conversationWidth: the conversation without rails.
    public static let plainWidth: CGFloat = 760

    public private(set) var showsSessions = false
    public private(set) var showsDetails = false
    /// Room for at least one rail: the header shows the rail switches.
    public private(set) var showsToggles = false
    public private(set) var sessionWidth: CGFloat = 0
    public private(set) var detailWidth: CGFloat = 0
    public private(set) var centerWidth: CGFloat = 0

    public func shows(_ rail: ConversationRail) -> Bool { rail == .sessions ? showsSessions : showsDetails }

    public static func railWidth(_ rail: ConversationRail, scale: CGFloat = 1) -> CGFloat {
        (rail == .sessions ? sessionBase : detailBase) * scale
    }

    /// What a window of `width` shows: wanted rails in order of preference while the conversation keeps its minimum.
    public static func resolve(width: CGFloat, rails: ConversationRails, scale: CGFloat = 1) -> ConversationRailLayout {
        var layout = ConversationRailLayout()
        layout.sessionWidth = railWidth(.sessions, scale: scale)
        layout.detailWidth = railWidth(.details, scale: scale)
        let minimum = centerMinimum * scale
        layout.showsToggles = width >= minimum + min(layout.sessionWidth, layout.detailWidth)
        var used: CGFloat = 0
        if layout.showsToggles {
            let order: [ConversationRail] = rails.prefersDetails ? [.details, .sessions] : [.sessions, .details]
            for rail in order where rails.wants(rail) {
                let needed = railWidth(rail, scale: scale)
                guard width - used - needed >= minimum else { continue }
                used += needed
                if rail == .sessions { layout.showsSessions = true } else { layout.showsDetails = true }
            }
        }
        layout.centerWidth = width - used
        return layout
    }

    /// Opening width: 760 without rails; with rails a 660-point conversation plus each wanted rail.
    public static func preferredWidth(rails: ConversationRails, scale: CGFloat = 1) -> CGFloat {
        guard !rails.isEmpty else { return plainWidth * scale }
        var total = centerWithRails * scale
        for rail in ConversationRail.allCases where rails.wants(rail) { total += railWidth(rail, scale: scale) }
        return total
    }

    /// Width a moved or resized window needs to show `rail` beside the rails `current` shows and the minimum conversation.
    public static func width(toShow rail: ConversationRail, beside current: ConversationRailLayout, scale: CGFloat = 1) -> CGFloat {
        var total = centerMinimum * scale + railWidth(rail, scale: scale)
        for other in ConversationRail.allCases where other != rail && current.shows(other) { total += railWidth(other, scale: scale) }
        return total
    }
}
