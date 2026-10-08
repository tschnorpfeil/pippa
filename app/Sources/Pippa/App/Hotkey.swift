import AppKit
import Carbon.HIToolbox
import PippaCore

/// Shortcut for "call Pippa". One default everywhere: ⌃⌥ Space (⌥ Space types a non-breaking space on German
/// keyboards, ⌃⌥ P is hard to remember). If ⌃⌥ Space is already "Select next input source",
/// Settings reports that (`HotkeyCenter.takenBySystem`).
/// Whoever has already saved another combination keeps it. A few fixed presets, no free recorder.
enum Hotkey: String, CaseIterable, Identifiable {
    case controlOptionSpace
    case optionSpace
    case controlOptionP
    case controlShiftSpace
    case off

    var id: String { rawValue }

    static var current: Hotkey {
        get { Hotkey(rawValue: UserDefaults.standard.string(forKey: "hotkey") ?? "") ?? .standard }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "hotkey") }
    }

    /// The one default.
    static let standard: Hotkey = .controlOptionSpace

    var display: String {
        switch self {
        case .optionSpace: T("⌥ Space", table: "App")
        case .controlOptionSpace: T("⌃⌥ Space", table: "App")
        case .controlShiftSpace: T("⌃⇧ Space", table: "App")
        case .controlOptionP: "⌃⌥ P"
        case .off: T("Off", table: "App")
        }
    }

    var keyCode: UInt32? {
        switch self {
        case .optionSpace, .controlOptionSpace, .controlShiftSpace: UInt32(kVK_Space)
        case .controlOptionP: UInt32(kVK_ANSI_P)
        case .off: nil
        }
    }

    var carbonModifiers: UInt32 {
        switch self {
        case .optionSpace: UInt32(optionKey)
        case .controlOptionSpace, .controlOptionP: UInt32(controlKey | optionKey)
        case .controlShiftSpace: UInt32(controlKey | shiftKey)
        case .off: 0
        }
    }

    /// For display in the menu.
    var menuKey: String {
        switch self {
        case .optionSpace, .controlOptionSpace, .controlShiftSpace: " "
        case .controlOptionP: "p"
        case .off: ""
        }
    }

    var menuModifiers: NSEvent.ModifierFlags {
        switch self {
        case .optionSpace: [.option]
        case .controlOptionSpace, .controlOptionP: [.control, .option]
        case .controlShiftSpace: [.control, .shift]
        case .off: []
        }
    }
}

/// Global shortcut via Carbon (without Accessibility permissions). ID 1: ask Pippa.
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    var onPress: (@MainActor () -> Void)?

    /// Shortcuts that currently don't take effect (taken by macOS or another app).
    private(set) var taken: Set<UInt32> = []

    /// `false`: the combination is already taken and Pippa does not react to it.
    @discardableResult func apply(_ hotkey: Hotkey) -> Bool {
        register(id: 1, code: hotkey.keyCode, modifiers: hotkey.carbonModifiers)
    }

    var mainTaken: Bool { taken.contains(1) }

    nonisolated static var takenText: String { T("Already in use. Choose a different combination.", table: "App") }

    /// Enabled macOS shortcuts (e.g. switch input source) silently win; hence check beforehand.
    static func takenBySystem(code: UInt32, modifiers: UInt32) -> Bool {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr, let entries = list?.takeRetainedValue() as? [[String: Any]] else { return false }
        return entries.contains { entry in
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let key = entry[kHISymbolicHotKeyCode as String] as? Int,
                  let mods = entry[kHISymbolicHotKeyModifiers as String] as? Int else { return false }
            return SystemHotkeys.matches(entryCode: key, entryModifiers: mods, code: code, carbonModifiers: modifiers)
        }
    }

    private func register(id: UInt32, code: UInt32?, modifiers: UInt32) -> Bool {
        if let old = refs.removeValue(forKey: id) { UnregisterEventHotKey(old) }
        taken.remove(id)
        guard let code else { return true }
        if Self.takenBySystem(code: code, modifiers: modifiers) {
            taken.insert(id)
            return false
        }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var key = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &key)
                guard key.id == 1 else { return noErr }
                // Carbon delivers on the main thread.
                MainActor.assumeIsolated { HotkeyCenter.shared.onPress?() }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(code, modifiers, EventHotKeyID(signature: OSType(0x5050_4141), id: id), GetApplicationEventTarget(), 0, &ref) // "PPAA"
        guard status == noErr, let ref else {
            // e.g. eventHotKeyExistsErr: another app already has the combination.
            taken.insert(id)
            return false
        }
        refs[id] = ref
        return true
    }
}
