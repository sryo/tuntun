import Foundation

/// Deterministic hashing of an n-gram (ordered lowercased words) to a 64-bit key,
/// stable across model build and query.
enum NGram {
    static func key(_ words: [String]) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325 // FNV-1a offset basis
        for (i, word) in words.enumerated() {
            if i > 0 { h = (h ^ 0x1F) &* 0x0000_0100_0000_01B3 }
            for byte in word.lowercased().utf8 {
                h = (h ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
            }
        }
        return h
    }

    /// Canonical form for a context token, applied identically at model build and
    /// lookup: lowercased, with trailing sentence punctuation stripped so `word.`
    /// or `word)"` (as callers may hand us raw text fragments) still keys the
    /// same bigram as `word`.
    static func normalizeContext(_ token: String) -> String {
        var t = token.lowercased()
        while let last = t.last, trailingPunctuation.contains(last) { t.removeLast() }
        return t
    }

    private static let trailingPunctuation: Set<Character> = [
        ".", ",", "!", "?", ";", ":", ")", "\"", "'", "]",
    ]
}

/// Linear quantization of a log-probability range into a byte, matching the
/// teardown's approach (`ngramsngram` stored a quantized log-prob with a
/// dequant shift/scale).
struct LogProbQuantizer: Sendable, Equatable {
    let minLog: Double
    let maxLog: Double

    func encode(_ logProb: Double) -> UInt8 {
        guard maxLog > minLog else { return 0 }
        let clamped = Swift.min(maxLog, Swift.max(minLog, logProb))
        let t = (clamped - minLog) / (maxLog - minLog)
        return UInt8((t * 255).rounded())
    }

    func decode(_ byte: UInt8) -> Double {
        guard maxLog > minLog else { return minLog }
        return minLog + (Double(byte) / 255.0) * (maxLog - minLog)
    }
}

/// The production language model: a vocabulary trie (for the decoder to walk) plus
/// a compact, memory-mappable bigram store — a ``BloomFilter`` for membership and
/// a ``BloomierFilter`` of quantized log-probs for the value. This is the Swift
/// analogue of Fila's `reference.db` vocab + `ngramsbits`/`ngramsbloom` model.
public struct QuantizedNGramModel: LanguageModel {
    public let lexicon: Lexicon
    /// The language this bundle was built for (drives transliteration on reload);
    /// nil for ad-hoc in-memory models.
    public let language: KeyboardLanguage?
    let membership: BloomFilter
    let values: BloomierFilter
    let quantizer: LogProbQuantizer
    /// Weight on the bigram estimate vs. the unigram backoff.
    let lambda: Double

    /// Cap on how far a decoded bigram may exceed the word's unigram prior, in
    /// nats. The membership Bloom filter passes false positives at p ≈ 0.001, and
    /// for those the Bloomier value is an *arbitrary* byte — potentially decoding
    /// near `maxLog` and boosting a wrong word by orders of magnitude. Capping the
    /// boost at e⁸ ≈ 3000× keeps almost all genuine bigram signal while bounding
    /// the damage a false positive can do.
    static let maxBigramBoost = 8.0

    init(lexicon: Lexicon, language: KeyboardLanguage? = nil,
         membership: BloomFilter, values: BloomierFilter,
         quantizer: LogProbQuantizer, lambda: Double = 0.7) {
        self.lexicon = lexicon
        self.language = language
        self.membership = membership
        self.values = values
        self.quantizer = quantizer
        self.lambda = lambda
    }

    public func logProbability(of word: String, given context: [String]) -> Double {
        let unigram = lexicon.logPrior(of: word) ?? -.infinity
        // A membership false positive must never resurrect an out-of-vocabulary
        // word, and the boost cap below needs a finite baseline.
        guard unigram > -.infinity else { return -.infinity }
        guard let prevRaw = context.last else { return unigram }
        let prev = NGram.normalizeContext(prevRaw)
        guard !prev.isEmpty else { return unigram }
        let key = NGram.key([prev, word.lowercased()])
        guard membership.contains(key) else { return unigram }
        let bigram = min(quantizer.decode(values.lookup(key)), unigram + Self.maxBigramBoost)
        // Interpolate in probability space (Jelinek–Mercer), back to log space.
        let mixed = lambda * exp(bigram) + (1 - lambda) * exp(unigram)
        return mixed > 0 ? log(mixed) : -.infinity
    }
}
