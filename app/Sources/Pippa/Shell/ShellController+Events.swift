import AppKit
import PippaCore

// Shell events: pass clicks outside through or collapse, drop files,
// keyboard (Esc, ⌘↩, typing during deformation). State lives in ShellController.
extension ShellController {
    // MARK: Pass clicks through

    func updateMouseIgnoring() {
        guard stageVisible else {
            if !panel.ignoresMouseEvents { panel.ignoresMouseEvents = true }
            return
        }
        let mouse = NSEvent.mouseLocation
        // Also accept clicks over the cards behind the pill (items lying on Pippa).
        let inside = shellScreenRect.contains(mouse) || (stackScreenRect?.contains(mouse) ?? false)
        let ignore = !inside && !isDraggingPill
        if panel.ignoresMouseEvents != ignore { panel.ignoresMouseEvents = ignore }
    }

    // MARK: Dropping

    var canDrop: Bool {
        // Expanded conversation receives attachments even during a preview or
        // active request; AppModel queues them visibly until the request ends.
        if model.mode.isConversation { return true }
        if model.busy { return false }
        switch model.mode {
        case .working, .sortSheet: return false
        default: return true
        }
    }

    func draggingEntered() -> NSDragOperation {
        guard canDrop else { return [] }
        model.dragEntered()
        return .copy
    }

    func draggingExited() {
        model.dragExited()
        if !dragAnnounced { model.dragEnded() }
    }

    func performDrop(_ pb: NSPasteboard) -> Bool {
        guard canDrop else { return false }
        dragAnnounced = false
        return receive(pb, imageName: "Bild.png")
    }

