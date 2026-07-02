import Foundation

/// A character trie over the vocabulary, doubling as the unigram store.
///
/// The decoder walks this trie tap-by-tap: only paths that spell real words
/// survive, which is what lets an imprecise one-row tap sequence resolve to a
/// valid word. The trie is keyed by each word's *transliterated key sequence*
/// (see ``Transliterator``), so "don't" lives under d-o-n-t and "été" under
/// e-t-e; a node stores every display form that shares its key sequence, each
/// with its own unigram log-prior ("well" and "we'll" are siblings). In
/// production the trie is built offline, serialized, and memory-mapped from the
/// App Group container to stay under the ~48 MB extension ceiling; this
/// in-memory form is the build and test representation.
public final class Lexicon: @unchecked Sendable {
    struct Entry {
        let word: String
        /// Unigram log-probability (natural log).
        var logPrior: Double
    }

    final class Node {
        /// Child edges as a compact array, not a dictionary: with a 60–100k-word
        /// vocabulary resident in the extension, per-node dictionary storage is
        /// the dominant memory cost, and fan-out is bounded by the alphabet so a
        /// linear scan stays cheap (the decoder iterates all children anyway).
        var children: [(letter: Character, node: Node)] = []
        /// Display forms whose key sequence ends at this node.
        var entries: [Entry] = []

        func child(_ letter: Character) -> Node? {
            children.first { $0.letter == letter }?.node
        }
    }

    let root = Node()
    public let transliterator: Transliterator

    public init(transliterator: Transliterator = .identity) {
        self.transliterator = transliterator
    }

    /// Build from a `[word: count]` frequency table (add-one smoothed unigram).
    public convenience init(frequencies: [String: Int], transliterator: Transliterator = .identity) {
        self.init(transliterator: transliterator)
        let total = Double(frequencies.values.reduce(0, +))
        let vocab = Double(frequencies.count)
        let denom = total + vocab // add-one smoothing normalizer
        for (word, count) in frequencies {
            let logPrior = log((Double(count) + 1) / denom)
            insert(word: word, logPrior: logPrior)
        }
    }

    /// Insert (or reprice) a display word under its key sequence. Words the
    /// layout can't produce are skipped.
    public func insert(word: String, logPrior: Double) {
        let display = word.lowercased()
        guard let key = transliterator.keySequence(for: display) else { return }
        var node = root
        for ch in key {
            if let next = node.child(ch) {
                node = next
            } else {
                let next = Node()
                node.children.append((ch, next))
                node = next
            }
        }
        if let i = node.entries.firstIndex(where: { $0.word == display }) {
            node.entries[i].logPrior = logPrior
        } else {
            node.entries.append(Entry(word: display, logPrior: logPrior))
        }
    }

    /// Remove a display word. Interior nodes are left in place (cheap, and the
    /// decoder ignores entry-less nodes).
    @discardableResult
    public func remove(word: String) -> Bool {
        let display = word.lowercased()
        guard let node = keyNode(for: display),
              let i = node.entries.firstIndex(where: { $0.word == display }) else { return false }
        node.entries.remove(at: i)
        return true
    }

    public func contains(_ word: String) -> Bool {
        entry(for: word) != nil
    }

    /// Unigram log-prior for a word, or nil if it isn't in the vocabulary.
    public func logPrior(of word: String) -> Double? {
        entry(for: word)?.logPrior
    }

    /// All (word, unigram log-prior) pairs, for model serialization.
    public func terminals() -> [(word: String, logPrior: Double)] {
        var out: [(String, Double)] = []
        func walk(_ node: Node) {
            for entry in node.entries { out.append((entry.word, entry.logPrior)) }
            for (_, child) in node.children { walk(child) }
        }
        walk(root)
        return out
    }

    private func entry(for word: String) -> Entry? {
        let display = word.lowercased()
        guard let node = keyNode(for: display) else { return nil }
        return node.entries.first { $0.word == display }
    }

    private func keyNode(for display: String) -> Node? {
        guard let key = transliterator.keySequence(for: display) else { return nil }
        var node = root
        for ch in key {
            guard let next = node.child(ch) else { return nil }
            node = next
        }
        return node
    }
}
