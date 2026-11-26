import AppKit
import Combine
import CryptoKit
import EventKit
import PippaCore

/// Calm, opt-in multi-routine proactivity engine (PippaCore/Proactivity + `RoutineAIRunner`).
///
/// Rules this type keeps:
/// - Off (the default): zero timers, zero folder watchers, zero EventKit observers, zero SQLite opens.
///   Only `settings.json` and non-prompting authorization statuses are read.
/// - Never opens the island by itself and never takes focus: a delivered island nudge only lights the menu bar dot.
/// - Desk-only routines never spend daily Island budget and never set `activeNudge`, while appearing in `openMatters`.
/// - Never asks for Calendar or Reminders access: reads and observes only what the person already allowed.
/// - Background local AI runs only for explicitly opt-in `.localAIReadOnly` routines, strictly local and read-only,
///   serialized, and deferred while chat is answering.
@MainActor
final class ProactivityCoordinator: ObservableObject {
    static let shared = ProactivityCoordinator()

    /// Fallback sweep interval (besides exact single-shot routine timers, wake, day/clock change, folder and EventKit observers).
    static let tickInterval: TimeInterval = 15 * 60
    /// Folder events come in bursts (a download writes several times): wait this long after the last one.
    static let folderDebounce: Duration = .seconds(2)
    /// EventKit change notifications arrive in bursts when syncing: wait this long before running reactive watchers.
    static let eventStoreDebounce: Duration = .seconds(3)
    /// Hours the Morning Brief may be set to in Settings.
    static let morningBriefHours = 6...11
    /// Maximum recent runs published to the transparent Activity drawer.
    static let recentRunsLimit = 30

    // MARK: Published State (existing + Package 3 UI)

    @Published private(set) var settings: ProactivitySettings
    /// The one nudge waiting in the island. Set only after `ProactivityGate` and `recordDelivery` allowed it.
    @Published private(set) var activeNudge: ProactiveMatter?
    /// Result of "Preview now" in Settings, or why there is nothing to show.
    @Published private(set) var previewText: String?
    @Published private(set) var isPreviewing = false
    @Published private(set) var focusAuthorization = FocusAuthorizationState.notDetermined

    /// Active `.open` and `.offered` matters for the "For You" Desk, newest first.
    @Published private(set) var openMatters: [ProactiveMatter] = []
    /// Currently snoozed matters (`snoozedUntil > now`), soonest first.
    @Published private(set) var snoozedMatters: [ProactiveMatter] = []
    /// All persisted routines from `ProactiveRoutineStore`.
    @Published private(set) var routines: [ProactiveRoutine] = []
    /// Newest 30 routine runs for the transparent Activity drawer.
    @Published private(set) var recentRuns: [RoutineRunRecord] = []
    /// Routines currently executing (for live `SpinRing` feedback).
    @Published private(set) var runningRoutineIDs: Set<UUID> = []
    /// How many Island nudges were delivered today against `settings.dailyCap`.
    @Published private(set) var deliveredTodayCount: Int = 0
    /// Live macOS Focus active state from the most recent check.
    @Published private(set) var isFocusActiveNow: Bool = false
    /// Hermes live pulse summarizing the earliest upcoming routine or meeting prep.
    @Published private(set) var nextScheduledSummary: String?
    /// Permission-aware starter packs not yet enabled.
    @Published private(set) var suggestedTemplates: [ProactiveRoutineTemplate] = []
    /// Set `true` by `openDesk()`, consumed by `ChatView` to switch to the "For You" Desk.
    @Published var openDeskRequested: Bool = false
    /// Incremented whenever any flow explicitly opens the chat (⌘N, Open in Chat, Island, file drop) so `ChatView` leaves "For You".
    @Published private(set) var openChatToken: UInt64 = 0
    /// True when saved routines exist on disk (checked via file presence without opening SQLite while OFF) so Pause can Resume.
    @Published private(set) var hasSavedRoutines: Bool = false

    // MARK: Private State

    private final class FolderWatcherState {
        let routineID: UUID
        let path: String
        let bookmark: Data?
        var source: DispatchSourceFileSystemObject?
        var resolvedURL: URL?
        var setupTask: Task<Void, Never>?
        var debounceTask: Task<Void, Never>?
        var scanTask: Task<Void, Never>?
        var needsRescan = false
        var generation: UInt64 = 0

        init(routineID: UUID, path: String, bookmark: Data?) {
            self.routineID = routineID
            self.path = path
            self.bookmark = bookmark
        }

        func stop() {
            generation &+= 1
            setupTask?.cancel()
            setupTask = nil
            debounceTask?.cancel()
            debounceTask = nil
            scanTask?.cancel()
            scanTask = nil
            needsRescan = false
            source?.cancel()
            source = nil
            resolvedURL = nil
        }
    }

    private var matterStore: ProactiveMatterStore?
    private var routineStore: ProactiveRoutineStore?
    private var jobStore: DurableJobStore?

    private var timer: Timer?
    private var nextRoutineTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var dayChangeObserver: NSObjectProtocol?
    private var clockChangeObserver: NSObjectProtocol?
    private var eventStore: EKEventStore?
    private var eventStoreObserver: NSObjectProtocol?
    private var eventStoreDebounceTask: Task<Void, Never>?

    private var folderWatchers: [UUID: FolderWatcherState] = [:]
    private var tickTask: Task<Void, Never>?
    private var tickGeneration: UInt64 = 0
    private var needsAnotherTick = false
    private var reactiveTask: Task<Void, Never>?
    private var backgroundTasks: [UUID: Task<Void, Never>] = [:]

    private var isWatching = false
    private var isSnapshotMode = false
    private var hasSeededRoutines = false
    private var seedingTask: Task<Void, Never>?
    private var nextUpcomingMeetingLead: (date: Date, title: String)?
    private let focusReader = SystemFocusStatusReader()

    private init() {
        settings = PippaSettings.load(from: PiSession.settingsDirectory).effectiveProactivity
        hasSavedRoutines = Self.routinesDatabaseExists()
        suggestedTemplates = computeSuggestedTemplates()
    }

    // MARK: Lifecycle

    /// At launch: starts watching only when the person switched calm notices on.
    func start() {
        guard settings.enabled, !isSnapshotMode else { return }
        refreshFocusAuthorization()
        startWatching()
    }

    /// Re-reads Focus authorization state (for Settings on appear or app activation).
    func refreshFocusAuthorization() {
        focusAuthorization = SystemFocusStatusReader.currentAuthorizationState()
        isFocusActiveNow = focusReader.currentStatus().isFocusActive
        if !isSnapshotMode {
            suggestedTemplates = computeSuggestedTemplates()
        }
    }

    /// Cleanly stops all timers, observers, watchers, background tasks, and any in-flight local AI routine on quit.
    func shutdown() async {
        stopWatching()
        let tasks = Array(backgroundTasks.values)
        backgroundTasks.removeAll()
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        await RoutineAIRunner.shared.shutdown()
    }

    /// Deterministic snapshot configuration with zero SQLite, watcher, or disk side effects.
    func configureForSnapshot(
        enabled: Bool,
        activeNudge: ProactiveMatter? = nil,
        openMatters: [ProactiveMatter] = [],
        snoozedMatters: [ProactiveMatter] = [],
        routines: [ProactiveRoutine] = [],
        recentRuns: [RoutineRunRecord] = [],
        deliveredTodayCount: Int = 0,
        isFocusActiveNow: Bool = false,
        nextScheduledSummary: String? = nil,
        suggestedTemplates: [ProactiveRoutineTemplate]? = nil,
        hasSavedRoutines: Bool = false
    ) {
        isSnapshotMode = true
        stopWatching()
        var snapshotSettings = settings
        snapshotSettings.enabled = enabled
        settings = snapshotSettings
        self.activeNudge = activeNudge
        self.openMatters = openMatters
        self.snoozedMatters = snoozedMatters
        self.routines = routines
        self.recentRuns = recentRuns
        self.runningRoutineIDs = []
        self.deliveredTodayCount = deliveredTodayCount
        self.isFocusActiveNow = isFocusActiveNow
        self.nextScheduledSummary = nextScheduledSummary
        self.suggestedTemplates = suggestedTemplates ?? computeSuggestedTemplates()
        self.hasSavedRoutines = hasSavedRoutines || !routines.isEmpty
    }

    // MARK: Navigation

    /// Closes the island, reveals the main chat window, and asks `ChatView` to open the "For You" Desk.
    func openDesk() {
        Island.shared.close()
        ChatWindow.shared.show()
        openDeskRequested = true
    }

    /// Signals `ChatView` to leave "For You" and show the chat (e.g. ⌘N, Open in Chat, Island, file drop).
    func dismissDesk() {
        openDeskRequested = false
        openChatToken &+= 1
    }

    // MARK: Settings (backward compatible + new controls)

    func setEnabled(_ on: Bool) {
        guard settings.enabled != on else { return }
        update { $0.enabled = on }
        if on {
            focusAuthorization = SystemFocusStatusReader.currentAuthorizationState()
            isFocusActiveNow = focusReader.currentStatus().isFocusActive
            if focusAuthorization == .notDetermined {
                // Asked here only: the person just switched this on in Settings.
                Task { [weak self] in
                    let state = await SystemFocusStatusReader.requestAuthorizationIfNeeded()
                    self?.focusAuthorization = state
                    self?.isFocusActiveNow = self?.focusReader.currentStatus().isFocusActive ?? false
                }
            }
        }
    }

    func setMorningBrief(enabled: Bool) {
        update { $0.morningBriefEnabled = enabled }
        syncMorningBriefRoutineFromSettings()
    }

    func setMorningBrief(hour: Int) {
        let clamped = min(max(hour, Self.morningBriefHours.lowerBound), Self.morningBriefHours.upperBound)
        update { $0.morningBriefHour = clamped; $0.morningBriefMinute = 0 }
        syncMorningBriefRoutineFromSettings()
    }

    func setDailyCap(_ cap: Int) {
        update { $0.dailyCap = ProactivitySettings.clampDailyCap(cap) }
    }

    func setQuietHours(enabled: Bool) {
        update { $0.quietHoursEnabled = enabled }
    }

    func setQuietHours(enabled: Bool, startHour: Int, endHour: Int) {
        update {
            $0.quietHoursEnabled = enabled
            $0.quietStartHour = startHour
            $0.quietEndHour = endHour
        }
    }

