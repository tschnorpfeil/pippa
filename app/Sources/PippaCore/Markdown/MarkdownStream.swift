import Foundation

/// Markdown blocks for a text that grows at its end, as an answer does while it streams in. Each update reads only the
/// new characters: finished lines go through the parser once, and blocks they close move to `closed` for good. Only
/// the block still being written and the line still being typed are worked out again (`open`). A text that does not
/// continue the previous one starts over.
public struct MarkdownStream: Sendable {
    /// Blocks no later text can change.
    public private(set) var closed: [MarkdownBlock] = []
    /// The blocks after `closed`, from the open block and the unfinished last line; rebuilt on every update.
    public private(set) var open: [MarkdownBlock] = []
    /// Times the text did not continue the previous one and parsing started over.
    public private(set) var restarts = 0
    /// Characters read to find line breaks and to classify lines, over all updates. A finished line is read once; the
    /// unfinished last line is classified by its first few characters (its markers), the rest is copied, not read.
    public private(set) var scanned = 0

    public var blocks: [MarkdownBlock] { closed + open }

    private var text = ""
    /// UTF-8 offsets: how far line breaks were searched, and where the unfinished last line starts.
    private var searched = 0
    private var partialStart = 0
    /// Finished lines not taken in yet: a possible table head waits for the line under it.
    private var waiting: [Range<Int>] = []
    private var state = MarkdownLineState()

    /// How many characters of the unfinished line decide what it is ("## ", "```", "12. ", "|").
    private static let peek = 16

    public init() {}

    public mutating func update(_ newText: String) {
        if !Self.continues(newText, text, count: searched) {
            let (restarts, scanned) = (self.restarts + 1, self.scanned)
            self = MarkdownStream()
            self.restarts = restarts
            self.scanned = scanned
        } else if newText.utf8.count == searched, searched > 0 {
            return
        }
        text = newText
        let utf8 = newText.utf8
        var index = utf8.index(utf8.startIndex, offsetBy: searched)
        var offset = searched
        while index < utf8.endIndex {
            if utf8[index] == 0x0A {
                waiting.append(partialStart..<offset)
                partialStart = offset + 1
            }
            utf8.formIndex(after: &index)
            offset += 1
        }
        scanned += offset - searched
        searched = offset

        // Finished lines go in for good, unless one needs to see a line that is still being written.
        var taken = 0
        while taken < waiting.count {
            let line = slice(waiting[taken])
            let hasNext = taken + 1 < waiting.count
            if state.needsNextLine(line) && !hasNext { break }
            let next = hasNext ? slice(waiting[taken + 1]) : nil
            scanned += line.utf8.count
            if state.take(line, next: next, into: &closed), let next {
                scanned += next.utf8.count
                taken += 2
            } else {
                taken += 1
            }
        }
        waiting.removeFirst(taken)

        // The rest on a copy: what the text says right now, without committing to it.
        var tail = state
        var lines = waiting.map(slice)
        let partial = slice(partialStart..<searched)
        lines.append(partial)
        scanned += waiting.reduce(0) { $0 + $1.count } + min(partial.utf8.count, MarkdownLineState.trimmed(partial).hasPrefix("|") ? .max : Self.peek)
        open = []
        var line = 0
        while line < lines.count {
            let next = line + 1 < lines.count ? lines[line + 1] : nil
            line += tail.take(lines[line], next: next, into: &open) ? 2 : 1
        }
        tail.finish(into: &open)
    }

    private func slice(_ range: Range<Int>) -> Substring {
        let utf8 = text.utf8
        let start = utf8.index(utf8.startIndex, offsetBy: range.lowerBound)
        let end = utf8.index(start, offsetBy: range.count)
        return text[start..<end]
    }

    /// `new` starts with the first `count` UTF-8 bytes of `old`.
    private static func continues(_ new: String, _ old: String, count: Int) -> Bool {
        guard count > 0 else { return true }
        guard new.utf8.count >= count, old.utf8.count >= count else { return false }
        let fast = new.utf8.withContiguousStorageIfAvailable { a in
            old.utf8.withContiguousStorageIfAvailable { b in memcmp(a.baseAddress!, b.baseAddress!, count) == 0 }
        }
        if let fast, let result = fast { return result }
        return new.utf8.prefix(count).elementsEqual(old.utf8.prefix(count))
    }
}
