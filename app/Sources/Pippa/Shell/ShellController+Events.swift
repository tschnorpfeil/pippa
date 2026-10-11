import AppKit
import PippaCore

// Shell events: pass clicks outside through, drop files,
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
        // A card Pippa is handing out is not a drop on Pippa, even when it is let go over the pill.
        if takingOut { return false }
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
        guard canDrop else {
            // Busy at the pill: say why nothing happens instead of staying silent.
            if !takingOut, model.mode.key == "pill", !model.toastShowing {
                model.toasts?.show(title: T("I’m still working", table: "App"),
                                   detail: T("Drop it on me again once I’m done.", table: "App"), buttons: [], log: false)
            }
            return []
        }
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
        if DropReader.isPromise(pb) {
            // Promised files (a mail from Mail) take a moment: the pill leaves "Let Go" and works until they are here.
            model.dragEnded()
            model.receivingStarted { [weak self] in self?.showNotReceived() }
            return receive(pb, imageName: "", promised: true)
        }
        return receive(pb, imageName: T("Dropped image %@.png", table: "App", PasteDecision.timeStamp(Date())))
    }

    private func showNotReceived() {
        model.show(.message(title: T("That didn’t reach me", table: "App"),
                            body: T("Drag it onto me once more.", table: "App"), isError: false))
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

    private func receive(_ pb: NSPasteboard, imageName: String, promised: Bool = false) -> Bool {
        DropReader.read(pb, imageName: imageName) { [weak self] result in
            guard let self else { return }
            if promised { self.model.receivingEnded() }
            if let result {
                self.model.receive(result.payload, items: result.items)
            } else if promised {
                // The other app didn't deliver: the thing was fine, getting it failed.
                self.showNotReceived()
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
        // The conversation stays open when switching to or clicking in another app (copying text there, a look
        // elsewhere): only X, Esc or the shortcut close it.
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
