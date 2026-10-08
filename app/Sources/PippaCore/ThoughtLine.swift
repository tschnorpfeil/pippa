import Foundation

// The "Thought Line": one quiet line that says what Pippa is actually doing while an answer is on its way,
// and afterwards a small receipt of what was read.
//
// Every phase comes from a real host or Pi event (reading a file, recognizing a page, choosing passages, starting
// the local helper, waiting for the first words, a tool call, retry, compaction). Nothing is timed, guessed or
// taken from model output: no invented "thinking" steps, no fake progress. Engines that report nothing simply
// stay on `.starting` until text arrives.

/// What Pippa is doing right now during one answer.
public enum WorkPhase: Sendable, Equatable {
    /// Accepted; nothing more specific is known yet.
    case starting
    /// Reading an attached file (`index` counts from 1).
    case reading(name: String, index: Int, count: Int)
    /// Text recognition on a scanned page or image (`page` counts from 1).
    case recognizing(name: String, page: Int, pages: Int)
    /// Choosing the passages that go with the question.
    case choosingPassages
    /// The local helper is starting (only when it was not already running).
    case gettingReady
    /// Cold start: the knowledge is being loaded into memory. `progress` 0…1 measured from the server process
    /// (ColdStart.swift), `nil` while nothing can be measured yet.
    case wakingUp(progress: Double?)
    /// Cold start: loaded; Pippa's instructions are read once before the first words.
    case warmingUp
    /// Sent; waiting for the first words. `continuing`: part of the answer is already visible.
    case waitingForAnswer(continuing: Bool)
    /// Looking through the attached sources during the answer; `name` only when the host knows which one.
    case lookingThrough(name: String?)
    case lookingUpOnline
    case checkingCalendar
    case preparingPreview
    /// Pi works with its own tools (searching, reading, changing files); the step says what exactly.
    case working
    /// A failed attempt was discarded and is being repeated.
    case retrying
    /// The earlier conversation is being condensed to make room.
    case condensing
    /// The finished answer is checked in code against what was actually read (SourceFidelity).
    case checkingSources
    /// Pippa needs the person (a permission, a choice) before she can go on.
    case waitingForPerson
    /// Answer text is streaming; the line steps aside.
    case writing
    /// Stop was pressed; nothing else is accepted.
    case stopping

    /// Stable identity of the kind of activity (page numbers and file indices left out), for transitions and VoiceOver.
    public var kind: String {
        switch self {
        case .starting: "starting"
        case .reading(let name, _, _): "reading:" + name
        case .recognizing(let name, _, _): "recognizing:" + name
        case .choosingPassages: "choosing"
        case .gettingReady: "ready"
        case .wakingUp: "waking"
        case .warmingUp: "warming"
        case .waitingForAnswer(let continuing): continuing ? "continuing" : "waiting"
        case .lookingThrough(let name): "looking:" + (name ?? "")
        case .lookingUpOnline: "online"
        case .checkingCalendar: "calendar"
        case .preparingPreview: "preview"
        case .working: "working"
        case .retrying: "retry"
        case .condensing: "condensing"
        case .checkingSources: "checking"
        case .waitingForPerson: "person"
        case .writing: "writing"
        case .stopping: "stopping"
        }
    }

    /// Host preparation happens strictly in this order; a later event of an earlier step is stale.
    var preparationRank: Int? {
        switch self {
        case .starting: 0
        case .reading, .recognizing: 1
        case .choosingPassages: 2
        case .gettingReady, .wakingUp: 3
        case .warmingUp: 4
        default: nil
        }
    }

