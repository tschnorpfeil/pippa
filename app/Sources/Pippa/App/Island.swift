import AppKit
import Combine
import PippaCore
import PiRPC

/// Settings binds its switch to `Pill.shared.isShown` (Views/SettingsWindow.swift); it now turns the island on and off.
typealias Pill = Island

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
    private var watches: [AnyCancellable] = []
    private var screenObserver: NSObjectProtocol?
    /// "Your answer is ready" or "That didn't work", for a few seconds after an answer.
    private var flash: ChatModel.Unseen?
    private var flashClear: Task<Void, Never>?
    /// The island opened by itself for a question and closes again once it is answered.
    private var openedForQuestion = false
    private var presenting = false

    /// At launch: shows the island if it is switched on.
    func start() { apply() }

    /// Snapshots only (`IslandSnapshots`).
    func showForSnapshot(_ status: IslandStatus) { self.status = status }

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
            openedForQuestion = false
            wantsFocus = false
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
        watches.append(chat.$unseen.removeDuplicates().sink { [weak self] unseen in self?.showFlash(unseen) })
        watches.append(Approvals.shared.$questions.map(\.isEmpty).removeDuplicates().sink { [weak self] empty in
            guard let self, empty, openedForQuestion else { return }
            DispatchQueue.main.async { self.close() }
        })
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // A display came or went: start again from rest on whichever display has the island now.
                self?.presenter?.close(animated: false)
                self?.refresh()
            }
        }
    }

    private func showFlash(_ unseen: ChatModel.Unseen?) {
        flashClear?.cancel()
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

    /// "Open Pippa" (⌘↩), "Set up my AI", or a click on "Your answer is ready".
    func openChat() {
        close()
        ChatWindow.shared.show()
    }

    /// Files dropped on the island go with the next quick question.
    func attach(_ urls: [URL]) {
        let chat = ChatModel.shared
        chat.attachments += MailDropIdentity.attachments(urls, excluding: chat.attachments)
        open(key: true, focus: true)
    }

    /// Return in the question field: a new conversation with the question and any dropped files.
    func send() {
        let chat = ChatModel.shared
        let text = chat.draft, files = chat.attachments
        guard !chat.isAnswering, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty else { return }
        chat.newConversation()
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