    /// ⌘V in the input: copied files or a picture are attached exactly like a drop; text pastes as usual.
    /// Returns false when the normal text paste should happen. `pb` is injectable for checks.
    func pasteAsAttachment(_ pb: NSPasteboard = .general, requireFocus: Bool = true) -> Bool {
        guard canDrop, !requireFocus || (panel.isKeyWindow && panel.firstResponder is NSTextView) else { return false }
        let decision = PasteDecision.decide(
            hasFileURLs: pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]),
            hasImage: pb.availableType(from: [.png, .tiff]) != nil,
            plainText: pb.string(forType: .string))
        guard decision != .text else { return false }
        return receive(pb, imageName: T("Clipboard image %@.png", table: "App", PasteDecision.timeStamp(Date())))
    }

    private func receive(_ pb: NSPasteboard, imageName: String) -> Bool {
        DropReader.read(pb, imageName: imageName) { [weak self] result in
            guard let self else { return }
            if let result {
                self.model.receive(result.payload, items: result.items)
            } else {
                self.model.show(.message(title: T("I can’t do anything with that", table: "App"), body: T("Drag files, folders, text or a link onto me.", table: "App"), isError: false))
            }
        }
        return true
    }

    /// Detects a drag anywhere on screen and turns the pill into a drop target in advance.
    func startDragPoll() {
        dragPoll?.invalidate()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollDrag() }
        }
        timer.tolerance = 0.015
        // Keep the fallback alive in AppKit's mouse-tracking loop too.
        RunLoop.main.add(timer, forMode: .common)
        dragPoll = timer
    }

    private func pollDrag() {
        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        let board = NSPasteboard(name: .drag)
        let count = board.changeCount
        // Inspect advertised formats only. Reading contents or file promises here
        // would do work for a drag the person may be taking somewhere else.
        updateDragPresence(pressed: pressed, changeCount: count,
                           hasSupportedType: pressed && !dragAnnounced && count != dragBaseline
                               && board.availableType(from: DropReader.types) != nil)
    }

    /// Shared by native events and the tracking-mode timer. No pointer proximity
    /// test: the cold target announces availability anywhere on the desktop.
    func updateDragPresence(pressed: Bool, changeCount count: Int, hasSupportedType: Bool) {
        if !pressed {
            if dragAnnounced {
                dragAnnounced = false
                model.dragEnded()
            }
            dragBaseline = count
            return
        }
        updateMouseIgnoring()
        panel.releaseEditorDrops()
        // If Pippa is dragging an item out itself, that is not a drop on Pippa.
        guard model.pillVisible, stageVisible, canDrop, !isDraggingPill, !takingOut else {
            if dragAnnounced {
                dragAnnounced = false
                model.dragEnded()
            }
            dragBaseline = count
            return
        }
        guard !dragAnnounced, count != dragBaseline, hasSupportedType else { return }
        if case .pill = model.mode {
            dragAnnounced = true
            model.dragAnnounced()
        }
    }

    // MARK: Events

    func installMonitors() {
        // Scripted QA snapshots run beside the installed Pippa: they never watch clicks or drags in other apps.
        let watchesOtherApps = DevSnapshot.directory == nil
        // The conversation stays open when switching to another app.
        // Intercept clicks only where the shell is.
        if watchesOtherApps, let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp], handler: { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated {
                if type == .mouseMoved { self?.updateMouseIgnoring() }
                else if type == .leftMouseUp {
                    // Let AppKit deliver the drop before shrinking its destination.
                    DispatchQueue.main.async { [weak self] in self?.pollDrag() }
                } else { self?.pollDrag() }
            }
        }) { monitors.append(m) }
        // A click in another app collapses the conversation, but only on release: pressing on a file in the
        // Finder may start a drag toward here, and the drop target must not disappear meanwhile.
        if watchesOtherApps, let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown], handler: { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated {
                guard let self else { return }
                // A scripted snapshot must not collapse because the developer clicks
                // in another app while the fixture is running. Production is unchanged.
                if DevSnapshot.directory != nil,
                   ["attachments", "mailcards", "dragtarget", "conversationresume", "calendar", "thoughtline"].contains(DevEnvironment.value("PIPPA_SNAPSHOT_ONLY") ?? "") { return }
                if type == .leftMouseDown { self.outsideDragBaseline = NSPasteboard(name: .drag).changeCount; return }
                let dragged = type == .leftMouseUp && NSPasteboard(name: .drag).changeCount != self.outsideDragBaseline
                if self.collapsesOnOutsideClick(dragged: dragged) { self.model.collapse() }
            }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp], handler: { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated {
                if type == .mouseMoved { self?.updateMouseIgnoring() }
                else if type == .leftMouseUp {
                    // Let AppKit deliver the drop before shrinking its destination.
                    DispatchQueue.main.async { [weak self] in self?.pollDrag() }
                } else { self?.pollDrag() }
            }
            return event
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let code = event.keyCode
            let window = event.window.map(ObjectIdentifier.init)
            let chars = event.characters ?? ""
            let plain = event.modifierFlags.intersection([.command, .control]).isEmpty
            let handled: Bool = MainActor.assumeIsolated {
                guard let self, window == ObjectIdentifier(self.panel) else { return false }
                // ⌘↩ applies an open preview, but only with an empty input field: someone typing a
                // follow-up to the preview and submitting with ⌘↩ wants to send, not organize.
                if (code == 36 || code == 76),
                   event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
                   self.model.mode.isConversation {
                    if !event.isARepeat {
                        let typed = self.model.query
                        if typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self.model.confirmPreview() } else { self.model.route(typed) }
                    }
                    return true
                }
                if code == 53 { self.model.escape(); return true }  // Esc
                return plain && self.bufferTyping(chars)
            }
            return handled ? nil : event
        }) { monitors.append(m) }
    }

    /// Collapse after a click outside, except while dragging. Also not while the system prompt
    /// for the calendar is open: the click on "Allow" is outside, the answer should appear in the open conversation.
    func collapsesOnOutsideClick(dragged: Bool) -> Bool {
        model.isExpanded && !isDraggingPill && !dragged && !dragAnnounced
            && !model.awaitingSystemPrompt && !shellScreenRect.contains(NSEvent.mouseLocation)
    }

    /// Typing before the field has focus (shell still deforming): nothing gets lost.
    /// Only during deformation and only while no field and no button has focus:
    /// otherwise the key belongs to the focused element (space presses the button, text goes into the field).
    private func bufferTyping(_ chars: String) -> Bool {
        let responder = panel.firstResponder
        guard morphing, (model.mode.isConversation || model.mode.key == "resume"), !chars.isEmpty,
              chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }),
              !(responder is NSText), !(responder is NSControl) else { return false }
        model.query += chars
        return true
    }
}
