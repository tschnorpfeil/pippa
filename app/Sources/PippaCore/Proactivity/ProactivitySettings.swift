import Foundation

/// Categories of calm proactive matters that Pippa can prepare when opted in.
public enum ProactiveMatterKind: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case morningBrief = "morning_brief"
    case watchedFile = "watched_file"
    case followUp = "follow_up"
}

/// Opt-in configuration for Pippa's calm proactivity contract.
/// Off by default (`enabled == false`), with a hard daily nudge cap in `1...2`.
public struct ProactivitySettings: Codable, Sendable, Equatable {
    public static let validDailyCapRange = 1...2
    public static let defaultDisabled = ProactivitySettings()

    public var enabled: Bool
    public var morningBriefEnabled: Bool
    public var morningBriefHour: Int {
        didSet { morningBriefHour = Self.clampHour(morningBriefHour) }
    }
    public var morningBriefMinute: Int {
        didSet { morningBriefMinute = Self.clampMinute(morningBriefMinute) }
    }
    public var watchedFolderPath: String?
    public var watchedFolderBookmark: Data?
    public var quietHoursEnabled: Bool
    public var quietStartHour: Int {
        didSet { quietStartHour = Self.clampHour(quietStartHour) }
    }
    public var quietEndHour: Int {
        didSet { quietEndHour = Self.clampHour(quietEndHour) }
    }
    public var dailyCap: Int {
        didSet { dailyCap = Self.clampDailyCap(dailyCap) }
    }
    public var mutedKinds: Set<ProactiveMatterKind>

    public init(
        enabled: Bool = false,
        morningBriefEnabled: Bool = true,
        morningBriefHour: Int = 8,
        morningBriefMinute: Int = 0,
        watchedFolderPath: String? = nil,
        watchedFolderBookmark: Data? = nil,
        quietHoursEnabled: Bool = true,
        quietStartHour: Int = 22,
        quietEndHour: Int = 8,
        dailyCap: Int = 2,
        mutedKinds: Set<ProactiveMatterKind> = []
    ) {
        self.enabled = enabled
        self.morningBriefEnabled = morningBriefEnabled
        self.morningBriefHour = Self.clampHour(morningBriefHour)
        self.morningBriefMinute = Self.clampMinute(morningBriefMinute)
        self.watchedFolderPath = watchedFolderPath
        self.watchedFolderBookmark = watchedFolderBookmark
        self.quietHoursEnabled = quietHoursEnabled
        self.quietStartHour = Self.clampHour(quietStartHour)
        self.quietEndHour = Self.clampHour(quietEndHour)
        self.dailyCap = Self.clampDailyCap(dailyCap)
        self.mutedKinds = mutedKinds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.morningBriefEnabled = try container.decodeIfPresent(Bool.self, forKey: .morningBriefEnabled) ?? true
        self.morningBriefHour = Self.clampHour(try container.decodeIfPresent(Int.self, forKey: .morningBriefHour) ?? 8)
        self.morningBriefMinute = Self.clampMinute(try container.decodeIfPresent(Int.self, forKey: .morningBriefMinute) ?? 0)
        self.watchedFolderPath = try container.decodeIfPresent(String.self, forKey: .watchedFolderPath)
        self.watchedFolderBookmark = try container.decodeIfPresent(Data.self, forKey: .watchedFolderBookmark)
        self.quietHoursEnabled = try container.decodeIfPresent(Bool.self, forKey: .quietHoursEnabled) ?? true
        self.quietStartHour = Self.clampHour(try container.decodeIfPresent(Int.self, forKey: .quietStartHour) ?? 22)
        self.quietEndHour = Self.clampHour(try container.decodeIfPresent(Int.self, forKey: .quietEndHour) ?? 8)
        self.dailyCap = Self.clampDailyCap(try container.decodeIfPresent(Int.self, forKey: .dailyCap) ?? 2)
        self.mutedKinds = try container.decodeIfPresent(Set<ProactiveMatterKind>.self, forKey: .mutedKinds) ?? []
    }

    public func isMuted(_ kind: ProactiveMatterKind) -> Bool {
        mutedKinds.contains(kind)
    }

    public mutating func mute(_ kind: ProactiveMatterKind) {
        mutedKinds.insert(kind)
    }

    public mutating func unmute(_ kind: ProactiveMatterKind) {
        mutedKinds.remove(kind)
    }

    public static func clampDailyCap(_ value: Int) -> Int {
        min(max(value, validDailyCapRange.lowerBound), validDailyCapRange.upperBound)
    }

    public static func clampHour(_ value: Int) -> Int {
        min(max(value, 0), 23)
    }

    public static func clampMinute(_ value: Int) -> Int {
        min(max(value, 0), 59)
    }
}