    /// Plain words, no architecture.
    public var title: String {
        switch self {
        case .starting, .waitingForAnswer(continuing: false): L("Preparing your answer…", table: "Thought")
        case .reading(let name, _, _): L("Reading %@…", table: "Thought", name)
        case .recognizing(_, let page, let pages):
            pages > 1 ? L("Recognizing text on page %lld of %lld…", table: "Thought", page, pages) : L("Recognizing text…", table: "Thought")
        case .choosingPassages: L("Finding the right passages…", table: "Thought")
        case .gettingReady: L("Getting ready…", table: "Thought")
        case .wakingUp: L("Waking up…", table: "Thought")
        case .warmingUp: L("Almost ready…", table: "Thought")
        case .waitingForAnswer(continuing: true): L("Continuing the answer…", table: "Thought")
        case .lookingThrough(let name):
            name.map { L("Looking in %@…", table: "Thought", $0) } ?? L("Looking through your documents…", table: "Thought")
        case .lookingUpOnline: L("Looking it up online…", table: "Thought")
        case .checkingCalendar: L("Checking your calendar…", table: "Thought")
        case .preparingPreview: L("Preparing a preview…", table: "Thought")
        case .working: L("Working on it…", table: "Thought")
        case .retrying: L("Trying again…", table: "Thought")
        case .condensing: L("Summarizing our conversation so far…", table: "Thought")
        case .checkingSources: L("Checking the answer against your documents…", table: "Thought")
        case .waitingForPerson: L("Waiting for you", table: "Thought")
        case .writing: L("Writing the answer…", table: "Thought")
        case .stopping: L("Stopping…", table: "Thought")
        }
    }

    /// Quieter second part of the line: which file, or how far through several.
    public var detail: String? {
        switch self {
        case .reading(_, let index, let count) where count > 1: L("%lld of %lld", table: "Thought", index, count)
        case .recognizing(let name, _, _): name
        case .wakingUp, .warmingUp: L("Takes a moment now, then it’s quicker", table: "Thought")
        default: nil
        }
    }

    /// Maps a Pi tool name to what the person sees. `nil`: bookkeeping tools (proposing actions, recording quotes)
    /// and unknown tools leave the current phase as it is rather than guessing.
    public static func tool(_ name: String, source: String?) -> WorkPhase? {
        // Pippa's MCP server on the Pi RPC path is called `mcp__pippa__<tool>` by Pi (read_document, web_search ...).
        var lowered = name.lowercased()
        if lowered.hasPrefix("mcp__pippa__") { lowered.removeFirst("mcp__pippa__".count) }
        switch lowered {
        case "list_context", "list_plan_files": return .lookingThrough(name: nil)
        case "read_context", "read_document": return .lookingThrough(name: source)
        case "propose_plan": return .preparingPreview
        case "propose_lookup", "web_search", "read_web_page": return .lookingUpOnline
        case "read_calendar": return .checkingCalendar
        default:
            if lowered.contains("calendar") || lowered.contains("kalender") { return .checkingCalendar }
            return nil
        }
    }
}

/// What the host or Pi reports during one answer (`ChatContext.onWork`). Calls arrive in order on any thread.
public enum WorkEvent: Sendable, Equatable {
    case phase(WorkPhase)
    /// One file was read: pages actually read, page count of the file, text recognition used.
    case sourceRead(name: String, pagesRead: Int?, pageCount: Int?, recognizedText: Bool)
    /// What went into the answer (read status and passages), replaces earlier facts per name.
    case sources([SourceReading])
    /// A Pi tool started; `source` is the host's name of the source it opened, never agent text.
    /// `step`: the everyday phrase for what the tool does (WorkStepPhrase), computed by the host.
    case toolStarted(name: String, source: String?, step: String? = nil)
    /// `outcome`: a short result such as "3 matches", when cheaply known.
    case toolEnded(name: String, outcome: String? = nil)
}

public typealias WorkEventHandler = @Sendable (WorkEvent) -> Void