    func resetMuted() { update { $0.mutedKinds = [] } }

    /// Reusable `NSOpenPanel` folder picker returning path and optional security-scoped bookmark.
    func chooseFolderForRoutine() -> (path: String, bookmark: Data?)? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = T("Watch Folder", table: "Settings")
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let bookmark = (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        return (url.path, bookmark)
    }

    /// "Choose…": the person picks the folder in the open panel, which also grants Pippa access to it.
    func chooseFolder() {
        guard let picked = chooseFolderForRoutine() else { return }
        update { $0.watchedFolderPath = picked.path; $0.watchedFolderBookmark = picked.bookmark }
        syncWatchedFolderRoutineFromSettings(path: picked.path, bookmark: picked.bookmark)
    }

    func removeFolder() {
        update { $0.watchedFolderPath = nil; $0.watchedFolderBookmark = nil }
        syncWatchedFolderRoutineFromSettings(path: nil, bookmark: nil)
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
            || (previous.quietStartHour != next.quietStartHour)
            || (previous.quietEndHour != next.quietEndHour)
            || (next.dailyCap > previous.dailyCap)
        settings = next
        if !isSnapshotMode { save() }
        if !next.enabled {
            stopWatching()
            let tasks = Array(backgroundTasks.values)
            backgroundTasks.removeAll()
            for task in tasks { task.cancel() }
            Task { await RoutineAIRunner.shared.cancelActive() }
            matterStore = nil
            routineStore = nil
            jobStore = nil
            hasSeededRoutines = false
            activeNudge = nil
            previewText = nil
            openMatters = []
            snoozedMatters = []
            routines = []
            recentRuns = []
            runningRoutineIDs = []
            deliveredTodayCount = 0
            isFocusActiveNow = false
            nextScheduledSummary = nil
            nextUpcomingMeetingLead = nil
            hasSavedRoutines = Self.routinesDatabaseExists()
            suggestedTemplates = computeSuggestedTemplates()
            return
        }
        if !isWatching && !isSnapshotMode {
            startWatching()
        } else if !isSnapshotMode {
            if folderChanged || watchedFileUnmuted || next.isMuted(.watchedFile) != previous.isMuted(.watchedFile) {
                syncFolderWatchers()
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
        guard !isSnapshotMode else { return }
        var file = PippaSettings.load(from: PiSession.settingsDirectory)
        file.proactivity = settings
        do { try file.save(to: PiSession.settingsDirectory) }
        catch { DiagnosticsLog.shared.event("proaktiv-speichern-fehler", [:]) }
    }

    // MARK: Routine CRUD & Starter Packs

    /// Activates one of Pippa's built-in starter packs, opting into proactivity if currently off.
    func activateStarterPack(_ template: ProactiveRoutineTemplate) {
        guard !isSnapshotMode else { return }
        var pickedFolder: (path: String, bookmark: Data?)?
        if template == .folderWatch {
            let existingPath = routines.first(where: { $0.template == .folderWatch })?.folderPath
                ?? settings.watchedFolderPath
            if existingPath == nil || existingPath?.isEmpty == true {
                guard let picked = chooseFolderForRoutine() else { return }
                pickedFolder = picked
            }
        }
        if !settings.enabled {
            setEnabled(true)
        }
        if let pickedFolder {
            settings.watchedFolderPath = pickedFolder.path
            settings.watchedFolderBookmark = pickedFolder.bookmark
            save()
        }
        trackTask { [weak self] in
            guard let self, let store = await self.ensureRoutineStore() else { return }
            await self.seedRoutinesIfNeeded(store: store)
            let now = Date()
            let targetKey = Self.builtInKey(for: template)
            var routine: ProactiveRoutine
            if let key = targetKey, let existing = try? await store.routine(builtInKey: key) {
                routine = existing
            } else if template == .folderWatch {
                let path = pickedFolder?.path ?? self.settings.watchedFolderPath ?? ""
                let bookmark = pickedFolder?.bookmark ?? self.settings.watchedFolderBookmark
                routine = ProactiveRoutine.watchedFolder(path: path, bookmark: bookmark, language: Self.language, enabled: true, now: now)
            } else if let starter = ProactiveRoutine.starterPacks(language: Self.language, now: now).first(where: { $0.template == template }) {
                routine = starter
            } else {
                return
            }

            if template == .folderWatch, let pickedFolder {
                routine.trigger = .folder(path: pickedFolder.path, bookmark: pickedFolder.bookmark)
            }
            routine.enabled = true
            routine.updatedAt = now
            if case .schedule(let schedule) = routine.trigger {
                routine.nextRunAt = ProactiveScheduleCalculator.nextFireDate(for: schedule, after: now)
            } else {
                routine.nextRunAt = nil
            }
            do {
                try await store.upsert(routine)
            } catch {
                DiagnosticsLog.shared.event("proaktiv-routine-fehler", [:])
                return
            }
            let allAfterActivate = (try? await store.allRoutines()) ?? []
            self.syncLegacySettings(from: routine, allRoutines: allAfterActivate)
            await self.refreshPublishedState()
            self.syncWatchersAndTimers()

            // Run an immediate check for reactive packs, or tick for scheduled packs.
            switch routine.trigger {
            case .calendarChange, .upcomingMeeting, .reminderDue:
                await self.runReactiveRoutine(routine, triggerTag: "activate", now: Date())
            case .folder:
                // Folder watcher already schedules an immediate scan on attach.
                self.tick()
            case .schedule:
                self.tick()
            }
        }
    }

    /// Creates and persists a new routine, enabling proactivity if currently off.
    func createRoutine(_ routine: ProactiveRoutine) {
        guard !isSnapshotMode else {
            routines.append(routine)
            suggestedTemplates = computeSuggestedTemplates()
            return
        }
        if !settings.enabled {
            setEnabled(true)
        }
        var prepared = routine
        let now = Date()
        prepared.updatedAt = now
        if prepared.enabled, case .schedule(let schedule) = prepared.trigger {
            prepared.nextRunAt = ProactiveScheduleCalculator.nextFireDate(for: schedule, after: now)
        } else {
            prepared.nextRunAt = nil
        }

        trackTask { [weak self] in
            guard let self, let store = await self.ensureRoutineStore() else { return }
            await self.seedRoutinesIfNeeded(store: store)
            do {
                try await store.upsert(prepared)
            } catch {
                DiagnosticsLog.shared.event("proaktiv-routine-fehler", [:])
                return
            }
            let allAfterCreate = (try? await store.allRoutines()) ?? []
            self.syncLegacySettings(from: prepared, allRoutines: allAfterCreate)
            await self.refreshPublishedState()
            self.syncWatchersAndTimers()
            if prepared.enabled {
                switch prepared.trigger {
                case .calendarChange, .upcomingMeeting, .reminderDue:
                    await self.runReactiveRoutine(prepared, triggerTag: "create", now: Date())
                case .folder, .schedule:
                    self.tick()
                }
            }
        }
    }

    /// Parses natural language into a `ProactiveRoutine` and saves it (`.customCheck`/`.followUp` default to `.prepareForChat`).
    @discardableResult
    func createRoutineFromText(_ text: String) -> ProactiveRoutine? {
        let now = Date()
        guard let draft = RoutineNaturalLanguageParser.parse(text, now: now, language: Self.language) else {
            return nil
        }
        var trigger = draft.trigger
        if case .folder(let path, _) = trigger, path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let picked = chooseFolderForRoutine() else { return nil }
            trigger = .folder(path: picked.path, bookmark: picked.bookmark)
        }
        let executionMode: RoutineExecutionMode
        switch draft.template {
        case .morningBrief, .eveningPreview, .weeklyReview, .folderWatch, .calendarRadar, .meetingPrep, .reminderRadar:
            executionMode = .deterministic
        case .followUp, .customCheck:
            executionMode = .prepareForChat
        }
        let deliveryMode: RoutineDeliveryMode
        switch draft.template {
        case .calendarRadar, .meetingPrep, .reminderRadar:
            deliveryMode = .deskOnly
        default:
            deliveryMode = .islandAndDesk
        }
        let nextRun: Date?
        if case .schedule(let schedule) = trigger {
            nextRun = ProactiveScheduleCalculator.nextFireDate(for: schedule, after: now)
        } else {
            nextRun = nil
        }
        let routine = ProactiveRoutine(
            title: draft.title,
            instruction: draft.instruction,
            template: draft.template,
            trigger: trigger,
            executionMode: executionMode,
            deliveryMode: deliveryMode,
            enabled: true,
            onlyWhenNew: true,
            nextRunAt: nextRun,
            createdAt: now,
            updatedAt: now
        )
        createRoutine(routine)
        return routine
    }

    /// Updates an existing routine, recomputes its schedule, and syncs watchers/timers and legacy settings.
    func updateRoutine(_ routine: ProactiveRoutine) {
        var updated = routine
        let now = Date()
        updated.updatedAt = now
        if updated.enabled, case .schedule(let schedule) = updated.trigger {
            updated.nextRunAt = ProactiveScheduleCalculator.nextFireDate(for: schedule, after: now)
        } else {
            updated.nextRunAt = nil
        }
        if isSnapshotMode {
            if let idx = routines.firstIndex(where: { $0.id == updated.id }) { routines[idx] = updated }
            suggestedTemplates = computeSuggestedTemplates()
            return
        }
        trackTask { [weak self] in
            guard let self, let store = await self.ensureRoutineStore() else { return }
            let previous = (try? await store.routine(id: updated.id)) ?? nil
            if previous?.trigger != updated.trigger {
                updated.lastSlotKey = nil
            }
            do {
                try await store.upsert(updated)
            } catch {
                DiagnosticsLog.shared.event("proaktiv-routine-fehler", [:])
                return
            }
            let allAfterUpdate = (try? await store.allRoutines()) ?? []
            self.syncLegacySettings(from: updated, allRoutines: allAfterUpdate)
            if !updated.enabled, let nudge = self.activeNudge, self.resolveOwner(for: nudge, in: [updated]) != nil {
                self.activeNudge = nil
            }
            if updated.deliveryMode == .deskOnly, let nudge = self.activeNudge, self.resolveOwner(for: nudge, in: [updated]) != nil {
                self.activeNudge = nil
            }
            await self.refreshPublishedState()
            self.syncWatchersAndTimers()
        }
    }

    /// Enables or disables a single routine by ID.
    func toggleRoutine(_ id: UUID, enabled: Bool) {
        if isSnapshotMode {
            if let idx = routines.firstIndex(where: { $0.id == id }) { routines[idx].enabled = enabled }
            suggestedTemplates = computeSuggestedTemplates()
            return
        }
        trackTask { [weak self] in
            guard let self, let store = await self.ensureRoutineStore() else { return }
            let now = Date()
            do {
                var toggled = try await store.setEnabled(id: id, enabled: enabled, now: now)
                if toggled.enabled, case .schedule(let schedule) = toggled.trigger {
                    toggled.nextRunAt = ProactiveScheduleCalculator.nextFireDate(for: schedule, after: now)
                    try await store.upsert(toggled)
                } else if !toggled.enabled && toggled.nextRunAt != nil {
                    toggled.nextRunAt = nil
                    try await store.upsert(toggled)
                }
                let allAfterToggle = (try? await store.allRoutines()) ?? []
                self.syncLegacySettings(from: toggled, allRoutines: allAfterToggle)
                if !enabled, let nudge = self.activeNudge, self.resolveOwner(for: nudge, in: [toggled]) != nil {
                    self.activeNudge = nil
                }
            } catch {
                DiagnosticsLog.shared.event("proaktiv-routine-fehler", [:])
                return
            }
            await self.refreshPublishedState()
            self.syncWatchersAndTimers()
            if enabled { self.tick() }
        }
    }

    /// Deletes a routine by ID, stopping any watcher and clearing legacy folder settings if built-in watched folder.
    func deleteRoutine(_ id: UUID) {
        if isSnapshotMode {
            routines.removeAll { $0.id == id }
            suggestedTemplates = computeSuggestedTemplates()
            return
        }
        stopFolderWatcher(for: id)
        let known = routines.first(where: { $0.id == id })
        trackTask { [weak self] in
            guard let self, let store = await self.ensureRoutineStore() else { return }
            let existing: ProactiveRoutine?
            if let known {
                existing = known
            } else {
                existing = (try? await store.routine(id: id)) ?? nil
            }
            do {
                try await store.delete(id: id)
            } catch {
                DiagnosticsLog.shared.event("proaktiv-routine-fehler", [:])
                return
            }
            if let existing {
                let allAfterDelete = (try? await store.allRoutines()) ?? []
                self.syncLegacySettings(from: existing, deleted: true, allRoutines: allAfterDelete)
            }
            await self.refreshPublishedState()
            self.syncWatchersAndTimers()
        }
    }

    /// Runs a single routine immediately on demand with a manual slot key.
    func runRoutineNow(_ id: UUID) {
        guard settings.enabled, !isSnapshotMode, !runningRoutineIDs.contains(id) else { return }
        trackTask { [weak self] in
            guard let self,
                  let matterStore = await self.ensureMatterStore(),
                  let routineStore = await self.ensureRoutineStore()
            else { return }
            await self.seedRoutinesIfNeeded(store: routineStore)
            guard let routine = (try? await routineStore.routine(id: id)) ?? self.routines.first(where: { $0.id == id }) else { return }
            let now = Date()
            let slotKey = "manual-\(Int64(now.timeIntervalSince1970))"
            await self.executeRoutine(
                routine,
                slotKey: slotKey,
                nextFireDate: routine.nextRunAt,
                disableAfterFire: false,
                manual: true,
                matterStore: matterStore,
                routineStore: routineStore,
                now: now
            )
            await self.refreshPublishedState()
            self.syncWatchersAndTimers()
            await self.evaluateIslandDelivery(matterStore: matterStore, now: Date())
        }
    }

    // MARK: Legacy Settings Bidirectional Sync

    private func syncMorningBriefRoutineFromSettings() {
        guard settings.enabled, !isSnapshotMode else { return }
        let enabled = settings.morningBriefEnabled
        let hour = settings.morningBriefHour
        let minute = settings.morningBriefMinute
        trackTask { [weak self] in
            guard let self, let store = await self.ensureRoutineStore() else { return }
            await self.seedRoutinesIfNeeded(store: store)
            guard var routine = try? await store.routine(builtInKey: ProactiveRoutine.morningBriefKey) else { return }
            let now = Date()
            let schedule = ProactiveSchedule.daily(hour: hour, minute: minute)
            routine.enabled = enabled
            routine.trigger = .schedule(schedule)
            routine.nextRunAt = enabled ? ProactiveScheduleCalculator.nextFireDate(for: schedule, after: now) : nil
            routine.updatedAt = now
            try? await store.upsert(routine)
            await self.refreshPublishedState()
            self.syncWatchersAndTimers()
        }
    }

    private func syncWatchedFolderRoutineFromSettings(path: String?, bookmark: Data?) {
        guard settings.enabled, !isSnapshotMode else { return }
        trackTask { [weak self] in
            guard let self, let store = await self.ensureRoutineStore() else { return }
            await self.seedRoutinesIfNeeded(store: store)
            let now = Date()
            if let path, !path.isEmpty {
                var routine = (try? await store.routine(builtInKey: ProactiveRoutine.watchedFolderKey))
                    ?? ProactiveRoutine.watchedFolder(path: path, bookmark: bookmark, language: Self.language, enabled: true, now: now)
                routine.trigger = .folder(path: path, bookmark: bookmark)
                routine.enabled = true
                routine.updatedAt = now
                try? await store.upsert(routine)
            } else if let existing = try? await store.routine(builtInKey: ProactiveRoutine.watchedFolderKey) {
                self.stopFolderWatcher(for: existing.id)
                try? await store.delete(id: existing.id)
            }
            await self.refreshPublishedState()
            self.syncWatchersAndTimers()
        }
    }

    private func syncLegacySettings(from routine: ProactiveRoutine, deleted: Bool = false, allRoutines: [ProactiveRoutine]? = nil) {
        var next = settings
        if routine.template == .morningBrief {
            if let allRoutines {
                next.morningBriefEnabled = allRoutines.contains { $0.template == .morningBrief && $0.enabled }
            } else {
                next.morningBriefEnabled = !deleted && routine.enabled
            }
            if routine.builtInKey == ProactiveRoutine.morningBriefKey && !deleted {
                if case .schedule(let schedule) = routine.trigger {
                    switch schedule {
                    case .daily(let h, let m), .weekdays(let h, let m), .weekly(_, let h, let m):
                        next.morningBriefHour = h
                        next.morningBriefMinute = m
                    default:
                        break
                    }
                }
            }
        } else if routine.builtInKey == ProactiveRoutine.watchedFolderKey {
            if deleted {
                next.watchedFolderPath = nil
                next.watchedFolderBookmark = nil
            } else if case .folder(let path, let bookmark) = routine.trigger {
                next.watchedFolderPath = path.isEmpty ? nil : path
                next.watchedFolderBookmark = path.isEmpty ? nil : bookmark
            }
        }
        guard next != settings else { return }
        settings = next
        save()
    }

    // MARK: Watching, Timers & Observers

    private func startWatching() {
        guard settings.enabled, !isWatching, !isSnapshotMode else { return }
        isWatching = true
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { ProactivityCoordinator.shared.tick() }
        }
        dayChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { ProactivityCoordinator.shared.tick() }
        }
        clockChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { ProactivityCoordinator.shared.handleClockChange() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { _ in
            MainActor.assumeIsolated { ProactivityCoordinator.shared.tick() }
        }
        timer?.tolerance = 60
        syncFolderWatchers()
        tick()
    }

