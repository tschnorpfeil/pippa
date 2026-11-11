/// What the island shows of an answer while it is written. The island draws the end of the text in a box three lines
/// high, anchored at the bottom: new words only extend the last line and push whole lines up. A tail cut "the last
/// 150 characters" moved its start with every word, so all three lines wrapped anew each time and the text jittered.
/// Here the start moves only every `step` characters, far above the visible lines, so what is on screen keeps its wrap.
public enum IslandTail {
    public static func window(_ text: String, keep: Int = 600, step: Int = 300) -> String {
        guard text.count > keep, step > 0 else { return text }
        let cut = ((text.count - keep) / step + 1) * step
        var start = text.index(text.startIndex, offsetBy: cut)
        // Back to the start of the word the cut falls in, so the hidden first line never starts mid-word. Searching
        // backwards keeps the window whole (a long URL after the cut would otherwise swallow it), and only text before
        // the cut is read, which no longer changes. Without a space there (one endless word), the cut stays.
        if let space = text[..<start].lastIndex(of: " ") { start = text.index(after: space) }
        return "…" + text[start...]
    }
}