/// One source as it was actually read for an answer.
public struct SourceReading: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case read, partial, unreadable, unavailable, namesOnly }
    public var name: String
    /// Text the person selected and handed over (not a file).
    public var isSelection: Bool
    public var status: Status
    public var pagesRead: Int?
    public var pageCount: Int?
    public var recognizedText: Bool
    /// Pi opened this source again while answering.
    public var openedWhileAnswering: Bool

    public init(name: String, isSelection: Bool = false, status: Status, pagesRead: Int? = nil, pageCount: Int? = nil, recognizedText: Bool = false,
                openedWhileAnswering: Bool = false) {
        self.name = name; self.isSelection = isSelection; self.status = status; self.pagesRead = pagesRead; self.pageCount = pageCount
        self.recognizedText = recognizedText
        self.openedWhileAnswering = openedWhileAnswering
    }

    public var wasRead: Bool { status == .read || status == .partial }
    public var displayName: String { isSelection ? L("Selected text", table: "Thought") : name }

    /// The facts behind one source, in plain words: how much was read, recognition.
    public var detail: String {
        var parts: [String] = []
        switch status {
        case .read:
            if let pages = pagesRead, pages > 1 { parts.append(L("All %lld pages read", table: "Thought", pages)) }
            else { parts.append(L("Read", table: "Thought")) }
        case .partial:
            if let read = pagesRead, let count = pageCount, count > read {
                parts.append(L("Pages 1–%lld of %lld read", table: "Thought", read, count))
            } else { parts.append(L("Read in part", table: "Thought")) }
        case .unreadable: parts.append(L("No readable text", table: "Thought"))
        case .unavailable: parts.append(L("Not available anymore", table: "Thought"))
        case .namesOnly: parts.append(L("File names only", table: "Thought"))
        }
        if recognizedText && wasRead { parts.append(L("text recognized", table: "Thought")) }
        if openedWhileAnswering { parts.append(L("looked at again while answering", table: "Thought")) }
        return parts.joined(separator: " · ")
    }
}

/// The small note under a finished answer: what was read and how long it took. Expands to `sources`.
public struct WorkReceipt: Codable, Sendable, Equatable {
    public var seconds: Int
    public var sources: [SourceReading]
    public var lookedUpOnline: Bool
    public var checkedCalendar: Bool
    /// The steps of the tool loop in everyday words (older receipts have none).
    public var steps: [WorkStep]?
    public init(seconds: Int, sources: [SourceReading], lookedUpOnline: Bool = false, checkedCalendar: Bool = false, steps: [WorkStep]? = nil) {
        self.seconds = seconds; self.sources = sources; self.lookedUpOnline = lookedUpOnline; self.checkedCalendar = checkedCalendar
        self.steps = steps?.isEmpty == false ? steps : nil
    }

    /// "3 sources read · 12 s" and its honest variants (partly read, not readable).
    public var summary: String {
        let time = Self.duration(seconds)
        let read = sources.filter(\.wasRead)
        let partial = read.filter { $0.status == .partial }.count
        if sources.count == 1, let only = sources.first {
            switch only.status {
            case .read: return L("Read %@ · %@", table: "Thought", only.displayName, time)
            case .partial: return L("Read part of %@ · %@", table: "Thought", only.displayName, time)
            default: return L("Couldn’t read %@ · %@", table: "Thought", only.displayName, time)
            }
        }
        if sources.count > 1 {
            if read.count < sources.count { return L("Read %lld of %lld sources · %@", table: "Thought", read.count, sources.count, time) }
            if partial > 0 { return L("Read %lld sources, %lld only in part · %@", table: "Thought", read.count, partial, time) }
            return L("Read %lld sources · %@", table: "Thought", read.count, time)
        }
        if lookedUpOnline { return L("Looked it up online · %@", table: "Thought", time) }
        if checkedCalendar { return L("Checked your calendar · %@", table: "Thought", time) }
        if let steps, !steps.isEmpty {
            return steps.count == 1 ? L("1 step · %@", table: "Thought", time) : L("%lld steps · %@", table: "Thought", steps.count, time)
        }
        return time
    }

    /// Elapsed time in plain units ("12 s", "1 min 5 s").
    public static func duration(_ seconds: Int) -> String {
        let value = max(0, seconds)
        if value < 60 { return L("%lld s", table: "Thought", value) }
        let rest = value % 60
        return rest == 0 ? L("%lld min", table: "Thought", value / 60) : L("%lld min %lld s", table: "Thought", value / 60, rest)
    }
}

/// State of the Thought Line for one answer at a time. Pure and deterministic: callers pass the request and the time.
/// Events for another request, after Stop or after the end are dropped, so no stale phase survives a Stop or a switch.
public struct ThoughtLine: Sendable, Equatable {
    /// Elapsed time appears only after this (anything longer than two seconds shows progress).
    public static let elapsedThreshold = 2
    /// VoiceOver hears a new kind of activity at most this often; page counters are never announced.
    public static let announcementInterval: TimeInterval = 3