    private func stopWatching() {
        isWatching = false
        timer?.invalidate()
        timer = nil
        nextRoutineTimer?.invalidate()
        nextRoutineTimer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        if let dayChangeObserver { NotificationCenter.default.removeObserver(dayChangeObserver) }
        dayChangeObserver = nil
        if let clockChangeObserver { NotificationCenter.default.removeObserver(clockChangeObserver) }
        clockChangeObserver = nil
        stopEventStoreObserver()
        stopAllFolderWatchers()
        tickGeneration &+= 1
        tickTask?.cancel()
        tickTask = nil
        needsAnotherTick = false
        reactiveTask?.cancel()
        reactiveTask = nil
        seedingTask?.cancel()
        seedingTask = nil
    }

    private func handleClockChange() {
        guard settings.enabled, isWatching, !isSnapshotMode else { return }
        trackTask { [weak self] in
            guard let self, let store = await self.ensureRoutineStore() else { return }
            let now = Date()
            let all = (try? await store.allRoutines()) ?? []
            for var routine in all where routine.enabled {
                if case .schedule(let schedule) = routine.trigger {
                    let recomputed = ProactiveScheduleCalculator.nextFireDate(for: schedule, after: now)
                    if routine.nextRunAt != recomputed {
                        routine.nextRunAt = recomputed
                        routine.updatedAt = now
                        try? await store.upsert(routine)
                    }
                }
            }
            await self.refreshPublishedState()
            self.syncWatchersAndTimers()
            self.tick()
        }
    }

    private func syncWatchersAndTimers() {
        guard settings.enabled, isWatching, !isSnapshotMode else { return }
        syncFolderWatchers()
        syncEventStoreObserver()
        scheduleNextRoutineTimer()
        nextScheduledSummary = computeNextScheduledSummary(now: Date())
    }

