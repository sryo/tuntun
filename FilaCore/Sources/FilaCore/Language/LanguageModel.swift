/// The "language" half of the Bayesian decoder: supplies the prior probability
/// of a word, optionally conditioned on preceding context.
///
/// `P(word | taps) ∝ P(taps | word) · P(word | context)`. The decoder combines a
/// ``SpatialModel`` (the first factor) with a conforming language model (the
/// second). Keeping this a protocol lets the decoder run against the quantized
/// production model, its multilingual wrapper, or a future on-device neural
/// next-word signal without changes.
public protocol LanguageModel: Sendable {
    /// The lexicon the decoder walks tap-by-tap.
    var lexicon: Lexicon { get }

    /// Log `P(word | context)`. `context` is the run of preceding words, most
    /// recent last (may be empty). Falls back to the unigram prior when no
    /// higher-order evidence exists.
    func logProbability(of word: String, given context: [String]) -> Double
}
