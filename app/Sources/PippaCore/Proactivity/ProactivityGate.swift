import CoreGraphics
import Foundation
#if canImport(Intents)
import Intents
#endif

/// Authorization state of macOS Focus status reporting (never requires Full Disk Access).
public enum FocusAuthorizationState: String, Sendable, Equatable {
    case authorized
    case notDetermined
    case denied
    case restricted
    case unavailable
}

/// Snapshot of system interruption state read without Full Disk Access or TCC prompts.
public struct FocusStatus: Sendable, Equatable {
    public var isFocusActive: Bool
    public var isScreenLocked: Bool
    public var authorizationState: FocusAuthorizationState

    public init(
        isFocusActive: Bool = false,
        isScreenLocked: Bool = false,
        authorizationState: FocusAuthorizationState = .authorized
    ) {
        self.isFocusActive = isFocusActive
        self.isScreenLocked = isScreenLocked
        self.authorizationState = authorizationState
    }
}

/// Reads whether the person is currently in a macOS Focus or has the screen locked.
public protocol FocusStatusReading: Sendable {
    func currentStatus() -> FocusStatus
}

/// Deterministic stand-in for offline checks.
public struct StubFocusStatusReader: FocusStatusReading {
    public var status: FocusStatus

    public init(status: FocusStatus = FocusStatus()) {
        self.status = status
    }

    public init(isFocusActive: Bool = false, isScreenLocked: Bool = false) {
        self.status = FocusStatus(isFocusActive: isFocusActive, isScreenLocked: isScreenLocked)
    }

    public func currentStatus() -> FocusStatus {
        status
    }
}

/// Native macOS focus and screen-lock reader.
/// Never asks for Full Disk Access, never reads `~/Library/DoNotDisturb`, and never triggers a Focus TCC prompt during background reads.
public struct SystemFocusStatusReader: FocusStatusReading {
    public init() {}

    public func currentStatus() -> FocusStatus {
        let auth = Self.currentAuthorizationState()
        return FocusStatus(
            isFocusActive: auth == .authorized ? Self.readAuthorizedFocusState() : false,
            isScreenLocked: Self.isScreenLocked(),
            authorizationState: auth
        )
    }

    public static func currentAuthorizationState() -> FocusAuthorizationState {
        #if canImport(Intents)
        switch INFocusStatusCenter.default.authorizationStatus {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unavailable
        }
        #else
        return .unavailable
        #endif
    }

    /// Requests Focus status access strictly from an explicit user opt-in flow in Settings.
    public static func requestAuthorizationIfNeeded() async -> FocusAuthorizationState {
        #if canImport(Intents)
        let current = currentAuthorizationState()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            INFocusStatusCenter.default.requestAuthorization { status in
                switch status {
                case .authorized: continuation.resume(returning: .authorized)
                case .notDetermined: continuation.resume(returning: .notDetermined)
                case .denied: continuation.resume(returning: .denied)
                case .restricted: continuation.resume(returning: .restricted)
                @unknown default: continuation.resume(returning: .unavailable)
                }
            }
        }
        #else
        return .unavailable
        #endif
    }

    private static func readAuthorizedFocusState() -> Bool {
        #if canImport(Intents)
        let center = INFocusStatusCenter.default
        guard center.authorizationStatus == .authorized else { return false }
        return center.focusStatus.isFocused ?? false
        #else
        return false
        #endif
    }

    private static func isScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        if let locked = session["CGSSessionScreenIsLocked"] as? Bool {
            return locked
        }
        if let lockedNumber = session["CGSSessionScreenIsLocked"] as? NSNumber {
            return lockedNumber.boolValue
        }
        return false
    }
}

/// Pure gating outcome for whether a prepared proactive matter may be surfaced right now.
public enum ProactivityDecision: Sendable, Equatable {
    public enum HoldReason: String, Sendable, Equatable {
        case dailyCapReached
        case focusActive
        case quietHours
        case answering
        case snoozed
    }

    public enum DropReason: String, Sendable, Equatable {
        case disabled
        case muted
        case closed
        case stale
        /// The routine asked for the Desk only: the Island ignores it without spending the daily budget.
        case deskOnly
    }

    case deliver
    case hold(reason: HoldReason)
    case drop(reason: DropReason)
}

/// Pure, side-effect-free decision rules for Pippa's calm proactivity contract.
public enum ProactivityGate {
    public static func evaluate(
        matter: ProactiveMatter,
        settings: ProactivitySettings,
        deliveredToday: Int,
        focusStatus: FocusStatus,
        isAnswering: Bool = false,
        isFresh: Bool = true,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        routineEnabled: Bool = true,
        deliveryMode: RoutineDeliveryMode = .islandAndDesk
    ) -> ProactivityDecision {
        guard settings.enabled, routineEnabled else {
            return .drop(reason: .disabled)
        }
        if matter.kind == .morningBrief && !settings.morningBriefEnabled {
            return .drop(reason: .disabled)
        }
        if settings.isMuted(matter.kind) {
            return .drop(reason: .muted)
        }
        if matter.state.isHumanClosed {
            return .drop(reason: .closed)
        }
        if !isFresh {
            return .drop(reason: .stale)
        }
        // Before any hold: a Desk-only matter never waits for, or counts against, the Island's daily budget.
        if deliveryMode == .deskOnly {
            return .drop(reason: .deskOnly)
        }
        if matter.state == .snoozed {
            let stillSnoozed = matter.snoozedUntil.map { $0 > now } ?? true
            if stillSnoozed {
                return .hold(reason: .snoozed)
            }
        }
        let effectiveCap = ProactivitySettings.clampDailyCap(settings.dailyCap)
        if deliveredToday >= effectiveCap {
            return .hold(reason: .dailyCapReached)
        }
        if isAnswering {
            return .hold(reason: .answering)
        }
        if focusStatus.isFocusActive || focusStatus.isScreenLocked {
            return .hold(reason: .focusActive)
        }
        if settings.quietHoursEnabled,
           isInQuietHours(
               now: now,
               startHour: settings.quietStartHour,
               endHour: settings.quietEndHour,
               calendar: calendar
           ) {
            return .hold(reason: .quietHours)
        }
        return .deliver
    }

    public static func evaluate(
        matter: ProactiveMatter,
        settings: ProactivitySettings,
        deliveredToday: Int,
        focusReader: any FocusStatusReading,
        isAnswering: Bool = false,
        isFresh: Bool = true,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        routineEnabled: Bool = true,
        deliveryMode: RoutineDeliveryMode = .islandAndDesk
    ) -> ProactivityDecision {
        evaluate(
            matter: matter,
            settings: settings,
            deliveredToday: deliveredToday,
            focusStatus: focusReader.currentStatus(),
            isAnswering: isAnswering,
            isFresh: isFresh,
            now: now,
            calendar: calendar,
            routineEnabled: routineEnabled,
            deliveryMode: deliveryMode
        )
    }

    /// Evaluates whether `now`'s local hour falls within `[startHour, endHour)` (handling overnight wrap).
    public static func isInQuietHours(
        now: Date,
        startHour: Int,
        endHour: Int,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Bool {
        let start = ProactivitySettings.clampHour(startHour)
        let end = ProactivitySettings.clampHour(endHour)
        guard start != end else { return false }
        let hour = calendar.component(.hour, from: now)
        if start < end {
            return hour >= start && hour < end
        }
        // Overnight window (for example 22:00 through 08:00).
        return hour >= start || hour < end
    }
}
