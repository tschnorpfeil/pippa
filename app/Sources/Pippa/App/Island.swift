import AppKit
import Combine
import PippaCore
import PiRPC

/// Pippa Island: a black companion at the notch (or under the menu bar symbol on a display without one). It shows
/// what Pippa is doing, asks Pi's questions, and takes a quick question or dropped files. At rest it is invisible:
/// hidden in the camera housing, or just the menu bar symbol.
@MainActor
final class Island: ObservableObject {
    static let shared = Island()

    /// On unless the person switched it off; the pill's saved choice ("showsPill") still counts.
    @Published var isShown = UserDefaults.standard.object(forKey: "showsPill") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isShown, forKey: "showsPill")
            apply()
        }
    }
    @Published private(set) var status = IslandStatus.rest
    @Published private(set) var isOpen = false
    /// Raised to put the keyboard in the question field.
    @Published private(set) var focusToken = 0
    private(set) var wantsFocus = false
    /// The menu bar symbol: the island hangs under it on a display without a notch.
    weak var statusButton: NSStatusBarButton?

    private(set) var presenter: IslandPresenter?
    /// The menu bar symbol's state. Beside the notch the island carries her live mark, so the symbol stays at rest;
    /// set after every status or placement change, so the two never animate together or both rest while she works.
    @Published private(set) var menuMark = MarkState.ruht
    private var watches: [AnyCancellable] = []
    private var screenObserver: NSObjectProtocol?
    /// "Your answer is ready" or "That didn't work", for a few seconds after an answer.
    private var flash: ChatModel.Unseen?
    private var flashClear: Task<Void, Never>?
    /// The finished answer the open island shows: one the person has not seen yet. It goes once the island closes
    /// after showing it or the chat window comes to the front, so the island never keeps an old answer.
    @Published private(set) var freshAnswer: UUID?
    /// "New conversation" pressed in the island: the next question starts fresh although a recent one could go on.
    @Published var startsFresh = false
    private var answeringID: String?
    /// The island opened by itself for a question and closes again once it is answered.
    private var openedForQuestion = false
    private var presenting = false
    /// Files are being dragged in another app with the pointer near the top of the island's display: the island opens
    /// as a large drop tray, so nobody has to open it first.
    @Published private(set) var dropMode = false
    private var dragMonitor: Any?
    private var dragStart = 0
    static let fileDragTypes: [NSPasteboard.PasteboardType] =
        [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    /// How far below the top of the display a drag counts as heading for the island.
    static let dragReach: CGFloat = 160

    /// At launch: shows the island if it is switched on.
    func start() { apply() }

    /// Snapshots only (`IslandSnapshots`).
    func showForSnapshot(_ status: IslandStatus, dropMode: Bool = false, fresh: UUID? = nil) {
        self.status = status
        self.dropMode = dropMode
        freshAnswer = fresh
    }

    private func apply() {
        // The menu bar symbol follows the status also while the island is off.
        watch()
        if isShown {
            if presenter == nil { presenter = makePresenter() }
            if !presenting {
                // The island can always show a question, so it is a presenter for as long as it is on.
                Approvals.shared.present("island") { [weak self] in self?.reveal() }
                presenting = true
            }
            refresh()
        } else {
            if presenting {
                Approvals.shared.dismiss("island")
                presenting = false
            }
            presenter?.place(nil, compactWidth: nil)
            isOpen = false
            refresh()
        }
    }

    private func makePresenter() -> IslandPresenter {
        let presenter = IslandPresenter(island: self)
        presenter.sourceRect = { [weak self] in self?.statusButtonFrame ?? .zero }
        presenter.onEscape = { [weak self] in self?.declineQuestion() ?? false }
        presenter.onClosed = { [weak self] in
            guard let self else { return }
            isOpen = false
            dropMode = false
            openedForQuestion = false
            wantsFocus = false
            // "New conversation" counts for this opening only, also when it was closed with Escape or a click outside.
            startsFresh = false
            // Seen: the next time the island opens it starts fresh.
            if !ChatModel.shared.isAnswering { freshAnswer = nil }
            statusButton?.highlight(false)
        }
        presenter.onIdle = { [weak self] in self?.refresh() }
        return presenter
    }

    private func watch() {
        guard watches.isEmpty else { return }
        let chat = ChatModel.shared
        let changes = Publishers.MergeMany(
            chat.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            SetupModel.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            Approvals.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            DropFeedback.island.objectWillChange.map { _ in () }.eraseToAnyPublisher())
        // objectWillChange comes before the change: read the models on the next turn of the run loop.
        watches.append(changes.receive(on: RunLoop.main).sink { [weak self] in self?.refresh() })
        // Not deduplicated: `unseen` stays `.answer` until the chat is opened, and every later answer flashes too.
        watches.append(chat.$unseen.sink { [weak self] unseen in self?.showFlash(unseen) })
        // An answer that ends while the chat window is not in front stays in the island until it was seen there.
        watches.append(chat.$answeringID.sink { [weak self] id in
            guard let self else { return }
            let ended = answeringID
            answeringID = id
            guard id == nil, let ended else { return }
            DispatchQueue.main.async { self.answerEnded(in: ended) }
        })
        watches.append(Approvals.shared.$questions.map(\.isEmpty).removeDuplicates().sink { [weak self] empty in
            guard let self, empty, openedForQuestion else { return }
            DispatchQueue.main.async { self.close() }
        })
        // Mouse events of other apps need no permission; the drag pasteboard tells a file drag from any other.
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.followDrag(type) }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // A display came or went: start again from rest on whichever display has the island now.
                self?.presenter?.close(animated: false)
                self?.refresh()
            }
        }
    }

    private func followDrag(_ type: NSEvent.EventType) {
        let board = NSPasteboard(name: .drag)
        switch type {
        case .leftMouseDown:
            dragStart = board.changeCount
        case .leftMouseUp where dropMode:
            // The drop reaches the island after this event: a tray that got nothing closes once it would have.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, dropMode, NSEvent.pressedMouseButtons & 1 == 0 else { return }
                close()
            }
        case .leftMouseDragged:
            // An island opened by hand already takes drops as it is.
            // Files only (also Mail's promised files): dragged text or a link is not headed for Pippa.
            guard isShown, !isOpen || dropMode, board.changeCount != dragStart,
                  board.availableType(from: Self.fileDragTypes) != nil, let placement = presenter?.placement else { return }
            let island: CGPoint
            switch placement {
            case .notch(let housing, _): island = CGPoint(x: housing.midX, y: housing.midY)
            case .menuBar(let anchor, _): island = CGPoint(x: anchor.midX, y: anchor.midY)
            }
            // Near the top of the display the island is on, not of a neighbour whose top lines up with it.
            let point = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(point) }
            let near = screen.map { $0.frame.contains(island) && point.y >= $0.frame.maxY - Self.dragReach } == true
            if near, !dropMode {
                dropMode = true
                open(key: false)
            } else if !near, dropMode {
                close()
            }
        default:
            break
        }
    }

    private func answerEnded(in conversation: String) {
        let message = ChatModel.shared.conversations.first { $0.id == conversation }?.messages.last { $0.role == .assistant }
        guard let message, isOpen || !ChatWindow.shared.isKey else { return }
        freshAnswer = message.id
    }

    private func showFlash(_ unseen: ChatModel.Unseen?) {
        flashClear?.cancel()
        // The chat window came to the front: the answer was seen there.
        if unseen == nil, ChatWindow.shared.isKey { freshAnswer = nil }
        flash = unseen
        guard unseen != nil else { return }
        flashClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self else { return }
            // The unread dot on the menu bar symbol and the Dock badge stay until the chat is opened.
            flash = nil
            refresh()
        }
    }

    func refresh() {
        defer { updateMenuMark() }
        let status = IslandStatus.current(chat: .shared, setup: .shared, questions: Approvals.shared.questions.count,
                                          flash: flash, targeted: DropFeedback.island.targeted)
        if status != self.status { self.status = status }
        guard isShown, let presenter else { return }
        presenter.view.compact.setAccessibilityValue(status.label)
        if !isOpen, presenter.isIdle, let placement = placement(), placement != presenter.placement {
            presenter.place(placement, compactWidth: compactWidth(status, placement))
        }
        guard let placement = presenter.placement else { return }
        presenter.setCompact(width: compactWidth(status, placement))
    }

    private func compactWidth(_ status: IslandStatus, _ placement: IslandPlacement) -> CGFloat? {
        guard status.showsCompact else { return nil }
        return placement.isNotch ? status.wingWidth : status.capsuleWidth
    }

    // MARK: Where

    private var statusButtonFrame: NSRect? {
        guard let button = statusButton, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// At the notch when a display has one; under the menu bar symbol otherwise, or when the symbol was clicked on
    /// another display than the notched one.
    private func placement(fromStatusItem: Bool = false) -> IslandPlacement? {
        let screens = NSScreen.screens
        let notch = screens.lazy.compactMap { screen -> IslandPlacement? in
            IslandGeometry.housing(screen: screen.frame, leftArea: screen.auxiliaryTopLeftArea,
                                   rightArea: screen.auxiliaryTopRightArea, topInset: screen.safeAreaInsets.top)
                .map { .notch(housing: $0, screen: screen.frame) }
        }.first
        if let anchor = statusButtonFrame, let screen = statusButton?.window?.screen {
            var onNotchScreen = false
            if case .notch(_, let frame) = notch { onNotchScreen = frame == screen.frame }
            if notch == nil || (fromStatusItem && !onNotchScreen) { return .menuBar(anchor: anchor, visible: screen.visibleFrame) }
        }
        if let notch { return notch }
        guard let screen = NSScreen.main ?? screens.first else { return nil }
        // No menu bar symbol (checks): where it usually is, near the right end of the menu bar.
        let visible = screen.visibleFrame
        return .menuBar(anchor: CGRect(x: visible.maxX - 160, y: visible.maxY, width: 30, height: screen.frame.maxY - visible.maxY),
                        visible: visible)
    }

    // MARK: Actions

    /// The menu bar symbol, or a click on the island.
    func toggle(fromStatusItem: Bool = false) {
        if isOpen { close() } else { open(key: true, fromStatusItem: fromStatusItem) }
    }

    /// The shortcut: open with the keyboard in the question field. The app in front goes with the next question.
    func ask(front: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) {
        if isOpen, presenter?.panel.isKeyWindow == true { close(); return }
        AppActions.noteFrontApp(front)
        open(key: true, focus: true)
    }

    /// A new question from Pi: the island opens by itself, without taking the keyboard from the app in front.
    func reveal() {
        // Open as a drop tray: the question takes its place, and the drag no longer closes it.
        if dropMode {
            dropMode = false
            openedForQuestion = true
            return
        }
        guard isShown, !isOpen else { return }
        openedForQuestion = true
        open(key: false)
    }

    func compactClicked() {
        // Right after an answer, a click goes to the answer.
        if !isOpen, status.tone == .done || status.tone == .failed { openChat(); return }
        toggle()
    }

    private func open(key: Bool, focus: Bool = false, fromStatusItem: Bool = false) {
        guard isShown, let presenter else { return }
        if !isOpen, let placement = placement(fromStatusItem: fromStatusItem), placement != presenter.placement {
            presenter.place(placement, compactWidth: compactWidth(status, placement))
        }
        updateMenuMark()
        guard presenter.placement != nil else { return }
        isOpen = true
        wantsFocus = focus
        presenter.open(key: key)
        if focus { focusToken += 1 }
        if case .menuBar = presenter.placement {
            // After the button's own mouse-up handling, which resets its highlight.
            DispatchQueue.main.async { [weak self] in self?.statusButton?.highlight(self?.isOpen == true) }
        }
    }

    func close() { presenter?.close() }

    private func updateMenuMark() {
        let state = isShown && presenter?.placement?.isNotch == true ? MarkState.ruht : status.markState
        if state != menuMark { menuMark = state }
    }

    /// The panel's content is on screen: a focus asked for while it was still hidden takes effect now.
    func panelShown() {
        if wantsFocus { focusToken += 1 }
    }

    /// "Open Pippa" (⌘↩), "Set up my AI", or a click on "Your answer is ready".
    func openChat() {
        close()
        ChatWindow.shared.show()
    }

    /// The earlier conversation under the empty field: the chat opens on it.
    func openConversation(_ id: String) {
        ChatModel.shared.select(id)
        openChat()
    }

    /// Files dropped on the island go with the next quick question.
    func attach(_ urls: [URL]) {
        dropMode = false
        let chat = ChatModel.shared
        chat.attachments += MailDropIdentity.attachments(urls, excluding: chat.attachments)
        open(key: true, focus: true)
    }

    /// What a question in the island goes on with: the latest conversation while the island still shows its answer or
    /// its last message is at most ten minutes old, so "And chapter 6?" keeps the context. Older, or after "New
    /// conversation": a new one.
    var followUp: Conversation? {
        guard !startsFresh else { return nil }
        let chat = ChatModel.shared
        guard let latest = chat.conversations.filter({ !$0.messages.isEmpty }).max(by: { $0.updated < $1.updated }) else { return nil }
        let showing = freshAnswer.map { id in latest.messages.contains { $0.id == id } } ?? false
        return showing || latest.updated > Date().addingTimeInterval(-600) ? latest : nil
    }

    /// Return in the question field: the question and any dropped files, going on with `followUp` or in a new
    /// conversation.
    func send() {
        let chat = ChatModel.shared
        let text = chat.draft, files = chat.attachments
        // Like the composer: until the AI can answer, the question stays in the field (the island shows the setup above it).
        guard !chat.isAnswering, SetupModel.shared.canAnswer,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty else { return }
        if let followUp { chat.select(followUp.id) } else { chat.newConversation() }
        startsFresh = false
        chat.draft = text
        chat.attachments = files
        chat.send()
    }

    /// Escape on a question: "Don't Allow", or no answer.
    private func declineQuestion() -> Bool {
        guard let question = Approvals.shared.questions.first else { return false }
        Approvals.shared.answer(question.id, question.request.method == "confirm" ? .confirmed(false) : .cancelled)
        return true
    }
}