    private func scheduleNextRoutineTimer() {
        nextRoutineTimer?.invalidate()
        nextRoutineTimer = nil
        guard settings.enabled, isWatching, !isSnapshotMode else { return }
        let now = Date()
        var candidates: [Date] = []
        for routine in routines where routine.enabled {
            if case .schedule(let schedule) = routine.trigger {
                if let next = routine.nextRunAt, next > now {
                    candidates.append(next)
                } else if let next = ProactiveScheduleCalculator.nextFireDate(for: schedule, after: now) {
                    candidates.append(next)
                }
            }
        }
        if let meetingLead = nextUpcomingMeetingLead, meetingLead.date > now {
            candidates.append(meetingLead.date)
        }
        for matter in snoozedMatters {
            if let until = matter.snoozedUntil, until > now {
                candidates.append(until)
            }
        }
        guard let earliest = candidates.min() else { return }
        let delay = max(5.0, earliest.timeIntervalSince(now))
        let scheduled = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { ProactivityCoordinator.shared.tick() }
        }
        scheduled.tolerance = min(15.0, max(1.0, delay * 0.05))
        nextRoutineTimer = scheduled
    }

    // MARK: Multi-Folder Watchers

    private func syncFolderWatchers() {
        guard settings.enabled, isWatching, !isSnapshotMode, !settings.isMuted(.watchedFile) else {
            stopAllFolderWatchers()
            return
        }
        var desired: [UUID: (path: String, bookmark: Data?)] = [:]
        var hasBuiltInFolder = false
        for routine in routines {
            if routine.builtInKey == ProactiveRoutine.watchedFolderKey {
                hasBuiltInFolder = true
            }
            guard routine.enabled, case .folder(let path, let bookmark) = routine.trigger, !path.isEmpty else { continue }
            desired[routine.id] = (path, bookmark)
        }
        // Fallback before starter packs have been seeded: preserve legacy watched folder without duplicating built-in.
        if !hasBuiltInFolder, let legacyPath = settings.watchedFolderPath, !legacyPath.isEmpty {
            let builtInID = ProactiveRoutine.builtInID(for: ProactiveRoutine.watchedFolderKey)
            let alreadyWatchedPath = desired.values.contains { $0.path == legacyPath }
            if !alreadyWatchedPath {
                desired[builtInID] = (legacyPath, settings.watchedFolderBookmark)
            }
        }

        for (id, existing) in folderWatchers {
            guard let target = desired[id], target.path == existing.path, target.bookmark == existing.bookmark else {
                existing.stop()
                folderWatchers.removeValue(forKey: id)
                continue
            }
        }
        for (id, target) in desired where folderWatchers[id] == nil {
            startFolderWatcher(routineID: id, path: target.path, bookmark: target.bookmark)
        }
    }

    private func startFolderWatcher(routineID: UUID, path: String, bookmark: Data?) {
        stopFolderWatcher(for: routineID)
        guard settings.enabled, isWatching, !isSnapshotMode, !settings.isMuted(.watchedFile) else { return }
        let state = FolderWatcherState(routineID: routineID, path: path, bookmark: bookmark)
        folderWatchers[routineID] = state
        state.generation &+= 1
        let gen = state.generation
        state.setupTask = Task { [weak self] in
            // Resolve bookmark off MainActor with `.withoutMounting` so offline network/external volumes never block launch.
            let resolved: URL? = await Task.detached(priority: .utility) {
                Self.resolveFolderOffMain(bookmark: bookmark, fallbackPath: path)
            }.value
            guard !Task.isCancelled, let self,
                  let current = self.folderWatchers[routineID], current === state, current.generation == gen
            else { return }
            guard self.settings.enabled, !self.settings.isMuted(.watchedFile), let url = resolved else {
                self.folderWatchers.removeValue(forKey: routineID)
                return
            }
            self.attachFolderSource(url: url, state: current)
        }
    }

    private func attachFolderSource(url: URL, state: FolderWatcherState) {
        let accessed = url.startAccessingSecurityScopedResource()
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            if accessed { url.stopAccessingSecurityScopedResource() }
            if folderWatchers[state.routineID] === state {
                folderWatchers.removeValue(forKey: state.routineID)
            }
            DiagnosticsLog.shared.event("proaktiv-ordner-fehler", [:])
            return
        }
        let routineID = state.routineID
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .main
        )
        source.setEventHandler { [weak source] in
            let flags = source?.data ?? []
            MainActor.assumeIsolated {
                let coordinator = ProactivityCoordinator.shared
                guard let current = coordinator.folderWatchers[routineID], current === state else { return }
                if flags.contains(.delete) || flags.contains(.rename) {
                    coordinator.startFolderWatcher(routineID: routineID, path: current.path, bookmark: current.bookmark)
                } else {
                    coordinator.scheduleFolderScan(for: routineID, after: Self.folderDebounce)
                }
            }
        }
        source.setCancelHandler {
            close(descriptor)
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        source.resume()
        state.source = source
        state.resolvedURL = url
        // Scan files that arrived while Pippa was not running.
        scheduleFolderScan(for: routineID, after: .zero)
    }

    private func stopFolderWatcher(for routineID: UUID) {
        folderWatchers.removeValue(forKey: routineID)?.stop()
    }

    private func stopAllFolderWatchers() {
        for watcher in folderWatchers.values { watcher.stop() }
        folderWatchers.removeAll()
    }

    private func scheduleFolderScan(for routineID: UUID, after delay: Duration) {
        guard let state = folderWatchers[routineID] else { return }
        state.debounceTask?.cancel()
        state.debounceTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            self.scanFolder(for: routineID)
        }
    }

    private func scanFolder(for routineID: UUID) {
        guard settings.enabled, !isSnapshotMode, !settings.isMuted(.watchedFile),
              let state = folderWatchers[routineID], let folder = state.resolvedURL
        else { return }
        if state.scanTask != nil {
            state.needsRescan = true
            return
        }
        state.needsRescan = false
        state.generation &+= 1
        let gen = state.generation
        let lang = Self.language
        state.scanTask = Task { [weak self] in
            guard let self else { return }
            guard let matterStore = await self.ensureMatterStore() else {
                if self.folderWatchers[routineID]?.generation == gen { self.folderWatchers[routineID]?.scanTask = nil }
                return
            }
            let startedAt = Date()
            self.runningRoutineIDs.insert(routineID)
            defer { self.runningRoutineIDs.remove(routineID) }

            let scanner = WatchedFolderScanner(store: matterStore, language: lang)
            var scanReport: WatchedFolderScanReport?
            var scanFailed = false
            do {
                let report = try await Task.detached(priority: .utility) {
                    try await scanner.scan(folderURL: folder)
                }.value
                scanReport = report
                if !Task.isCancelled {
                    DiagnosticsLog.shared.event("proaktiv-ordner", [
                        "dateien": String(report.scannedFiles),
                        "hinweise": String(report.actionableMatters.count),
                    ])
                }
            } catch {
                scanFailed = true
                if !Task.isCancelled {
                    DiagnosticsLog.shared.event("proaktiv-ordner-fehler", [:])
                }
            }

            if !Task.isCancelled, let routineStore = await self.ensureRoutineStore(),
               var routine = (try? await routineStore.routine(id: routineID)) ?? nil {
                let finishedAt = Date()
                if scanFailed {
                    let slotKey = "folder-err-\(Int64(startedAt.timeIntervalSince1970))-\(UUID().uuidString.prefix(4))"
                    let record = RoutineRunRecord(
                        routineID: routine.id,
                        routineTitle: routine.title,
                        slotKey: slotKey,
                        outcome: .failed,
                        startedAt: startedAt,
                        finishedAt: finishedAt
                    )
                    _ = try? await routineStore.recordRun(record)
                    routine.lastRunAt = finishedAt
                    routine.lastOutcome = .failed
                    routine.updatedAt = finishedAt
                    try? await routineStore.upsert(routine)
                } else if let report = scanReport, report.triagedFiles > 0 || !report.actionableMatters.isEmpty {
                    let outcome: RoutineRunOutcome = report.actionableMatters.isEmpty ? .silent : .prepared
                    let detail = report.actionableMatters.first?.title
                    let slotKey = "folder-\(Int64(startedAt.timeIntervalSince1970))-\(UUID().uuidString.prefix(6))"
                    let record = RoutineRunRecord(
                        routineID: routine.id,
                        routineTitle: routine.title,
                        slotKey: slotKey,
                        outcome: outcome,
                        matterID: report.actionableMatters.first?.id,
                        detail: detail,
                        startedAt: startedAt,
                        finishedAt: finishedAt
                    )
                    _ = try? await routineStore.recordRun(record)
                    routine.lastRunAt = finishedAt
                    routine.lastOutcome = outcome
                    if let detail { routine.lastSummary = detail }
                    routine.updatedAt = finishedAt
                    try? await routineStore.upsert(routine)
                }
            }

            guard let current = self.folderWatchers[routineID], current === state, current.generation == gen else { return }
            current.scanTask = nil
            await self.refreshPublishedState()
            if current.needsRescan {
                current.needsRescan = false
                self.scheduleFolderScan(for: routineID, after: Self.folderDebounce)
            } else {
                self.tick()
            }
        }
    }

    /// Resolves a watched folder from its security-scoped bookmark off MainActor without mounting offline volumes.
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
        guard let fallbackPath, !fallbackPath.isEmpty else { return nil }
        return URL(fileURLWithPath: fallbackPath, isDirectory: true)
    }

    // MARK: Reactive EventKit Observer

    private func syncEventStoreObserver() {
        guard settings.enabled, isWatching, !isSnapshotMode else {
            stopEventStoreObserver()
            return
        }
        let enabledRoutines = routines.filter(\.enabled)
        let wantsCalendar = enabledRoutines.contains {
            switch $0.trigger {
            case .calendarChange, .upcomingMeeting: return true
            default: return false
            }
        }
        let wantsReminders = enabledRoutines.contains {
            if case .reminderDue = $0.trigger { return true }
            return false
        }
        // NEVER request authorization here; only observe if access was already granted.
        let hasCalendar = wantsCalendar && EKEventStore.authorizationStatus(for: .event) == .fullAccess
        let hasReminders = wantsReminders && EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        guard hasCalendar || hasReminders else {
            stopEventStoreObserver()
            return
        }
        if eventStoreObserver != nil { return }
        let store = EKEventStore()
        eventStore = store
        eventStoreObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { ProactivityCoordinator.shared.scheduleReactiveCheck() }
        }
    }

    private func stopEventStoreObserver() {
        eventStoreDebounceTask?.cancel()
        eventStoreDebounceTask = nil
        if let eventStoreObserver { NotificationCenter.default.removeObserver(eventStoreObserver) }
        eventStoreObserver = nil
        eventStore = nil
    }

    private func scheduleReactiveCheck() {
        guard settings.enabled, isWatching, !isSnapshotMode else { return }
        eventStoreDebounceTask?.cancel()
        eventStoreDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.eventStoreDebounce)
            guard !Task.isCancelled, let self else { return }
            self.runReactivePass()
        }
    }

    private func runReactivePass() {
        guard settings.enabled, isWatching, !isSnapshotMode else { return }
        reactiveTask?.cancel()
        reactiveTask = Task { [weak self] in
            guard let self,
                  let matterStore = await self.ensureMatterStore(),
                  let routineStore = await self.ensureRoutineStore()
            else { return }
            let now = Date()
            let all = (try? await routineStore.allRoutines()) ?? self.routines
            self.nextUpcomingMeetingLead = nil
            for routine in all where routine.enabled {
                guard !Task.isCancelled, self.settings.enabled else { return }
                switch routine.trigger {
                case .calendarChange, .upcomingMeeting, .reminderDue:
                    await self.runReactiveRoutine(routine, triggerTag: "ek", now: now, matterStore: matterStore, routineStore: routineStore)
                case .schedule, .folder:
                    continue
                }
            }
            guard !Task.isCancelled, self.settings.enabled else { return }
            await self.refreshPublishedState()
            self.syncWatchersAndTimers()
            await self.evaluateIslandDelivery(matterStore: matterStore, now: Date())
        }
    }

    private func runReactiveRoutine(
        _ routine: ProactiveRoutine,
        triggerTag: String,
        now: Date,
        matterStore: ProactiveMatterStore? = nil,
        routineStore: ProactiveRoutineStore? = nil
    ) async {
        guard let mStore: ProactiveMatterStore = matterStore != nil ? matterStore : await ensureMatterStore(),
              let rStore: ProactiveRoutineStore = routineStore != nil ? routineStore : await ensureRoutineStore()
        else { return }
        let slotKey = "\(triggerTag)-\(Int64(now.timeIntervalSince1970))-\(UUID().uuidString.prefix(4))"
        await executeRoutine(
            routine,
            slotKey: slotKey,
            nextFireDate: nil,
            disableAfterFire: false,
            manual: false,
            matterStore: mStore,
            routineStore: rStore,
            now: now
        )
    }

    // MARK: Tick & Execution Engine

    /// Evaluates due scheduled routines, reactive watchers, published desk state, and at most one Island nudge.
    func tick() {
        guard settings.enabled, isWatching, !isSnapshotMode else { return }
        if tickTask != nil {
            needsAnotherTick = true
            return
        }
        needsAnotherTick = false
        tickGeneration &+= 1
        let gen = tickGeneration
        tickTask = Task { [weak self] in
            guard let self else { return }
            await self.runTick()
            guard self.tickGeneration == gen else { return }
            self.tickTask = nil
            if self.needsAnotherTick {
                self.needsAnotherTick = false
                self.tick()
            }
        }
    }

    private func runTick() async {
        guard let matterStore = await ensureMatterStore(),
              let routineStore = await ensureRoutineStore()
        else { return }
        await seedRoutinesIfNeeded(store: routineStore)
        let now = Date()
        let calendar = Calendar.autoupdatingCurrent
        isFocusActiveNow = focusReader.currentStatus().isFocusActive

        let allRoutines = (try? await routineStore.allRoutines()) ?? []
        nextUpcomingMeetingLead = nil

        // 1. Evaluate enabled scheduled routines and reactive meeting/calendar/reminder routines.
        for var routine in allRoutines {
            guard !Task.isCancelled, settings.enabled else { return }
            guard routine.enabled else { continue }
            switch routine.trigger {
            case .schedule(let schedule):
                if let due = evaluateDueSlot(for: routine, schedule: schedule, now: now, calendar: calendar) {
                    let alreadyRan = (try? await routineStore.hasRun(routineID: routine.id, slotKey: due.slotKey)) ?? false
                    if !alreadyRan {
                        await executeRoutine(
                            routine,
                            slotKey: due.slotKey,
                            nextFireDate: due.nextFireDate,
                            disableAfterFire: due.disableAfterFire,
                            manual: false,
                            matterStore: matterStore,
                            routineStore: routineStore,
                            now: now
                        )
                    } else if routine.nextRunAt != due.nextFireDate {
                        routine.nextRunAt = due.nextFireDate
                        routine.updatedAt = now
                        try? await routineStore.upsert(routine)
                    }
                } else {
                    let nextFire = ProactiveScheduleCalculator.nextFireDate(for: schedule, after: now, calendar: calendar)
                    if routine.nextRunAt != nextFire {
                        routine.nextRunAt = nextFire
                        routine.updatedAt = now
                        try? await routineStore.upsert(routine)
                    }
                }
            case .upcomingMeeting, .calendarChange, .reminderDue:
                await runReactiveRoutine(routine, triggerTag: "tick", now: now, matterStore: matterStore, routineStore: routineStore)
            case .folder:
                continue
            }
        }

        // 2. Refresh all published UI state, watchers, and exact next-routine timer.
        await refreshPublishedState()
        syncWatchersAndTimers()

        // 3. Evaluate Island delivery (only when no activeNudge is already waiting).
        await evaluateIslandDelivery(matterStore: matterStore, now: now)
    }

    private func evaluateDueSlot(
        for routine: ProactiveRoutine,
        schedule: ProactiveSchedule,
        now: Date,
        calendar: Calendar
    ) -> ProactiveScheduleCalculator.DueEvaluation? {
        if let due = ProactiveScheduleCalculator.evaluateDue(
            schedule: schedule,
            lastSlotKey: routine.lastSlotKey,
            lastRunAt: routine.lastRunAt,
            createdAt: routine.createdAt,
            now: now,
            calendar: calendar
        ) {
            return due
        }
        // Preserve legacy Morning Brief behavior: if enabled after today's morning hour, still prepare today's brief once.
        if routine.builtInKey == ProactiveRoutine.morningBriefKey,
           settings.morningBriefEnabled,
           morningBriefDue(now: now, calendar: calendar),
           let todayDue = calendar.date(bySettingHour: settings.morningBriefHour, minute: settings.morningBriefMinute, second: 0, of: now) {
            let slotKey = ProactiveScheduleCalculator.slotKey(for: todayDue, calendar: calendar)
            if routine.lastSlotKey != slotKey {
                let nextFire = ProactiveScheduleCalculator.nextFireDate(for: schedule, after: now, calendar: calendar)
                return ProactiveScheduleCalculator.DueEvaluation(
                    slotDate: todayDue,
                    slotKey: slotKey,
                    nextFireDate: nextFire,
                    disableAfterFire: false
                )
            }
        }
        return nil
    }

    private func evaluateIslandDelivery(matterStore: ProactiveMatterStore, now: Date) async {
        guard !Task.isCancelled, settings.enabled, activeNudge == nil else { return }
        let todayKey = ProactiveMatterStore.dayKey(for: now)

        // Restore a still-valid previously offered notice after app restart without re-spending daily budget.
        let offered = (try? await matterStore.matters(states: [.offered])) ?? []
        for matter in offered.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            guard !Task.isCancelled, settings.enabled, activeNudge == nil else { return }
            if settings.isMuted(matter.kind) { continue }
            if matter.kind == .morningBrief && (!settings.morningBriefEnabled || matter.matterKey != MorningBriefBuilder.matterKey(for: todayKey)) {
                continue
            }
            let owner = resolveOwner(for: matter, in: routines)
            if let owner, !owner.enabled || owner.deliveryMode == .deskOnly { continue }
            let fresh = (try? await matterStore.isFresh(matterID: matter.id, expectedSourceVersion: matter.sourceVersion)) ?? false
            if fresh {
                activeNudge = matter
                return
            }
        }

        let waiting = (try? await matterStore.matters(states: [.open, .snoozed])) ?? []
        let candidates = waiting
            .filter { $0.kind != .morningBrief || $0.matterKey == MorningBriefBuilder.matterKey(for: todayKey) }
            .filter { $0.state == .open || ($0.snoozedUntil.map { $0 <= now } ?? false) }
            .sorted { $0.createdAt < $1.createdAt }

        var seen = Set<UUID>()
        for matter in candidates where seen.insert(matter.id).inserted {
            guard !Task.isCancelled, settings.enabled, activeNudge == nil else { return }
            if await deliver(matter, store: matterStore, now: now) {
                await refreshPublishedState()
                return
            }
        }
    }

    /// Executes a single routine for `slotKey`, updates its metadata, and records a `RoutineRunRecord` unless deferred.
    private func executeRoutine(
        _ routine: ProactiveRoutine,
        slotKey: String,
        nextFireDate: Date?,
        disableAfterFire: Bool,
        manual: Bool,
        matterStore: ProactiveMatterStore,
        routineStore: ProactiveRoutineStore,
        now: Date
    ) async {
        guard !Task.isCancelled, settings.enabled else { return }
        // Skip muted kinds early on automatic runs so neither builders nor the local AI do wasted work.
        if !manual && settings.isMuted(routine.matterKind) { return }

        runningRoutineIDs.insert(routine.id)
        defer { runningRoutineIDs.remove(routine.id) }

        let startedAt = Date()
        let calendar = Calendar.autoupdatingCurrent
        let lang = Self.language

        var outcome: RoutineRunOutcome = .silent
        var preparedMatterID: UUID?
        var inputHash: String?
        var detail: String?
        var skipRecording = false
        var recordRunIfSilent = manual || !routine.isReactiveWatcher

        switch routine.template {
        case .morningBrief:
            if !manual && settings.isMuted(.morningBrief) {
                outcome = .skipped
                recordRunIfSilent = false
            } else if manual || routine.builtInKey == nil {
                // Bypass the once-per-day DurableJobStore short-circuit for manual runs and user-created
                // Morning Brief routines so newly added events surface and `sourceRef` carries the owning UUID.
                let input = await briefInput(day: now, store: matterStore)
                if let content = MorningBriefBuilder.format(input) {
                    let draft = ProactiveMatterDraft(
                        kind: .morningBrief,
                        matterKey: MorningBriefBuilder.matterKey(for: content.dayKey),
                        sourceRef: "routine:\(routine.id.uuidString)",
                        sourceVersion: content.sourceVersion,
                        title: content.title,
                        summary: content.summary,
                        preparedPrompt: content.preparedPrompt,
                        preparedFiles: []
                    )
                    inputHash = content.sourceVersion
                    if let matter = await upsertDraft(draft, into: matterStore, now: now) {
                        outcome = .prepared
                        preparedMatterID = matter.id
                        detail = matter.title
                    } else {
                        outcome = .silent
                    }
                } else {
                    outcome = .silent
                }
            } else if let matter = await buildBrief(day: now, store: matterStore) {
                outcome = .prepared
                preparedMatterID = matter.id
                inputHash = matter.sourceVersion
                detail = matter.title
            } else {
                outcome = .silent
            }

        case .eveningPreview:
            let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
            let dayAfter = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(2 * 86_400)
            let input = await digestInput(now: now, eventsIn: DateInterval(start: tomorrowStart, end: dayAfter),
                                          remindersDueBefore: dayAfter, store: matterStore)
            if let draft = EveningPreviewBuilder.draft(input) {
                inputHash = draft.sourceVersion
                if !manual && routine.onlyWhenNew && draft.sourceVersion == routine.lastInputHash {
                    outcome = .silent
                } else if let matter = await upsertDraft(ownedDraft(draft, for: routine), into: matterStore, now: now) {
                    outcome = .prepared
                    preparedMatterID = matter.id
                    detail = matter.title
                }
            }

        case .weeklyReview:
            let todayStart = calendar.startOfDay(for: now)
            let weekEnd = calendar.date(byAdding: .day, value: 7, to: todayStart) ?? todayStart.addingTimeInterval(7 * 86_400)
            let input = await digestInput(now: now, eventsIn: DateInterval(start: todayStart, end: weekEnd),
                                          remindersDueBefore: weekEnd, store: matterStore)
            if let draft = WeeklyReviewBuilder.draft(input) {
                inputHash = draft.sourceVersion
                if !manual && routine.onlyWhenNew && draft.sourceVersion == routine.lastInputHash {
                    outcome = .silent
                } else if let matter = await upsertDraft(ownedDraft(draft, for: routine), into: matterStore, now: now) {
                    outcome = .prepared
                    preparedMatterID = matter.id
                    detail = matter.title
                }
            }

        case .calendarRadar:
            let lookahead: Int
            if case .calendarChange(let hours) = routine.trigger { lookahead = hours } else { lookahead = 48 }
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                outcome = .skipped
                break
            }
            let windowEnd = now.addingTimeInterval(TimeInterval(lookahead) * 3600)
            let events = await readCalendarEvents(in: DateInterval(start: now, end: windowEnd))
            let prev = (try? await routineStore.snapshot(for: routine.id)) ?? nil
            let eval = CalendarRadarBuilder.evaluate(
                events: events,
                previousSnapshotJSON: prev,
                now: now,
                lookaheadHours: lookahead,
                calendar: calendar,
                language: lang
            )
            try? await routineStore.saveSnapshot(eval.nextSnapshotJSON, for: routine.id, now: now)
            inputHash = eval.inputHash
            if let draft = eval.draft {
                if !manual && routine.onlyWhenNew && eval.inputHash == routine.lastInputHash {
                    outcome = .silent
                } else if let matter = await upsertDraft(ownedDraft(draft, for: routine), into: matterStore, now: now) {
                    outcome = .prepared
                    preparedMatterID = matter.id
                    detail = matter.title
                }
            }

        case .meetingPrep:
            let leadMinutes: Int
            if case .upcomingMeeting(let minutes) = routine.trigger { leadMinutes = minutes } else { leadMinutes = 30 }
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                outcome = .skipped
                break
            }
            let windowEnd = now.addingTimeInterval(24 * 3600)
            let events = await readCalendarEvents(in: DateInterval(start: now, end: windowEnd))
            if let nextLead = UpcomingMeetingPrepBuilder.nextLeadDate(events: events, now: now, leadMinutes: leadMinutes) {
                if nextUpcomingMeetingLead == nil || nextUpcomingMeetingLead!.date <= now || nextLead < nextUpcomingMeetingLead!.date {
                    nextUpcomingMeetingLead = (nextLead, routine.title)
                }
            }
            let reminders = await readOpenReminders(dueBefore: nil, limit: 40)
            let open = ((try? await matterStore.matters(states: [.open, .offered])) ?? [])
            var snapshotJSON = (try? await routineStore.snapshot(for: routine.id)) ?? nil
            var lastHash: String?
            for _ in 0..<8 {
                let eval = UpcomingMeetingPrepBuilder.evaluate(
                    events: events,
                    reminders: reminders,
                    openMatters: open,
                    previousSnapshotJSON: snapshotJSON,
                    now: now,
                    leadMinutes: leadMinutes,
                    calendar: calendar,
                    language: lang
                )
                snapshotJSON = eval.nextSnapshotJSON
                lastHash = eval.inputHash
                guard let draft = eval.draft else { break }
                if let matter = await upsertDraft(ownedDraft(draft, for: routine), into: matterStore, now: now) {
                    outcome = .prepared
                    if preparedMatterID == nil {
                        preparedMatterID = matter.id
                        detail = matter.title
                    }
                }
            }
            if let snapshotJSON {
                try? await routineStore.saveSnapshot(snapshotJSON, for: routine.id, now: now)
            }
            inputHash = lastHash

        case .reminderRadar:
            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                outcome = .skipped
                break
            }
            let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
            let reminders = await readOpenReminders(dueBefore: tomorrowStart, limit: 40)
            let prev = (try? await routineStore.snapshot(for: routine.id)) ?? nil
            let eval = ReminderRadarBuilder.evaluate(
                reminders: reminders,
                previousSnapshotJSON: prev,
                now: now,
                calendar: calendar,
                language: lang
            )
            try? await routineStore.saveSnapshot(eval.nextSnapshotJSON, for: routine.id, now: now)
            inputHash = eval.inputHash
            if let draft = eval.draft {
                if !manual && routine.onlyWhenNew && eval.inputHash == routine.lastInputHash {
                    outcome = .silent
                } else if let matter = await upsertDraft(ownedDraft(draft, for: routine), into: matterStore, now: now) {
                    outcome = .prepared
                    preparedMatterID = matter.id
                    detail = matter.title
                }
            }

        case .folderWatch:
            guard case .folder(let path, let bookmark) = routine.trigger, !path.isEmpty || bookmark != nil else {
                outcome = .skipped
                break
            }
            let resolved: URL? = await Task.detached(priority: .utility) {
                Self.resolveFolderOffMain(bookmark: bookmark, fallbackPath: path)
            }.value
            guard let url = resolved else {
                outcome = .skipped
                break
            }
            let scanner = WatchedFolderScanner(store: matterStore, language: lang)
            do {
                let report = try await Task.detached(priority: .utility) {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    return try await scanner.scan(folderURL: url, now: now)
                }.value
                if let first = report.actionableMatters.first {
                    outcome = .prepared
                    preparedMatterID = first.id
                    detail = first.title
                } else {
                    outcome = .silent
                }
            } catch {
                outcome = .failed
                detail = "folder scan failed"
            }

        case .followUp, .customCheck:
            switch routine.executionMode {
            case .prepareForChat, .deterministic:
                let draft = ProactiveMatterDraft(
                    kind: routine.matterKind,
                    matterKey: "routine:\(routine.id.uuidString):\(slotKey)",
                    sourceRef: "routine:\(routine.id.uuidString)",
                    sourceVersion: slotKey,
                    title: routine.title,
                    summary: routine.instruction,
                    preparedPrompt: routine.instruction
                )
                inputHash = slotKey
                if let matter = await upsertDraft(draft, into: matterStore, now: now) {
                    outcome = .prepared
                    preparedMatterID = matter.id
                    detail = matter.title
                }

            case .localAIReadOnly:
                let aiOutcome = await RoutineAIRunner.shared.run(routine: routine, now: now, language: lang)
                switch aiOutcome {
                case .prepared(let title, let summary):
                    let hash = Self.sha256(title + "\n---\n" + summary)
                    inputHash = hash
                    if !manual && routine.onlyWhenNew && hash == routine.lastInputHash {
                        outcome = .silent
                    } else {
                        // Security invariant: `preparedPrompt` is ALWAYS person-authored `routine.instruction`,
                        // NEVER untrusted model output.
                        let draft = ProactiveMatterDraft(
                            kind: routine.matterKind,
                            matterKey: "routine:\(routine.id.uuidString):\(slotKey)",
                            sourceRef: "routine:\(routine.id.uuidString)",
                            sourceVersion: hash,
                            title: title,
                            summary: summary,
                            preparedPrompt: routine.instruction
                        )
                        if let matter = await upsertDraft(draft, into: matterStore, now: now) {
                            outcome = .prepared
                            preparedMatterID = matter.id
                            detail = matter.title
                        }
                    }
                case .nothingNew:
                    outcome = .silent
                case .cancelled:
                    // Cancellation or shutdown must never consume the slot, disable a one-off, or write to SQLite.
                    skipRecording = true
                case .busy:
                    if manual {
                        outcome = .skipped
                        detail = "busy"
                    } else {
                        // Defer scheduled slot so it runs cleanly once chat finishes.
                        skipRecording = true
                    }
                case .unavailable(let reason):
                    outcome = .skipped
                    detail = reason
                case .timedOut:
                    outcome = .failed
                    detail = "timeout"
                case .failed(let reason):
                    outcome = .failed
                    detail = reason
                }
            }
        }

        guard !skipRecording, !Task.isCancelled, settings.enabled else { return }
        // Never resurrect a routine or record an orphan run if it was deleted while executing.
        guard var updated = (try? await routineStore.routine(id: routine.id)) ?? nil else { return }
        let finishedAt = Date()

        // Avoid flooding recentRuns with no-op ticks from reactive watchers when nothing changed.
        if outcome != .silent || recordRunIfSilent {
            let record = RoutineRunRecord(
                routineID: routine.id,
                routineTitle: updated.title,
                slotKey: slotKey,
                outcome: outcome,
                matterID: preparedMatterID,
                inputHash: inputHash,
                detail: detail,
                startedAt: startedAt,
                finishedAt: finishedAt
            )
            _ = try? await routineStore.recordRun(record)
        }

        // Persist updated routine metadata (slot key, hash, outcome, nextRunAt, one-off auto-disable).
        let triggerUnchanged = updated.trigger == routine.trigger
        let shouldUpdateMetadata = outcome != .silent || recordRunIfSilent || !manual
            || (triggerUnchanged && (disableAfterFire || nextFireDate != updated.nextRunAt))
        if shouldUpdateMetadata {
            if outcome != .silent || recordRunIfSilent {
                updated.lastRunAt = finishedAt
                updated.lastOutcome = outcome
                if let detail { updated.lastSummary = detail }
            }
            if let inputHash { updated.lastInputHash = inputHash }
            if triggerUnchanged {
                if !manual && !routine.isReactiveWatcher {
                    updated.lastSlotKey = slotKey
                }
                if disableAfterFire {
                    updated.enabled = false
                    updated.nextRunAt = nil
                } else if let nextFireDate {
                    updated.nextRunAt = nextFireDate
                }
            }
            updated.updatedAt = finishedAt
            try? await routineStore.upsert(updated)
            if triggerUnchanged && disableAfterFire {
                let allAfterFire = (try? await routineStore.allRoutines()) ?? []
                syncLegacySettings(from: updated, allRoutines: allAfterFire)
            }
        }
    }

    private func ownedDraft(_ draft: ProactiveMatterDraft, for routine: ProactiveRoutine) -> ProactiveMatterDraft {
        ProactiveMatterDraft(
            kind: draft.kind,
            matterKey: draft.matterKey,
            sourceRef: "routine:\(routine.id.uuidString)",
            sourceVersion: draft.sourceVersion,
            title: draft.title,
            summary: draft.summary,
            preparedPrompt: draft.preparedPrompt,
            preparedFiles: draft.preparedFiles
        )
    }

    private func upsertDraft(_ draft: ProactiveMatterDraft, into store: ProactiveMatterStore, now: Date) async -> ProactiveMatter? {
        do {
            let result = try await store.upsertPrepared(draft, now: now)
            if case .keptClosed = result { return nil }
            return result.matter
        } catch {
            DiagnosticsLog.shared.event("proaktiv-matter-fehler", [:])
            return nil
        }
    }

    /// Delivers `matter` to Pippa Island when `ProactivityGate` says so and the store recorded it under the daily cap.
    private func deliver(_ matter: ProactiveMatter, store: ProactiveMatterStore, now: Date) async -> Bool {
        guard matter.state == .open || matter.state == .snoozed else { return false }
        let dayKey = ProactiveMatterStore.dayKey(for: now)
        let delivered = (try? await store.deliveredCount(forDayKey: dayKey)) ?? Int.max
        let fresh = (try? await store.isFresh(matterID: matter.id, expectedSourceVersion: matter.sourceVersion)) ?? false
        let owner = resolveOwner(for: matter, in: routines)
        let routineEnabled = owner?.enabled ?? true
        let deliveryMode = owner?.deliveryMode ?? .islandAndDesk
        let decision = ProactivityGate.evaluate(
            matter: matter,
            settings: settings,
            deliveredToday: delivered,
            focusReader: focusReader,
            isAnswering: ChatModel.shared.isAnswering,
            isFresh: fresh,
            now: now,
            routineEnabled: routineEnabled,
            deliveryMode: deliveryMode
        )
        guard decision == .deliver else { return false }
        let result = try? await store.recordDelivery(
            matterID: matter.id,
            kind: matter.kind,
            dayKey: dayKey,
            cap: settings.dailyCap,
            expectedSourceVersion: matter.sourceVersion,
            shownAt: now
        )
        guard case .recorded = result, settings.enabled else { return false }
        let offered = ((try? await store.matter(id: matter.id)) ?? nil) ?? matter
        DiagnosticsLog.shared.event("proaktiv-hinweis", ["art": matter.kind.rawValue])
        activeNudge = offered
        return true
    }

    private func morningBriefDue(now: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
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
        let events = await readCalendarEvents(in: DateInterval(start: start, end: end))
        let reminders = await readOpenReminders(dueBefore: end, limit: 20)
        var open: [ProactiveMatter] = []
        if let store {
            open = ((try? await store.matters(states: [.open, .offered, .snoozed])) ?? []).filter { $0.kind != .morningBrief }
        }
        return MorningBriefInput(day: day, events: events, reminders: reminders, openMatters: open, calendar: calendar, language: Self.language)
    }

    private func digestInput(
        now: Date,
        eventsIn interval: DateInterval,
        remindersDueBefore: Date?,
        store: ProactiveMatterStore
    ) async -> RoutineDigestInput {
        let calendar = Calendar.autoupdatingCurrent
        let events = await readCalendarEvents(in: interval)
        let reminders = await readOpenReminders(dueBefore: remindersDueBefore, limit: 40)
        let open = ((try? await store.matters(states: [.open, .offered])) ?? []).filter { $0.kind != .morningBrief }
        return RoutineDigestInput(now: now, events: events, reminders: reminders, openMatters: open, calendar: calendar, language: Self.language)
    }

    /// Reads Calendar events ONLY if `.fullAccess` was already granted; never requests permission.
    private func readCalendarEvents(in interval: DateInterval) async -> [CalendarEvent] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let integrations = SystemIntegrations()
        return (try? await integrations.events(in: interval, limit: CalendarReader.limit).events) ?? []
    }

    /// Reads open Reminders ONLY if `.fullAccess` was already granted; never requests permission.
    private func readOpenReminders(dueBefore: Date?, limit: Int) async -> [ReminderItem] {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return [] }
        let integrations = SystemIntegrations()
        return (try? await integrations.openReminders(dueBefore: dueBefore, limit: limit).items) ?? []
    }

    /// "Preview now" in Settings: today's brief as text, built in code, without storing or counting it.
    func previewMorningBriefNow() {
        guard !isPreviewing else { return }
        isPreviewing = true
        Task { [weak self] in
            guard let self else { return }
            let store = self.settings.enabled && !self.isSnapshotMode ? await self.ensureMatterStore() : nil
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

    /// "Open in Chat": starts a clean conversation with the prepared question and files, marks the notice
    /// resolved via `PersonAction`, and optionally auto-sends if requested and Pippa is ready.
    func openInChat(_ matter: ProactiveMatter, autoSend: Bool = false, surface: PersonAction.Surface = .island) {
        Island.shared.close()
        dismissDesk()
        let chat = ChatModel.shared
        chat.newConversation()
        ChatWindow.shared.show()
        let files = matter.preparedFiles.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        chat.attachments = files
        chat.frontApp = nil
        chat.draft = matter.preparedPrompt
        apply(.resolve(surface: surface), to: matter)
        if autoSend && SetupModel.shared.canAnswer && !chat.isAnswering {
            chat.send()
        }
    }

    func markDone(_ matter: ProactiveMatter, surface: PersonAction.Surface = .island) {
        apply(.resolve(surface: surface), to: matter)
    }

    func dismissMatter(_ matter: ProactiveMatter, surface: PersonAction.Surface = .panel) {
        apply(.dismiss(surface: surface), to: matter)
    }

    func snooze(_ matter: ProactiveMatter, hours: Int = 3, surface: PersonAction.Surface = .island) {
        let until = Date().addingTimeInterval(TimeInterval(max(1, hours)) * 3600)
        apply(.snooze(until: until, surface: surface), to: matter)
    }

    func snoozeUntilTomorrowMorning(_ matter: ProactiveMatter, surface: PersonAction.Surface = .panel) {
        let cal = Calendar.autoupdatingCurrent
        let today = cal.startOfDay(for: Date())
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        let until = cal.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow.addingTimeInterval(8 * 3600)
        apply(.snooze(until: until, surface: surface), to: matter)
    }

    func muteKind(_ kind: ProactiveMatterKind, dismissing matter: ProactiveMatter, surface: PersonAction.Surface = .island) {
        update { $0.mute(kind) }
        apply(.dismiss(surface: surface), to: matter)
    }

    private func apply(_ action: PersonAction, to matter: ProactiveMatter) {
        clear(matter)
        openMatters.removeAll { $0.id == matter.id }
        snoozedMatters.removeAll { $0.id == matter.id }
        if case .snooze(let until) = action.intent, until > Date() {
            var updated = matter
            updated.state = .snoozed
            updated.snoozedUntil = until
            updated.updatedAt = action.actedAt
            snoozedMatters.append(updated)
            snoozedMatters.sort { ($0.snoozedUntil ?? .distantFuture) < ($1.snoozedUntil ?? .distantFuture) }
        }
        guard !isSnapshotMode else { return }
        trackTask { [weak self] in
            guard let self, let store = await self.ensureMatterStore() else { return }
            do { _ = try await store.apply(action, to: matter.id) }
            catch { DiagnosticsLog.shared.event("proaktiv-aktion-fehler", [:]) }
            await self.refreshPublishedState()
            self.scheduleNextRoutineTimer()
        }
    }

    private func clear(_ matter: ProactiveMatter) {
        if activeNudge?.id == matter.id { activeNudge = nil }
    }

    // MARK: State Refresh, Pulse & Suggestions

    private func refreshPublishedState() async {
        guard settings.enabled, !isSnapshotMode else { return }
        let now = Date()
        let dayKey = ProactiveMatterStore.dayKey(for: now)

        if let mStore = await ensureMatterStore() {
            let active = (try? await mStore.matters(states: [.open, .offered])) ?? []
            openMatters = active
                .filter { !settings.isMuted($0.kind) }
                .sorted { ($0.updatedAt, $0.createdAt) > ($1.updatedAt, $1.createdAt) }

            let snoozed = (try? await mStore.matters(states: [.snoozed])) ?? []
            snoozedMatters = snoozed
                .filter { !settings.isMuted($0.kind) && ($0.snoozedUntil.map { $0 > now } ?? false) }
                .sorted { ($0.snoozedUntil ?? .distantFuture) < ($1.snoozedUntil ?? .distantFuture) }

            deliveredTodayCount = (try? await mStore.deliveredCount(forDayKey: dayKey)) ?? 0
        }

        if let rStore = await ensureRoutineStore() {
            routines = (try? await rStore.allRoutines()) ?? []
            recentRuns = (try? await rStore.recentRuns(limit: Self.recentRunsLimit)) ?? []
            hasSavedRoutines = !routines.isEmpty || Self.routinesDatabaseExists()
        }

        isFocusActiveNow = focusReader.currentStatus().isFocusActive
        nextScheduledSummary = computeNextScheduledSummary(now: now)
        suggestedTemplates = computeSuggestedTemplates()
    }

    /// Hermes permission-aware starter pack suggestions (never requests access).
    private func computeSuggestedTemplates() -> [ProactiveRoutineTemplate] {
        let calendarGranted = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        let remindersGranted = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        let enabledTemplates = Set(routines.filter(\.enabled).map(\.template))

        var candidates: [ProactiveRoutineTemplate] = []
        if calendarGranted {
            candidates += [.morningBrief, .eveningPreview, .calendarRadar, .meetingPrep]
        }
        if remindersGranted {
            candidates.append(.reminderRadar)
        }
        candidates.append(.folderWatch)
        return candidates.filter { !enabledTemplates.contains($0) }
    }

    /// Hermes live pulse: compact EN/DE summary of the earliest upcoming routine or meeting prep.
    private func computeNextScheduledSummary(now: Date) -> String? {
        let calendar = Calendar.autoupdatingCurrent
        let de = Self.language == "de"

        var candidates: [(date: Date, title: String)] = []
        for routine in routines where routine.enabled {
            if case .schedule(let schedule) = routine.trigger {
                let fire: Date?
                if let stored = routine.nextRunAt, stored > now {
                    fire = stored
                } else {
                    fire = ProactiveScheduleCalculator.nextFireDate(for: schedule, after: now, calendar: calendar)
                }
                if let fire {
                    candidates.append((fire, routine.title))
                }
            }
        }
        if let meetingLead = nextUpcomingMeetingLead, meetingLead.date > now {
            candidates.append((meetingLead.date, meetingLead.title))
        }
        guard let earliest = candidates.min(by: { $0.date < $1.date }) else { return nil }

        let minutesUntil = Int(ceil(earliest.date.timeIntervalSince(now) / 60))
        if minutesUntil <= 60 {
            let mins = max(1, minutesUntil)
            return de ? "In \(mins) Min · \(earliest.title)" : "In \(mins) min · \(earliest.title)"
        }
        let comps = calendar.dateComponents([.hour, .minute, .weekday], from: earliest.date)
        let timeStr = String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
        if calendar.isDateInToday(earliest.date) {
            return de ? "\(earliest.title) · Heute \(timeStr)" : "\(earliest.title) · Today \(timeStr)"
        }
        if calendar.isDateInTomorrow(earliest.date) {
            return de ? "\(earliest.title) · Morgen \(timeStr)" : "\(earliest.title) · Tomorrow \(timeStr)"
        }
        let weekdaysEN = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let weekdaysDE = ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"]
        let idx = min(max((comps.weekday ?? 2) - 1, 0), 6)
        let dayLabel = de ? weekdaysDE[idx] : weekdaysEN[idx]
        return "\(earliest.title) · \(dayLabel) \(timeStr)"
    }

    private func resolveOwner(for matter: ProactiveMatter, in list: [ProactiveRoutine]) -> ProactiveRoutine? {
        if matter.sourceRef.hasPrefix("routine:") {
            let suffix = String(matter.sourceRef.dropFirst("routine:".count))
            if let uuid = UUID(uuidString: suffix), let match = list.first(where: { $0.id == uuid }) {
                return match
            }
        }
        if matter.matterKey.hasPrefix("routine:") {
            let rest = matter.matterKey.dropFirst("routine:".count)
            if let colon = rest.firstIndex(of: ":"), let uuid = UUID(uuidString: String(rest[..<colon])),
               let match = list.first(where: { $0.id == uuid }) {
                return match
            }
        }
        if matter.kind == .morningBrief {
            return list.first(where: { $0.builtInKey == ProactiveRoutine.morningBriefKey })
                ?? list.first(where: { $0.template == .morningBrief })
        }
        if matter.matterKey.hasPrefix("evening-preview:") || matter.sourceRef.hasPrefix("routine:evening-preview:") {
            return list.first(where: { $0.builtInKey == ProactiveRoutine.eveningPreviewKey })
                ?? list.first(where: { $0.template == .eveningPreview })
        }
        if matter.matterKey.hasPrefix("weekly-review:") || matter.sourceRef.hasPrefix("routine:weekly-review:") {
            return list.first(where: { $0.builtInKey == ProactiveRoutine.weeklyReviewKey })
                ?? list.first(where: { $0.template == .weeklyReview })
        }
        if matter.kind == .calendarChange || matter.sourceRef == "routine:calendar-radar" {
            return list.first(where: { $0.builtInKey == ProactiveRoutine.calendarRadarKey })
                ?? list.first(where: { $0.template == .calendarRadar })
        }
        if matter.matterKey.hasPrefix("meeting-prep:") || matter.sourceRef == "routine:meeting-prep" {
            return list.first(where: { $0.builtInKey == ProactiveRoutine.meetingPrepKey })
                ?? list.first(where: { $0.template == .meetingPrep })
        }
        if matter.kind == .reminderDue || matter.sourceRef == "routine:reminder-radar" {
            return list.first(where: { $0.builtInKey == ProactiveRoutine.reminderRadarKey })
                ?? list.first(where: { $0.template == .reminderRadar })
        }
        if matter.kind == .watchedFile {
            let fileDir = URL(fileURLWithPath: matter.sourceRef).deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
            // Match active resolved watcher URLs first (handles bookmarks for renamed folders) and canonical trigger paths.
            if let exact = list.first(where: { routine in
                if let resolved = folderWatchers[routine.id]?.resolvedURL?.standardizedFileURL.resolvingSymlinksInPath().path,
                   resolved == fileDir {
                    return true
                }
                guard case .folder(let path, _) = routine.trigger, !path.isEmpty else { return false }
                return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path == fileDir
            }) {
                return exact
            }
            if let legacy = settings.watchedFolderPath, !legacy.isEmpty,
               URL(fileURLWithPath: legacy).standardizedFileURL.resolvingSymlinksInPath().path == fileDir {
                return list.first(where: { $0.builtInKey == ProactiveRoutine.watchedFolderKey })
            }
            return nil
        }
        return nil
    }

    // MARK: Seeding & Stores

    private func seedRoutinesIfNeeded(store: ProactiveRoutineStore) async {
        guard settings.enabled, !isSnapshotMode else { return }
        if let existingTask = seedingTask {
            await existingTask.value
            return
        }
        guard !hasSeededRoutines else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.seedingTask = nil }
            let existing = (try? await store.allRoutines()) ?? []
            guard !Task.isCancelled, self.settings.enabled, !self.isSnapshotMode else { return }
            self.hasSeededRoutines = true
            guard existing.isEmpty else { return }

            let now = Date()
            var starters = ProactiveRoutine.starterPacks(language: Self.language, now: now)
            for index in starters.indices {
                if starters[index].builtInKey == ProactiveRoutine.morningBriefKey {
                    let schedule = ProactiveSchedule.daily(hour: self.settings.morningBriefHour, minute: self.settings.morningBriefMinute)
                    starters[index].enabled = self.settings.morningBriefEnabled
                    starters[index].trigger = .schedule(schedule)
                }
                if starters[index].enabled, case .schedule(let schedule) = starters[index].trigger {
                    starters[index].nextRunAt = ProactiveScheduleCalculator.nextFireDate(for: schedule, after: now)
                }
                try? await store.upsert(starters[index])
            }
            if let path = self.settings.watchedFolderPath, !path.isEmpty {
                let folderRoutine = ProactiveRoutine.watchedFolder(
                    path: path,
                    bookmark: self.settings.watchedFolderBookmark,
                    language: Self.language,
                    enabled: !self.settings.isMuted(.watchedFile),
                    now: now
                )
                try? await store.upsert(folderRoutine)
            }
        }
        seedingTask = task
        await task.value
    }

    /// Opened off MainActor on first use while enabled, so a switched-off Pippa never touches SQLite and launch never stalls.
    private func ensureMatterStore() async -> ProactiveMatterStore? {
        guard settings.enabled, !isSnapshotMode else { return nil }
        if let matterStore { return matterStore }
        let base = PiSession.settingsDirectory
        let opened: ProactiveMatterStore? = await Task.detached(priority: .utility) {
            try? ProactiveMatterStore(baseDirectory: base)
        }.value
        guard settings.enabled, !isSnapshotMode else { return nil }
        if let opened {
            if matterStore == nil { matterStore = opened }
            return matterStore
        }
        DiagnosticsLog.shared.event("proaktiv-speicher-fehler", [:])
        return nil
    }

    private func ensureRoutineStore() async -> ProactiveRoutineStore? {
        guard settings.enabled, !isSnapshotMode else { return nil }
        if let routineStore { return routineStore }
        let base = PiSession.settingsDirectory
        let opened: ProactiveRoutineStore? = await Task.detached(priority: .utility) {
            try? ProactiveRoutineStore(baseDirectory: base)
        }.value
        guard settings.enabled, !isSnapshotMode else { return nil }
        if let opened {
            if routineStore == nil { routineStore = opened }
            return routineStore
        }
        DiagnosticsLog.shared.event("proaktiv-routinen-speicher-fehler", [:])
        return nil
    }

    private func ensureJobStore() async -> DurableJobStore? {
        guard settings.enabled, !isSnapshotMode else { return nil }
        if let jobStore { return jobStore }
        let base = PiSession.settingsDirectory
        let opened: DurableJobStore? = await Task.detached(priority: .utility) {
            try? DurableJobStore(baseDirectory: base)
        }.value
        guard settings.enabled, !isSnapshotMode else { return nil }
        if let opened {
            if jobStore == nil { jobStore = opened }
            return jobStore
        }
        DiagnosticsLog.shared.event("proaktiv-auftraege-fehler", [:])
        return nil
    }

    // MARK: Helpers

    private func trackTask(_ operation: @escaping @MainActor () async -> Void) {
        let id = UUID()
        backgroundTasks[id] = Task { [weak self] in
            defer { self?.backgroundTasks.removeValue(forKey: id) }
            await operation()
        }
    }

    private static func builtInKey(for template: ProactiveRoutineTemplate) -> String? {
        switch template {
        case .morningBrief: return ProactiveRoutine.morningBriefKey
        case .eveningPreview: return ProactiveRoutine.eveningPreviewKey
        case .weeklyReview: return ProactiveRoutine.weeklyReviewKey
        case .calendarRadar: return ProactiveRoutine.calendarRadarKey
        case .meetingPrep: return ProactiveRoutine.meetingPrepKey
        case .reminderRadar: return ProactiveRoutine.reminderRadarKey
        case .folderWatch: return ProactiveRoutine.watchedFolderKey
        case .followUp, .customCheck: return nil
        }
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func routinesDatabaseExists() -> Bool {
        let url = PiSession.settingsDirectory
            .appendingPathComponent("Proactivity", isDirectory: true)
            .appendingPathComponent("routines.sqlite")
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// The language Pippa's UI runs in, for briefs, file triage, and dynamic pulse summaries.
    private static var language: String {
        (Bundle.module.preferredLocalizations.first ?? "en").lowercased().hasPrefix("de") ? "de" : "en"
    }
}

private extension ProactiveRoutine {
    var folderPath: String? {
        if case .folder(let path, _) = trigger { return path }
        return nil
    }

    var isReactiveWatcher: Bool {
        switch trigger {
        case .calendarChange, .upcomingMeeting, .reminderDue, .folder: return true
        case .schedule: return false
        }
    }
}
