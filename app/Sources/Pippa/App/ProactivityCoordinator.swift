import AppKit
import Combine
import EventKit
import PippaCore

/// Calm, opt-in proactivity (PippaCore/Proactivity): a Morning Brief and new files in one watched folder, shown as a
/// quiet card in Pippa Island at most twice a day.
///
/// Rules this type keeps:
/// - Off (the default): no timer, no folder watcher, no EventKit read, no database opened. Only settings.json is read.
/// - Never opens the island by itself and never takes focus: a delivered nudge only lights the menu bar dot.
/// - Never asks for Calendar or Reminders access: it reads only what the person already allowed.
/// - Never launches Mail or the local model server: the brief is built in code (0 tokens), files get the AI built
///   into macOS at most.
@MainActor
final class ProactivityCoordinator: ObservableObject {
    static let shared = ProactivityCoordinator()

    /// How often an enabled coordinator looks again (besides waking from sleep and folder changes).
    static let tickInterval: TimeInterval = 15 * 60
    /// Folder events come in bursts (a download writes several times): wait this long after the last one.
    static let folderDebounce: Duration = .seconds(2)
    /// Hours the Morning Brief may be set to in Settings.
    static let morningBriefHours = 6...11

    @Published private(set) var settings: ProactivitySettings
    /// The one nudge waiting in the island. Set only after `ProactivityGate` and `recordDelivery` allowed it.
    @Published private(set) var activeNudge: ProactiveMatter?
    /// Result of "Preview now" in Settings, or why there is nothing to show.
    @Published private(set) var previewText: String?
    @Published private(set) var isPreviewing = false
    @Published private(set) var focusAuthorization = FocusAuthorizationState.notDetermined

    private var matterStore: ProactiveMatterStore?
    private var jobStore: DurableJobStore?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var folderSource: DispatchSourceFileSystemObject?
    private var watchedFolder: URL?
    private var folderDebounceTask: Task<Void, Never>?
    private var folderSetupTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var tickGeneration: UInt64 = 0
    private var scanGeneration: UInt64 = 0
    private var folderGeneration: UInt64 = 0
    private var needsRescan = false
    private var isWatching = false
    private let focusReader = SystemFocusStatusReader()

    private init() {
        settings = PippaSettings.load(from: PiSession.settingsDirectory).effectiveProactivity
    }

    /// At launch: starts watching only when the person switched calm notices on.
    func start() {
        guard settings.enabled else { return }
        refreshFocusAuthorization()
        startWatching()
    }

    /// Re-reads Focus authorization state (for Settings on appear or app activation).
    func refreshFocusAuthorization() {
        focusAuthorization = SystemFocusStatusReader.currentAuthorizationState()
    }

    // MARK: Settings

    func setEnabled(_ on: Bool) {
        guard settings.enabled != on else { return }
        update { $0.enabled = on }
        if on {
            focusAuthorization = SystemFocusStatusReader.currentAuthorizationState()
            if focusAuthorization == .notDetermined {
                // Asked here only: the person just switched this on in Settings.
                Task { [weak self] in
                    let state = await SystemFocusStatusReader.requestAuthorizationIfNeeded()
                    self?.focusAuthorization = state
                }
            }
        }
    }

    func setMorningBrief(enabled: Bool) { update { $0.morningBriefEnabled = enabled } }

    func setMorningBrief(hour: Int) {
        let clamped = min(max(hour, Self.morningBriefHours.lowerBound), Self.morningBriefHours.upperBound)
        update { $0.morningBriefHour = clamped; $0.morningBriefMinute = 0 }
    }

    func setQuietHours(enabled: Bool) {
        update { $0.quietHoursEnabled = enabled; $0.quietStartHour = 22; $0.quietEndHour = 8 }
    }

    func resetMuted() { update { $0.mutedKinds = [] } }

    /// "Choose…": the person picks the folder in the open panel, which also grants Pippa access to it.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = T("Watch Folder", table: "Settings")
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bookmark = (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        update { $0.watchedFolderPath = url.path; $0.watchedFolderBookmark = bookmark }
    }

