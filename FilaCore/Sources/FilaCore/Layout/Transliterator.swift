import Foundation

/// Maps a display word onto the key characters of a collapsed one-row layout —
/// Maps display words (with accents/apostrophes) onto the layout's key characters.
///
/// The 1D alphabet has no apostrophe and (Spanish ñ aside) no accented keys, yet
/// the vocabulary must contain "don't", "été", "für". The lexicon therefore keys
/// words by this *key sequence* while storing the display form: accents fold onto
/// their base key (é→e, ü→u, ç→c), a few letters expand (ß→ss, œ→oe), and
/// apostrophes/hyphens are silent — they consume no tap. Letters that are keys
/// themselves (Spanish ñ, Russian й) pass through before any folding.
public struct Transliterator: Sendable {
    /// Keys that exist on the layout; characters already here pass through.
    private let alphabet: Set<Character>?

    /// Pass-through: every character is its own key (test/fallback lexicons).
    public static let identity = Transliterator(alphabet: nil)

    /// Consumed without a key: straight/typographic apostrophes, hyphens, and
    /// the period of whitelisted abbreviations ("mr.", "dr.").
    private static let silent: Set<Character> = ["'", "\u{2019}", "\u{02BC}", "-", "\u{2010}", "\u{2011}", "."]

    /// Folds with no canonical decomposition (diacritic folding can't reach them).
    private static let expansions: [Character: String] = ["ß": "ss", "œ": "oe", "æ": "ae", "ø": "o"]

    private init(alphabet: Set<Character>?) {
        self.alphabet = alphabet
    }

    public init(alphabet: some Sequence<Character>) {
        self.alphabet = Set(alphabet)
    }

    /// The key characters that type `word`, or nil if the layout can't produce it.
    /// Never returns an empty sequence.
    public func keySequence(for word: String) -> String? {
        let lowered = word.lowercased()
        guard let alphabet else { return lowered.isEmpty ? nil : lowered }
        var keys = ""
        for ch in lowered {
            if alphabet.contains(ch) {
                keys.append(ch)
                continue
            }
            if Self.silent.contains(ch) { continue }
            let folded = (Self.expansions[ch] ?? String(ch))
                .folding(options: .diacriticInsensitive, locale: nil)
            guard !folded.isEmpty, folded.allSatisfy({ alphabet.contains($0) }) else { return nil }
            keys.append(folded)
        }
        return keys.isEmpty ? nil : keys
    }
}

public extension KeyboardLanguage {
    /// Display-character → key-character mapping for this language's 1D row.
    var transliterator: Transliterator { Transliterator(alphabet: collapsedSequence) }
}