    public private(set) var request: UUID?
    public private(set) var phase: WorkPhase?
    public private(set) var startedAt: Date?
    public private(set) var sources: [SourceReading] = []
    public private(set) var lookedUpOnline = false
    public private(set) var checkedCalendar = false
    private var furthest = 0
    private var textSeen = false
    private var openTools: [WorkPhase?] = []
    /// Index into `steps` per open tool (parallel to `openTools`); `nil`: the tool shows no step.
    private var openSteps: [Int?] = []
    /// Steps so far, oldest first (at most `maxSteps`); the open ones have no `finished` mark.
    public private(set) var steps: [WorkStep] = []
    private var finishedSteps = 0
    private var stopped = false

    public init() {}

    public static let maxSteps = 40
    /// How many finished steps stay in the quiet list under the line.
    public static let visibleSteps = 4

    /// The step that is running now (the newest open one), in everyday words.
    public var currentStep: String? {
        guard let index = openSteps.last(where: { $0 != nil }) ?? nil, steps.indices.contains(index) else { return nil }
        return steps[index].text
    }

    /// Finished steps, newest last, for the quiet list (`hidden`: how many older ones are not listed).
    public var recentSteps: (shown: [WorkStep], hidden: Int) {
        let open = Set(openSteps.compactMap { $0 })
        let done = steps.enumerated().filter { !open.contains($0.offset) }.map(\.element)
        return (Array(done.suffix(Self.visibleSteps)), max(0, done.count - Self.visibleSteps))
    }

    /// The line is visible while something real happens before or between answer text.
    public var isVisible: Bool {
        guard let phase else { return false }
        return phase != .writing
    }

    public func elapsedSeconds(at now: Date) -> Int {
        guard let startedAt else { return 0 }
        return max(0, Int(now.timeIntervalSince(startedAt)))
    }

    public func showsElapsed(at now: Date) -> Bool { isVisible && elapsedSeconds(at: now) >= Self.elapsedThreshold }

    public mutating func begin(_ request: UUID, at now: Date) {
        self = ThoughtLine()
        self.request = request
        startedAt = now
        phase = .starting
    }

    /// Applies one event; returns whether the visible phase changed.
    @discardableResult
    public mutating func apply(_ event: WorkEvent, request: UUID, at now: Date) -> Bool {
        guard accepts(request) else { return false }
        let before = phase
        let stepBefore = currentStep
        switch event {
        case .phase(let next): enter(next)
        case .sourceRead(let name, let pagesRead, let pageCount, let recognized):
            var source = sources.first { $0.name == name } ?? SourceReading(name: name, status: .read)
            source.pagesRead = pagesRead; source.pageCount = pageCount; source.recognizedText = recognized
            upsert(source)
        case .sources(let list):
            for var source in list {
                if let known = sources.first(where: { $0.name == source.name }) {
                    source.pagesRead = source.pagesRead ?? known.pagesRead
                    source.pageCount = source.pageCount ?? known.pageCount
                    source.recognizedText = source.recognizedText || known.recognizedText
                    source.openedWhileAnswering = source.openedWhileAnswering || known.openedWhileAnswering
                }
                upsert(source)
            }
        case .toolStarted(let name, let sourceName, let step):
            // Only names the host listed as sources are shown; anything else stays generic.
            var mapped = WorkPhase.tool(name, source: nil)
            if case .lookingThrough = mapped, let sourceName, var known = sources.first(where: { $0.name == sourceName }) {
                known.openedWhileAnswering = true
                upsert(known)
                mapped = .lookingThrough(name: known.displayName)
            }
            if mapped == .lookingUpOnline { lookedUpOnline = true }
            if mapped == .checkingCalendar { checkedCalendar = true }
            var stepIndex: Int?
            if let step, !step.isEmpty {
                steps.append(WorkStep(text: step))
                if steps.count > Self.maxSteps { steps.removeFirst(); openSteps = openSteps.map { $0.map { $0 - 1 }.flatMap { $0 >= 0 ? $0 : nil } } }
                stepIndex = steps.count - 1
                // Pi's own tools (no mapped phase) still move the line: "Working on it" with the step as detail.
                if mapped == nil { mapped = .working }
            }
            openSteps.append(stepIndex)
            openTools.append(mapped)
            furthest = Int.max
            if let mapped { phase = mapped }
        case .toolEnded(_, let outcome):
            if let index = openSteps.popLast() ?? nil, steps.indices.contains(index) { steps[index].outcome = outcome }
            // A tool that never changed the line does not change it when it ends either.
            let ended = openTools.popLast() ?? nil
            if let running = openTools.compactMap({ $0 }).last { phase = running }
            else if ended != nil { phase = .waitingForAnswer(continuing: textSeen) }
        }
        return phase != before || currentStep != stepBefore
    }

