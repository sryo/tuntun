import Foundation

/// Deterministic auto-capitalization applied as a *presentation* transform over
/// the decoder's (always-lowercase) output.
///
/// The lexicon and spatial model are lowercase-only, so casing never enters the
/// Bayesian search — it is decided at render/commit time from the text preceding
/// the word and the active language. Two rules, matching the platform keyboards:
///   • **Sentence start** — capitalize the first letter when the caret sits at the
///     start of the document or just after a sentence terminator (`.`/`!`/`?`,
///     optionally through a closing quote/bracket) or a line break.
///   • **English "I"** — the standalone pronoun `i` and its contractions (`i'm`,
///     `i'll`, …) always uppercase, regardless of position.
public enum Autocapitalization {

    /// Whether `textBeforeCursor` (the committed text up to the caret, *excluding*
    /// any in-progress word) is at a sentence start.
    public static func isSentenceStart(_ textBeforeCursor: String?) -> Bool {
        guard var text = textBeforeCursor?[...] else { return true }
        // Ignore spaces/tabs immediately before the caret (a pending word gap).
        while let last = text.last, last == " " || last == "\t" { text = text.dropLast() }
        guard let last = text.last else { return true } // start of document
        if last == "\n" { return true }                 // start of a new line
        // Allow a closing quote/bracket to sit between the terminator and the gap.
        var terminator = last
        if "\")]}'’”".contains(terminator) { terminator = text.dropLast().last ?? " " }
        return ".!?".contains(terminator)
    }

    /// Case a decoded lowercase `word` for display/commit.
    public static func cased(_ word: String,
                             sentenceStart: Bool,
                             english: Bool,
                             locale: Locale) -> String {
        guard let first = word.first else { return word }
        if english {
            if word == "i" { return "I" }
            if first == "i", word.count > 1 {
                let second = word[word.index(after: word.startIndex)]
                if second == "'" || second == "’" { return uppercaseFirst(word, locale) }
            }
        }
        return sentenceStart ? uppercaseFirst(word, locale) : word
    }

    private static func uppercaseFirst(_ word: String, _ locale: Locale) -> String {
        word.prefix(1).uppercased(with: locale) + word.dropFirst()
    }
}
