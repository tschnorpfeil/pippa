import Foundation
import PippaCore

// "What Pippa may do": checking never asks, each Allow asks only its own permission, answers are remembered.
func runPermissionChecks() async {
    print("\n— Permissions —")

    let name = "permission-check-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { dropDefaultsSuite(defaults, name) }
    let home = fm.temporaryDirectory.appendingPathComponent("pippa-permission-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: home) }
    for folder in ["Desktop", "Documents", "Downloads"] {
        try? fm.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
    }
    let asked = AskLog()
    let desk = SystemPermissions(access: { $0 == .calendar ? .notDetermined : .unavailable("Mail ist nicht offen") },
                                 request: { await asked.add($0); return .granted },
                                 defaults: defaults, home: home)

    await checkAsync("Permissions: folders never asked show Allow, without reading them") {
        let state = await desk.state(.folders)
        return state == .notAsked
    }
    await checkAsync("Permissions: Allow reads the folders once, the answer is remembered") {
        let first = await desk.request(.folders)
        let later = await desk.state(.folders)
        return first == .granted && later == .granted
    }
    await checkAsync("Permissions: a folder that refuses reading counts as declined") {
        let locked = home.appendingPathComponent("Documents")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let answer = await desk.request(.folders)
        let later = await desk.state(.folders)
        return answer == .denied && later == .denied
    }
    await checkAsync("Permissions: Calendar comes from the integrations, asking only the one pressed") {
        let calendar = await desk.state(.calendar)
        let granted = await desk.request(.calendar)
        let log = await asked.all
        return calendar == .notAsked && granted == .granted && log == [.calendar]
    }
    check("Permissions: a row without its dialog text in Info.plist stays hidden (macOS would end the app)") {
        !desk.applies(.contacts) && !desk.applies(.photos) && !desk.applies(.folders)
    }
    check("Permissions page: after Load and after Later, never before the download question is answered") {
        let downloading = PermissionOnboarding.shows(pending: true, setup: .downloading(progress: 0.4, remaining: nil), deferred: false)
        let later = PermissionOnboarding.shows(pending: true, setup: .askDownload(bytes: 1), deferred: true)
        let asking = PermissionOnboarding.shows(pending: true, setup: .askDownload(bytes: 1), deferred: false)
        let preparing = PermissionOnboarding.shows(pending: true, setup: .preparing(adoptingFrom: nil), deferred: false)
        let done = PermissionOnboarding.shows(pending: false, setup: .ready(adoptedFrom: nil), deferred: false)
        return downloading && later && !asking && !preparing && !done
    }
    check("Permissions page: closed with × it comes back at a later start, but not forever") {
        PermissionOnboarding.remindsAtStart(pending: true, dismissals: 0)
            && PermissionOnboarding.remindsAtStart(pending: true, dismissals: 1)
            && !PermissionOnboarding.remindsAtStart(pending: true, dismissals: PermissionOnboarding.reminders)
            && !PermissionOnboarding.remindsAtStart(pending: false, dismissals: 0)
    }
    check("Permissions page: opening Pippa brings it back until Continue or ×") {
        let ready = PiSetupState.ready(adoptedFrom: nil)
        return PermissionOnboarding.reopens(pending: true, setup: ready, deferred: false, closedThisRun: false)
            && !PermissionOnboarding.reopens(pending: true, setup: ready, deferred: false, closedThisRun: true)
            && !PermissionOnboarding.reopens(pending: false, setup: ready, deferred: false, closedThisRun: false)
            && !PermissionOnboarding.reopens(pending: true, setup: .askDownload(bytes: 1), deferred: false, closedThisRun: false)
    }
    check("Permissions page: Continue counts only the rows nobody answered") {
        PermissionOnboarding.undecided([.folders: .granted, .calendar: .notAsked, .photos: .denied, .notes: .notAsked,
                                        .externalDrives: .unavailable("kein Laufwerk")]) == 2
    }
    await checkAsync("Tidying: a folder macOS refused is told apart from an empty one") {
        let empty = home.appendingPathComponent("Desktop")
        let locked = home.appendingPathComponent("Downloads")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let refused = await PermissionOnboarding.folderRefused(locked)
        let open = await PermissionOnboarding.folderRefused(empty)
        return refused && !open
    }
    await checkAsync("Permissions: demo asks only the pressed row; declined stays declined") {
        let demo = DemoPermissions()
        let reminders = await demo.request(.reminders)
        let photos = await demo.request(.photos)
        let notes = await demo.state(.notes)
        return reminders == .granted && photos == .denied && notes == .notAsked
    }

    await checkAsync("Permissions: a hanging Apple Events check gives up in time and runs only once per app") {
        let calls = Counter()
        let release = DispatchSemaphore(value: 0)
        defer { for _ in 0..<4 { release.signal() } }
        let hang: @Sendable (String, Bool) -> OSStatus = { _, _ in calls.add(); release.wait(); return 0 }
        let started = Date()
        async let first = AppleEventsConsentCheck.permission(bundle: "com.example.hang", appName: "Mail", ask: false, limit: 0.5, determine: hang)
        async let second = AppleEventsConsentCheck.permission(bundle: "com.example.hang", appName: "Mail", ask: false, limit: 0.5, determine: hang)
        let (a, b) = await (first, second)
        let timedOut: (IntegrationAccess) -> Bool = { if case .unavailable = $0 { return true }; return false }
        return timedOut(a) && timedOut(b) && calls.value == 1 && Date().timeIntervalSince(started) < 3
    }
    await checkAsync("Permissions: one row that hangs never holds up the others, and Allow stops spinning") {
        let hanging = HangingDesk()
        let started = Date()
        let states = await hanging.states([.iCloudDrive, .mail, .calendar], previous: [.calendar: .denied], limit: 0.3)
        let asked = await hanging.request(.iCloudDrive, limit: 0.3)
        let quick = await hanging.request(.calendar, limit: 0.3)
        return states[.mail] == .notAsked && states[.calendar] == .denied && states[.iCloudDrive] == .granted
            && asked == nil && quick == .granted && Date().timeIntervalSince(started) < 3
    }
}

private actor AskLog {
    private(set) var all: [Integration] = []
    func add(_ integration: Integration) { all.append(integration) }
}

private final class Counter: @unchecked Sendable {
    private var count = 0
    private let lock = NSLock()
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// Mail's check and every request for iCloud Drive never come back; Calendar hangs on reading only.
private struct HangingDesk: PermissionDesk {
    func applies(_ permission: MacPermission) -> Bool { true }
    func state(_ permission: MacPermission) async -> PermissionState {
        switch permission {
        case .mail, .calendar: try? await Task.sleep(for: .seconds(30)); return .granted
        default: return .granted
        }
    }
    func request(_ permission: MacPermission) async -> PermissionState {
        if permission == .iCloudDrive { try? await Task.sleep(for: .seconds(30)) }
        return .granted
    }
}
