import Carbon.HIToolbox

/// Comparison with macOS shortcuts (CopySymbolicHotKeys). Their modifier keys come in
/// Carbon format (cmdKey 256, shiftKey 512, optionKey 2048, controlKey 4096), not as NSEvent flags.
public enum SystemHotkeys {
    static let modifierMask = cmdKey | shiftKey | optionKey | controlKey

    /// `true`: the macOS entry (key, modifiers) occupies the same combination as `code` with `carbonModifiers`.
    public static func matches(entryCode: Int, entryModifiers: Int, code: UInt32, carbonModifiers: UInt32) -> Bool {
        UInt32(truncatingIfNeeded: entryCode) == code
            && entryModifiers & modifierMask == Int(carbonModifiers) & modifierMask
    }
}