    /// Answer text arrived: the line steps aside.
    @discardableResult
    public mutating func textArrived(request: UUID) -> Bool {
        guard accepts(request), phase != .writing else { return false }
        textSeen = true
        furthest = Int.max
        phase = .writing
        return true
    }

    /// A message handed over while answering was taken up: what follows is a new answer.
    public mutating func steered(request: UUID) {
        guard accepts(request) else { return }
        textSeen = false
        phase = .waitingForAnswer(continuing: false)
    }

    /// Stop pressed: show that Pippa stops, accept nothing else.
    public mutating func stop(request: UUID) {
        guard accepts(request) else { return }
        stopped = true
        phase = .stopping
    }

    /// Answer finished. Returns the receipt when there is something worth reporting (sources or tools); resets.
    public mutating func finish(request: UUID, at now: Date) -> WorkReceipt? {
        guard self.request == request, !stopped else { if self.request == request { self = ThoughtLine() }; return nil }
        let receipt = WorkReceipt(seconds: elapsedSeconds(at: now), sources: sources, lookedUpOnline: lookedUpOnline, checkedCalendar: checkedCalendar,
                                  steps: steps)
        self = ThoughtLine()
        return receipt.sources.isEmpty && !receipt.lookedUpOnline && !receipt.checkedCalendar && receipt.steps == nil ? nil : receipt
    }

    /// Ends the line without a receipt (stopped, failed, or the request is gone).
    public mutating func end(request: UUID) {
        guard self.request == request else { return }
        self = ThoughtLine()
    }

    /// Should VoiceOver hear this phase? Only a new kind of activity, not the writing itself, and not too often.
    public static func shouldAnnounce(_ phase: WorkPhase, lastKind: String?, lastAnnouncement: Date?, now: Date) -> Bool {
        shouldAnnounce(kind: phase.kind, phase: phase, lastKind: lastKind, lastAnnouncement: lastAnnouncement, now: now)
    }

    /// Same rule for a step ("Lese Brief.docx"): `kind` identifies it; the throttle is shared with the phases.
    public static func shouldAnnounce(kind: String, phase: WorkPhase, lastKind: String?, lastAnnouncement: Date?, now: Date) -> Bool {
        guard phase != .writing, kind != lastKind else { return false }
        if phase == .stopping || phase == .waitingForPerson { return true }
        guard let lastAnnouncement else { return true }
        return now.timeIntervalSince(lastAnnouncement) >= announcementInterval
    }

    private func accepts(_ request: UUID) -> Bool { self.request == request && phase != nil && !stopped }

    private mutating func enter(_ next: WorkPhase) {
        switch next {
        case .writing:
            textSeen = true; furthest = Int.max; phase = .writing
        case .stopping:
            stopped = true; phase = .stopping
        case .waitingForAnswer:
            guard openTools.isEmpty else { return }
            furthest = Int.max
            phase = .waitingForAnswer(continuing: textSeen)
        case .waitingForPerson, .retrying, .condensing, .checkingSources:
            phase = next
        default:
            if let rank = next.preparationRank {
                // Late preparation events (after a later step or after the answer began) are stale.
                guard rank >= furthest, !textSeen, openTools.isEmpty else { return }
                furthest = rank
            }
            phase = next
        }
    }

    private mutating func upsert(_ source: SourceReading) {
        if let index = sources.firstIndex(where: { $0.name == source.name }) { sources[index] = source } else { sources.append(source) }
    }
}
