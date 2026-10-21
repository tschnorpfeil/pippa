import Foundation

/// Retrying a blocked answer must not silently substitute changed source context. This uses the same metadata
/// fingerprints as file previews; it does not establish content identity against deliberately preserved timestamps.
public struct ConversationRetryGuard: Sendable {
    private let files: [URL]
    private let focused: [URL]
    private let selectedText: String?
    private let fingerprints: [FileFingerprint?]

    public init(context: ConversationContext?) {
        files = context?.files.map(\.standardizedFileURL) ?? []
        focused = context?.focusedFiles?.map(\.standardizedFileURL) ?? []
        selectedText = context?.selectedText
        fingerprints = files.map(Self.regularFileFingerprint)
    }

    public func matches(context: ConversationContext?) -> Bool {
        guard files == (context?.files.map(\.standardizedFileURL) ?? []),
              focused == (context?.focusedFiles?.map(\.standardizedFileURL) ?? []),
              selectedText == context?.selectedText else { return false }
        return zip(files, fingerprints).allSatisfy { file, original in
            original?.matches(Self.regularFileFingerprint(file)) == true
        }
    }

    /// A folder's metadata does not cover its children; a symlink's metadata does not cover its target.
    private static func regularFileFingerprint(_ url: URL) -> FileFingerprint? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return FileFingerprint.of(url)
    }
}
