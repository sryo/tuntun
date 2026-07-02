/// Pure text-editing rules for spacing/punctuation: auto-space, smart-space
/// re-flow, and double-space→period. Kept side-effect-free so the host
/// controller can apply them through its `TextSink` and they can be unit-tested.
public enum TypingBehavior {
    /// Punctuation that should hug the preceding word (no space before it).
    public static let spacingPunctuation: Set<Character> = [".", ",", "?", "!", ";", ":"]

    /// Sentence-terminating punctuation (a trailing space reads naturally after).
    public static let terminators: Set<Character> = [".", "?", "!"]

    /// A second space typed right after a word becomes ". " (iOS-style).
    /// True when `before` ends in exactly one space preceded by a word character.
    public static func shouldConvertDoubleSpaceToPeriod(_ before: String) -> Bool {
        guard before.hasSuffix(" ") else { return false }
        let trimmed = before.dropLast()
        guard let prev = trimmed.last else { return false }
        // Don't double-punctuate ("word. " + space) or convert after another space.
        return prev.isLetter || prev.isNumber
    }

    /// When inserting spacing punctuation right after a space, the space should
    /// move to *after* the punctuation ("hello ." → "hello. "). Returns the text to
    /// insert *after* deleting the preceding space, or nil to insert `ch` verbatim.
    public static func smartPunctuation(_ ch: Character, before: String) -> String? {
        guard spacingPunctuation.contains(ch), before.hasSuffix(" ") else { return nil }
        let trimmed = before.dropLast()
        guard let prev = trimmed.last, prev.isLetter || prev.isNumber else { return nil }
        return terminators.contains(ch) ? "\(ch) " : String(ch)
    }
}
