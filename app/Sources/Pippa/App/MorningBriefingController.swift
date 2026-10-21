import AppKit
import Combine
import PippaCore
import UserNotifications

@MainActor
final class MorningBriefingController: ObservableObject {
    @Published private(set) var configuration = MorningBriefingConfiguration()
    @Published private(set) var latest: MorningBriefingResult?
    @Published private(set) var running = false
    @Published private(set) var discovering = false
    @Published private(set) var availableSources: [MorningBriefingSource] = []
    @Published private(set) var sourceFailures: [MorningBriefingSource.Kind: MorningBriefingReadFailure] = [:]
    @Published private(set) var errorText: String?
    @Published private(set) var notificationNote: String?
    var needsAttention: Bool { errorText != nil || !(latest?.issues.isEmpty ?? true) }
    var storageAvailable: Bool { store != nil }
    var onResult: ((MorningBriefingResult) -> Void)?
    private var store: MorningBriefingStore?
    private let reader: any MorningBriefingReading
    private let demo: Bool
    private var timer: Task<Void, Never>?
    private var run: Task<Void, Never>?
    private var generation = UUID()
    private var storagePaused = false
    private var observers: [NSObjectProtocol] = []
    private static let notificationID = "pippa.morning-briefing"

    init(baseDirectory: URL = Pippa.supportDirectory, reader: any MorningBriefingReading = SystemMorningBriefingReader(),
         demo: Bool = false) {
        self.reader = reader; self.demo = demo
        do {
            let store = try MorningBriefingStore(baseDirectory: baseDirectory)
            self.store = store; configuration = store.configuration; latest = store.latest
        } catch { errorText = T("I couldn’t open your morning overview settings. Automatic checks are off.", table: "MorningBriefing") }
    }

    func start() {
        guard timer == nil, !demo, !storagePaused else { return }
        if observers.isEmpty {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.checkIfDue() } })
            observers.append(NotificationCenter.default.addObserver(forName: NSNotification.Name.NSSystemTimeZoneDidChange,
                object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.checkIfDue() } })
        }
        checkIfDue()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                self?.checkIfDue()
            }
        }
    }

    func checkIfDue(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) {
        guard !storagePaused, let store else { return }
        do {
            let current = try store.current()
            configuration = current.configuration; latest = current.latest
            guard configuration.enabled, !running else { return }
            guard let claim = try store.claim(now: now, calendar: calendar) else { return }
            let selected = store.configuration
            let generation = generation
            running = true
            run = Task { [weak self] in
                guard let self else { return }
                defer {
                    if self.generation == generation {
                        self.running = false; self.run = nil
                        if let current = try? store.current() { self.configuration = current.configuration; self.latest = current.latest }
                    }
                }
                let result = await MorningBriefingReader.run(configuration: selected, occurrence: claim.occurrence,
                    reader: self.reader, now: now, isCurrent: { @Sendable [weak self] in
                        await MainActor.run { self?.store?.isCurrent(claim) == true }
                    })
                guard !Task.isCancelled, self.generation == generation, let result else { return }
                do {
                    guard try store.finish(claim, result: result) else { return }
                    self.latest = result; self.errorText = nil; self.onResult?(result)
                    if !self.demo, store.allowsNotification(after: claim) { await self.notify(claim) }
                } catch { self.storageFailure() }
            }
        } catch { storageFailure() }
    }

    /// Called only by the explicit Save control. Editing a schedule fences any ongoing run.
    func save(_ value: MorningBriefingConfiguration) {
        guard let store else { return }
        invalidate()
        do {
            try store.configure(value); configuration = store.configuration; latest = store.latest
            storagePaused = false; errorText = nil
            if !demo { start(); checkIfDue() }
        }
        catch { storageFailure() }
    }

    func pause() {
        var value = configuration; value.enabled = false
        save(value)
    }

    func delete() {
        guard let store else { return }
        invalidate()
        do {
            try store.delete(); configuration = store.configuration; latest = nil
            availableSources = []; sourceFailures = [:]; notificationNote = nil; errorText = nil; storagePaused = false
        } catch { storageFailure() }
    }

    private func invalidate() {
        generation = UUID(); run?.cancel(); run = nil; running = false
        if !demo {
            let notifications = UNUserNotificationCenter.current()
            notifications.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
            notifications.removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
        }
    }

    private func storageFailure() {
        invalidate()
        errorText = T("I couldn’t save the morning overview. Automatic checks are paused until you save again.", table: "MorningBriefing")
        // Do not continue using an old in-memory enabled configuration after a failed write.
        timer?.cancel(); timer = nil
        storagePaused = true
    }

    /// Source names are discovered only when the person opens the chooser, never by the scheduler.
    func loadSources() async {
        guard !discovering, !demo else { return }
        discovering = true
        let token = generation
        defer { discovering = false }
        var found: [MorningBriefingSource] = []
        var failures: [MorningBriefingSource.Kind: MorningBriefingReadFailure] = [:]
        for kind in MorningBriefingSource.Kind.allCases {
            guard generation == token else { return }
            do { found += try await reader.sources(for: kind) }
            catch { failures[kind] = error as? MorningBriefingReadFailure ?? .unavailable }
        }
        guard generation == token else { return }
        availableSources = found; sourceFailures = failures
    }

    /// The only permission request entry point: a user presses Allow in this feature's settings.
    func requestAccess(_ kind: MorningBriefingSource.Kind) async {
        guard !demo else { return }
        let token = generation
        let integration: Integration = kind == .calendar ? .calendar : .reminders
        if sourceFailures[kind] == .denied {
            NSWorkspace.shared.open(integration.settingsURL)
        } else {
            _ = await SystemIntegrations().requestAccess(integration)
            guard generation == token else { return }
            await loadSources()
        }
    }

    func requestNotifications() async {
        guard !demo else { return }
        let token = generation
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
            guard generation == token else { return }
            notificationNote = granted
                ? T("Notifications are allowed. They contain no appointment or task details.", table: "MorningBriefing")
                : T("Notifications are off in macOS. Your overview will still be available in Pippa.", table: "MorningBriefing")
        } catch {
            guard generation == token else { return }
            notificationNote = T("Notifications are off in macOS. Your overview will still be available in Pippa.", table: "MorningBriefing")
        }
    }

    private func notify(_ claim: MorningBriefingStore.Claim) async {
        guard let store, store.allowsNotification(after: claim), !Task.isCancelled else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard store.allowsNotification(after: claim), !Task.isCancelled,
              settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "Pippa"
        content.body = T("Your morning overview is ready. Open Pippa to see it.", table: "MorningBriefing")
        do {
            try await center.add(UNNotificationRequest(identifier: Self.notificationID, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
            if !store.allowsNotification(after: claim) || Task.isCancelled {
                center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
                center.removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
            }
        } catch { /* The saved overview remains available if macOS declines notification delivery. */ }
    }

    func openSource(_ entry: MorningBriefingEntry) {
        guard !demo else { return }
        if entry.source.kind == .calendar {
            var components = URLComponents()
            components.scheme = "ical"; components.host = "ekevent"; components.path = "/" + entry.id
            components.queryItems = [URLQueryItem(name: "method", value: "show"), URLQueryItem(name: "options", value: "more")]
            if let url = components.url, NSWorkspace.shared.open(url) { return }
        }
        let integration: Integration = entry.source.kind == .calendar ? .calendar : .reminders
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: integration.bundleIdentifier) {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        }
    }
}
