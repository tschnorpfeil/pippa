import AppKit
import Carbon
import Foundation

/// For checks: Apple Events consent with a stand-in for the system call (for example one that hangs).
public enum AppleEventsConsentCheck {
    public static func permission(bundle: String, appName: String, ask: Bool, limit: TimeInterval,
                                  determine: @escaping @Sendable (String, Bool) -> OSStatus) async -> IntegrationAccess {
        let real = AppleEvents.determine
        AppleEvents.determine = determine
        defer { AppleEvents.determine = real }
        return await AppleEvents.permission(bundle: bundle, appName: appName, ask: ask, limit: limit)
    }
}

/// Deterministic checks of the real serial queue and dispatch boundary, without scripting any app.
public enum AppleEventsExecutionCheck {
    public static func perform<T: Sendable>(mutation: Bool = false, _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await AppleEvents.perform {
            if mutation { try PippaMCPWriteLease.current?.beginDispatch() }
            return try body()
        }
    }
}

enum AppleEvents {
    static func isRunning(_ i: Integration) -> Bool { isRunning(bundle: i.bundleIdentifier) }

    static func isRunning(bundle: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
    }

    /// Is the app installed on this Mac? (Only asks LaunchServices, starts nothing.)
    static func isInstalled(bundle: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil
    }

    /// Starts the app invisibly in the background if it is not running.
    static func launchHidden(_ i: Integration) async -> Bool { await launchHidden(bundle: i.bundleIdentifier) }