    func removeFolder() {
        update { $0.watchedFolderPath = nil; $0.watchedFolderBookmark = nil }
    }

    /// The watched folder's name for Settings.
    var watchedFolderName: String? {
        settings.watchedFolderPath.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    /// Changes, saves and applies the settings: watchers follow `enabled`, folder changes and unmuting.
    private func update(_ change: (inout ProactivitySettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        let previous = settings
        let folderChanged = next.watchedFolderPath != previous.watchedFolderPath || next.watchedFolderBookmark != previous.watchedFolderBookmark
        let watchedFileUnmuted = previous.isMuted(.watchedFile) && !next.isMuted(.watchedFile)
        let relaxed = next.mutedKinds.count < previous.mutedKinds.count
            || (!previous.morningBriefEnabled && next.morningBriefEnabled)
            || (previous.morningBriefHour != next.morningBriefHour)
            || (previous.quietHoursEnabled && !next.quietHoursEnabled)
        settings = next
        save()
        if !next.enabled {
            stopWatching()
            activeNudge = nil
            previewText = nil
            return
        }
        if !isWatching {
            startWatching()
        } else {
            if folderChanged || watchedFileUnmuted {
                restartFolderWatch()
            }
            if relaxed {
                tick()
            }
        }
        if let nudge = activeNudge, next.isMuted(nudge.kind) || (nudge.kind == .morningBrief && !next.morningBriefEnabled) {
            activeNudge = nil
        }
    }

    private func save() {
        var file = PippaSettings.load(from: PiSession.settingsDirectory)
        file.proactivity = settings
        do { try file.save(to: PiSession.settingsDirectory) }
        catch { DiagnosticsLog.shared.event("proaktiv-speichern-fehler", [:]) }
    }

    // MARK: Watching

    private func startWatching() {
        guard settings.enabled, !isWatching else { return }
        isWatching = true
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                         object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ProactivityCoordinator.shared.tick() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { _ in
            MainActor.assumeIsolated { ProactivityCoordinator.shared.tick() }
        }
        timer?.tolerance = 60
        restartFolderWatch()
        tick()
    }

    private func stopWatching() {
        isWatching = false
        timer?.invalidate()
        timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        stopFolderWatch()
        tickGeneration &+= 1
        tickTask?.cancel()
        tickTask = nil
    }

    private func restartFolderWatch() {
        stopFolderWatch()
        guard settings.enabled, !settings.isMuted(.watchedFile) else { return }
        let bookmark = settings.watchedFolderBookmark
        let fallbackPath = settings.watchedFolderPath
        guard bookmark != nil || fallbackPath != nil else { return }
        folderGeneration &+= 1
        let gen = folderGeneration
        folderSetupTask = Task { [weak self] in
            // Resolve bookmark off MainActor with `.withoutMounting` so offline network/external volumes never block launch.
            let resolved: URL? = await Task.detached(priority: .utility) {
                Self.resolveFolderOffMain(bookmark: bookmark, fallbackPath: fallbackPath)
            }.value
            guard !Task.isCancelled, let self, self.folderGeneration == gen,
                  self.settings.enabled, !self.settings.isMuted(.watchedFile), let url = resolved else { return }
            self.attachFolderSource(url: url)
        }
    }

    private func attachFolderSource(url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            if accessed { url.stopAccessingSecurityScopedResource() }
            DiagnosticsLog.shared.event("proaktiv-ordner-fehler", [:])
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .rename, .delete, .extend], queue: .main)
        source.setEventHandler { [weak source] in
            let flags = source?.data ?? []
            MainActor.assumeIsolated {
                if flags.contains(.delete) || flags.contains(.rename) {
                    ProactivityCoordinator.shared.restartFolderWatch()
                } else {
                    ProactivityCoordinator.shared.folderChanged()
                }
            }
        }
        source.setCancelHandler {
            close(descriptor)
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        source.resume()
        folderSource = source
        watchedFolder = url
        // Files that arrived while Pippa was not running.
        scheduleScan(after: .zero)
    }

    private func stopFolderWatch() {
        folderGeneration &+= 1
        folderSetupTask?.cancel()
        folderSetupTask = nil
        folderDebounceTask?.cancel()
        folderDebounceTask = nil
        scanGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
        needsRescan = false
        folderSource?.cancel()
        folderSource = nil
        watchedFolder = nil
    }

    /// Resolves the watched folder from its security-scoped bookmark off MainActor without mounting offline volumes.
    private nonisolated static func resolveFolderOffMain(bookmark: Data?, fallbackPath: String?) -> URL? {
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) {
                return url
            }
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) {
                return url
            }
        }
        return fallbackPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func folderChanged() { scheduleScan(after: Self.folderDebounce) }

    private func scheduleScan(after delay: Duration) {
        folderDebounceTask?.cancel()
        folderDebounceTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            self.scanFolder()
        }
    }

    private func scanFolder() {
        guard settings.enabled, !settings.isMuted(.watchedFile), let folder = watchedFolder else { return }
        if scanTask != nil {
            needsRescan = true
            return
        }
        needsRescan = false
        scanGeneration &+= 1
        let gen = scanGeneration
        let lang = Self.language
        scanTask = Task { [weak self] in
            guard let self else { return }
            guard let store = await self.ensureMatterStore() else {
                if self.scanGeneration == gen { self.scanTask = nil }
                return
            }
            let scanner = WatchedFolderScanner(store: store, language: lang)
            do {
                let report = try await scanner.scan(folderURL: folder)
                if !Task.isCancelled {
                    DiagnosticsLog.shared.event("proaktiv-ordner", ["dateien": String(report.scannedFiles), "hinweise": String(report.actionableMatters.count)])
                }
            } catch {
                if !Task.isCancelled {
                    DiagnosticsLog.shared.event("proaktiv-ordner-fehler", [:])
                }
            }
            guard self.scanGeneration == gen else { return }
            self.scanTask = nil
            if self.needsRescan {
                self.needsRescan = false
                self.scheduleScan(after: Self.folderDebounce)
            } else {
                self.tick()
            }
        }
    }

    // MARK: Delivery

    /// Prepares today's brief when it is due and offers at most one matter, if the gate lets it through.
    func tick() {
        guard settings.enabled, isWatching, tickTask == nil, activeNudge == nil else { return }
        tickGeneration &+= 1
        let gen = tickGeneration
        tickTask = Task { [weak self] in
            guard let self else { return }
            await self.runTick()
            if self.tickGeneration == gen { self.tickTask = nil }
        }
    }

    private func runTick() async {
        guard let store = await ensureMatterStore() else { return }
        let now = Date()
        let todayKey = ProactiveMatterStore.dayKey(for: now)

        // Restore a still-valid previously offered notice after app restart without re-spending daily budget.
        let offered = (try? await store.matters(states: [.offered])) ?? []
        for matter in offered.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            guard !Task.isCancelled, settings.enabled, activeNudge == nil else { return }
            if settings.isMuted(matter.kind) { continue }
            if matter.kind == .morningBrief && (!settings.morningBriefEnabled || matter.matterKey != MorningBriefBuilder.matterKey(for: todayKey)) {
                continue
            }
            let fresh = (try? await store.isFresh(matterID: matter.id, expectedSourceVersion: matter.sourceVersion)) ?? false
            if fresh {
                activeNudge = matter
                return
            }
        }

        var candidates: [ProactiveMatter] = []
        if settings.morningBriefEnabled, !settings.isMuted(.morningBrief), morningBriefDue(now: now), let brief = await buildBrief(day: now, store: store) {
            candidates.append(brief)
        }
        let waiting = (try? await store.matters(states: [.open, .snoozed])) ?? []
        candidates += waiting
            .filter { $0.kind != .morningBrief || $0.matterKey == MorningBriefBuilder.matterKey(for: todayKey) }
            .filter { $0.state == .open || ($0.snoozedUntil.map { $0 <= now } ?? false) }
            .sorted { $0.createdAt < $1.createdAt }
        var seen = Set<UUID>()
        for matter in candidates where seen.insert(matter.id).inserted {
            guard !Task.isCancelled, settings.enabled, activeNudge == nil else { return }
            if await deliver(matter, store: store, now: now) { return }
        }
    }

    /// Delivers `matter` when `ProactivityGate` says so and the store recorded it under the daily cap.
    private func deliver(_ matter: ProactiveMatter, store: ProactiveMatterStore, now: Date) async -> Bool {
        guard matter.state == .open || matter.state == .snoozed else { return false }
        let dayKey = ProactiveMatterStore.dayKey(for: now)
        let delivered = (try? await store.deliveredCount(forDayKey: dayKey)) ?? Int.max
        let fresh = (try? await store.isFresh(matterID: matter.id, expectedSourceVersion: matter.sourceVersion)) ?? false
        let decision = ProactivityGate.evaluate(matter: matter, settings: settings, deliveredToday: delivered,
                                                focusReader: focusReader, isAnswering: ChatModel.shared.isAnswering,
                                                isFresh: fresh, now: now)
        guard decision == .deliver else { return false }
        let result = try? await store.recordDelivery(matterID: matter.id, kind: matter.kind, dayKey: dayKey,
                                                     cap: settings.dailyCap, expectedSourceVersion: matter.sourceVersion, shownAt: now)
        guard case .recorded = result, settings.enabled else { return false }
        let offered = ((try? await store.matter(id: matter.id)) ?? nil) ?? matter
        DiagnosticsLog.shared.event("proaktiv-hinweis", ["art": matter.kind.rawValue])
        activeNudge = offered
        return true
    }

    private func morningBriefDue(now: Date) -> Bool {
        let calendar = Calendar.autoupdatingCurrent
        guard let due = calendar.date(bySettingHour: settings.morningBriefHour, minute: settings.morningBriefMinute, second: 0, of: now) else {
            return false
        }
        return now >= due
    }

    /// Today's brief from already allowed data only. Short-circuits before reading EventKit if today's job already completed.
    private func buildBrief(day: Date, store: ProactiveMatterStore) async -> ProactiveMatter? {
        guard let jobs = await ensureJobStore() else { return nil }
        let dayKey = ProactiveMatterStore.dayKey(for: day)
        let reqKey = MorningBriefBuilder.requestKey(for: dayKey)
        let matKey = MorningBriefBuilder.matterKey(for: dayKey)
        if let existing = try? await jobs.record(requestKey: reqKey),
           existing.state == .completed || existing.state == .running {
            return (try? await store.matter(key: matKey)) ?? nil
        }
        let input = await briefInput(day: day, store: store)
        do {
            switch try await MorningBriefBuilder.build(input: input, jobStore: jobs, matterStore: store) {
            case .prepared(_, let matter, _): return matter
            case .alreadyBuilt(_, let matter, _): return matter
            case .silent: return nil
            }
        } catch {
            DiagnosticsLog.shared.event("proaktiv-brief-fehler", [:])
            return nil
        }
    }

    /// Reads Calendar and Reminders only when access was granted before; never asks.
    private func briefInput(day: Date, store: ProactiveMatterStore?) async -> MorningBriefInput {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let integrations = SystemIntegrations()
        var events: [CalendarEvent] = []
        if case .granted = await integrations.access(.calendar) {
            events = (try? await integrations.events(in: DateInterval(start: start, end: end), limit: CalendarReader.limit).events) ?? []
        }
        var reminders: [ReminderItem] = []
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess {
            reminders = (try? await integrations.openReminders(dueBefore: end, limit: 20).items) ?? []
        }
        var open: [ProactiveMatter] = []
        if let store {
            open = ((try? await store.matters(states: [.open, .offered, .snoozed])) ?? []).filter { $0.kind != .morningBrief }
        }
        return MorningBriefInput(day: day, events: events, reminders: reminders, openMatters: open, calendar: calendar, language: Self.language)
    }

    /// "Preview now" in Settings: today's brief as text, built in code, without storing or counting it.
    func previewMorningBriefNow() {
        guard !isPreviewing else { return }
        isPreviewing = true
        Task { [weak self] in
            guard let self else { return }
            let store = self.settings.enabled ? await self.ensureMatterStore() : nil
            let input = await self.briefInput(day: Date(), store: store)
            let allowed = EKEventStore.authorizationStatus(for: .event) == .fullAccess
                && EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
            var text: String
            if let content = MorningBriefBuilder.format(input) {
                text = content.title + "\n" + content.summary
            } else {
                text = T("Nothing on your calendar or reminders today. On a day like this Pippa stays quiet.", table: "Settings")
            }
            if !allowed {
                text += "\n" + T("Pippa reads only Calendar and Reminders you already allowed. You can allow them under Permissions.", table: "Settings")
            }
            self.previewText = text
            self.isPreviewing = false
        }
    }

    // MARK: The person's answers

    /// "Open in Chat": starts a clean conversation with the prepared question and files, and marks the notice
    /// resolved via `PersonAction` so it does not stay orphaned in `.offered` forever.
    func openInChat(_ matter: ProactiveMatter) {
        Island.shared.close()
        let chat = ChatModel.shared
        chat.newConversation()
        ChatWindow.shared.show()
        let files = matter.preparedFiles.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        chat.attachments = files
        chat.frontApp = nil
        chat.draft = matter.preparedPrompt
        apply(.resolve(surface: .island), to: matter)
    }

    func markDone(_ matter: ProactiveMatter) {
        apply(.resolve(surface: .island), to: matter)
    }

    func snooze(_ matter: ProactiveMatter, hours: Int = 3) {
        let until = Date().addingTimeInterval(TimeInterval(max(1, hours)) * 3600)
        apply(.snooze(until: until, surface: .island), to: matter)
    }

    func muteKind(_ kind: ProactiveMatterKind, dismissing matter: ProactiveMatter) {
        var next = settings
        next.mute(kind)
        settings = next
        save()
        if kind == .watchedFile { stopFolderWatch() }
        apply(.dismiss(surface: .island), to: matter)
    }

    private func apply(_ action: PersonAction, to matter: ProactiveMatter) {
        clear(matter)
        Task { [weak self] in
            guard let self, let store = await self.ensureMatterStore() else { return }
            do { _ = try await store.apply(action, to: matter.id) }
            catch { DiagnosticsLog.shared.event("proaktiv-aktion-fehler", [:]) }
        }
    }

    private func clear(_ matter: ProactiveMatter) {
        if activeNudge?.id == matter.id { activeNudge = nil }
    }

    // MARK: Stores

    /// Opened off MainActor on first use while enabled, so a switched-off Pippa never touches SQLite and launch never stalls.
    private func ensureMatterStore() async -> ProactiveMatterStore? {
        if let matterStore { return matterStore }
        guard settings.enabled else { return nil }
        let base = PiSession.settingsDirectory
        let opened: ProactiveMatterStore? = await Task.detached(priority: .utility) {
            try? ProactiveMatterStore(baseDirectory: base)
        }.value
        if let opened {
            if matterStore == nil { matterStore = opened }
            return matterStore
        }
        DiagnosticsLog.shared.event("proaktiv-speicher-fehler", [:])
        return nil
    }

    private func ensureJobStore() async -> DurableJobStore? {
        if let jobStore { return jobStore }
        guard settings.enabled else { return nil }
        let base = PiSession.settingsDirectory
        let opened: DurableJobStore? = await Task.detached(priority: .utility) {
            try? DurableJobStore(baseDirectory: base)
        }.value
        if let opened {
            if jobStore == nil { jobStore = opened }
            return jobStore
        }
        DiagnosticsLog.shared.event("proaktiv-auftraege-fehler", [:])
        return nil
    }

    /// The language Pippa's UI runs in, for the brief and the file triage.
    private static var language: String {
        (Bundle.module.preferredLocalizations.first ?? "en").lowercased().hasPrefix("de") ? "de" : "en"
    }
}