    /// As above, for apps without their own case in `Integration` (Photos).
    static func launchHidden(bundle: String) async -> Bool {
        if isRunning(bundle: bundle) { return true }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return false }
        // LaunchServices can leave its completion pending. Bound the whole launch, not just the running-state poll,
        // so a requested Mail search/draft (and the permission page) always gets an answer.
        return await firstAnswer(within: 5, fallback: false) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.hides = true
            config.addsToRecentItems = false
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
            for _ in 0..<25 where !isRunning(bundle: bundle) { try? await Task.sleep(for: .milliseconds(200)) }
            return isRunning(bundle: bundle)
        }
    }

    /// May Pippa ask the app via Apple Events? `ask: true` shows the system prompt and waits for the answer.
    static func permission(_ i: Integration, ask: Bool) async -> IntegrationAccess {
        await permission(bundle: i.bundleIdentifier, appName: i.appName, ask: ask)
    }

    /// Reading the state needs no person, asking waits for one (the dialog).
    static let readLimit: TimeInterval = 3
    static let askLimit: TimeInterval = 60

    /// The system call; checks replace it with one that hangs.
    nonisolated(unsafe) static var determine: @Sendable (_ bundle: String, _ ask: Bool) -> OSStatus = { bundle, ask in
        let target = NSAppleEventDescriptor(bundleIdentifier: bundle)
        guard let desc = target.aeDesc else { return OSStatus(procNotFound) }
        // With a prompt, wildcards are not allowed: a concrete read event (core/getd).
        return AEDeterminePermissionToAutomateTarget(desc, AEEventClass(kCoreEventClass), AEEventID(kAEGetData), ask)
    }

    /// Checks waiting for the answer of a call already running, per app and kind.
    nonisolated(unsafe) private static var waiting: [String: [@Sendable (OSStatus) -> Void]] = [:]
    private static let waitingLock = NSLock()

    /// As above, for apps without their own case in `Integration` (Excel).
    ///
    /// macOS can leave this call hanging for minutes (seen with Mail running: two threads stuck, a dialog that never
    /// showed). So it runs on a thread of its own, not in Swift's small shared pool where it would hold up other work,
    /// and after `limit` the answer is "not responding". The hanging call stays parked; while it runs, further checks for
    /// the same app share its answer instead of starting another one.
    static func permission(bundle: String, appName: String, ask: Bool, limit: TimeInterval? = nil) async -> IntegrationAccess {
        let key = "\(bundle)|\(ask)"
        let status: OSStatus? = await withCheckedContinuation { (cont: CheckedContinuation<OSStatus?, Never>) in
            let once = ResumeOnce(cont)
            let first: Bool = waitingLock.withLock {
                let first = waiting[key] == nil
                waiting[key, default: []].append { once.resume($0) }
                return first
            }
            if first {
                Thread.detachNewThread {
                    let status = determine(bundle, ask)
                    let waiters = waitingLock.withLock { waiting.removeValue(forKey: key) ?? [] }
                    waiters.forEach { $0(status) }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + (limit ?? (ask ? askLimit : readLimit))) { once.resume(nil) }
        }
        guard let status else {
            DiagnosticsLog.shared.event("erlaubnis-haengt", ["app": appName, "fragen": String(ask)])
            return .unavailable(L("%@ isn’t responding right now.", table: "Core", appName))
        }
        switch Int(status) {
        case Int(noErr): return .granted
        case -1744: return .notDetermined           // errAEEventWouldRequireUserConsent
        case -1743: return .denied                  // errAEEventNotPermitted
        case Int(procNotFound): return .unavailable(L("%@ isn’t open right now.", table: "Core", appName))
        default: return .unavailable(L("%@ isn’t responding right now.", table: "Core", appName))
        }
    }

    /// Calls a handler of an AppleScript with parameters. Texts go in as parameters,
    /// never into the script text, so nothing can be injected.
    /// Only inside `perform`.
    static func call(_ source: String, handler: String, _ args: [NSAppleEventDescriptor] = [], app: Integration,
                     mutation: Bool = false) throws -> NSAppleEventDescriptor {
        try call(source, handler: handler, args, appName: app.appName, mutation: mutation)
    }

    /// AppleScript runs on its own serial queue, not the main thread: a slow Mail or Excel (up to 20 s) never freezes
    /// the pill. NSAppleScript is not thread-safe, so every script and the compiled cache stay on this one queue.
    private static let queue = DispatchQueue(label: "app.pippa.applescript", qos: .userInitiated)

    static func perform<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        let lease = PippaMCPWriteLease.current
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    try PippaMCPWriteLease.$current.withValue(lease) {
                        try lease?.check()
                        return try body()
                    }
                })
            }
        }
    }

    /// Compiled once per source text (the Mail reply search calls the same script once per mailbox).
    /// Handlers keep no state between calls: every value they use comes in as a parameter. Only touched on `queue`.
    nonisolated(unsafe) private static var compiled: [String: NSAppleScript] = [:]

    /// As above; `appName` only for the error message (no permission, app not open). Only inside `perform`.
    static func call(_ source: String, handler: String, _ args: [NSAppleEventDescriptor] = [], appName: String,
                     mutation: Bool = false) throws -> NSAppleEventDescriptor {
        var error: NSDictionary?
        let script: NSAppleScript
        if let known = compiled[source] {
            script = known
        } else {
            guard let fresh = NSAppleScript(source: source), fresh.compileAndReturnError(&error) else { throw PippaError.notAvailable }
            compiled[source] = fresh
            script = fresh
        }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
                                           targetDescriptor: .currentProcess(), returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: handler.lowercased()), forKeyword: AEKeyword(keyASSubroutineName))
        let list = NSAppleEventDescriptor.list()
        for (i, a) in args.enumerated() { list.insert(a, at: i + 1) }
        event.setParam(list, forKeyword: AEKeyword(keyDirectObject))
        try PippaMCPWriteLease.current?.check()
        if mutation { try PippaMCPWriteLease.current?.beginDispatch() }
        let result = script.executeAppleEvent(event, error: &error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            switch code {
            case -1743, -1744: throw PippaError.accessDenied(appName)
            case -600, -609: throw PippaError.appNotOpen(appName)
            default: throw PippaError.notAvailable
            }
        }
        return result
    }

    static func items(_ d: NSAppleEventDescriptor) -> [NSAppleEventDescriptor] {
        guard d.descriptorType == typeAEList, d.numberOfItems > 0 else { return [] }
        return (1...d.numberOfItems).compactMap { d.atIndex($0) }
    }

    static func strings(_ d: NSAppleEventDescriptor?) -> [String] {
        guard let d else { return [] }
        return items(d).map { $0.stringValue ?? "" }
    }
}
