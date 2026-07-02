import Testing
import Foundation
@testable import FilaCore

/// Test scaffolding: an exact (unquantized) in-memory unigram+bigram model.
/// Stands in for the shipped ``QuantizedNGramModel`` with the same
/// Jelinek–Mercer interpolation and context canonicalization, but no
/// Bloom/Bloomier machinery, so decoder tests stay small and exact.
private struct NGramLanguageModel: LanguageModel {
    let lexicon: Lexicon
    /// `bigrams[prev][word] = count`.
    private let bigrams: [String: [String: Int]]
    private let bigramContextTotals: [String: Int]
    /// Weight on the bigram estimate vs. the unigram backoff.
    private let lambda: Double

    init(lexicon: Lexicon,
         bigrams: [String: [String: Int]] = [:],
         lambda: Double = 0.7) {
        self.lexicon = lexicon
        // Same context canonicalization as lookup, so build and query agree.
        var normalized: [String: [String: Int]] = [:]
        for (prevRaw, following) in bigrams {
            let prev = NGram.normalizeContext(prevRaw)
            guard !prev.isEmpty else { continue }
            for (word, count) in following {
                normalized[prev, default: [:]][word.lowercased(), default: 0] += count
            }
        }
        self.bigrams = normalized
        self.bigramContextTotals = normalized.mapValues { $0.values.reduce(0, +) }
        self.lambda = lambda
    }

    func logProbability(of word: String, given context: [String]) -> Double {
        let unigram = lexicon.logPrior(of: word) ?? -.infinity
        guard let prev = context.last.map({ NGram.normalizeContext($0) }),
              let following = bigrams[prev],
              let total = bigramContextTotals[prev], total > 0 else {
            return unigram
        }
        let bigramProb = Double(following[word.lowercased()] ?? 0) / Double(total)
        // Interpolate in probability space, then return to log space.
        let mixed = lambda * bigramProb + (1 - lambda) * exp(unigram)
        return mixed > 0 ? log(mixed) : -.infinity
    }
}

/// A small but realistic frequency table so the language model has meaningful priors.
private let sampleFrequencies: [String: Int] = [
    "the": 2300, "be": 1200, "to": 1100, "of": 1000, "and": 950, "a": 900,
    "in": 850, "that": 600, "have": 560, "it": 550, "for": 520, "not": 500,
    "on": 480, "with": 470, "he": 460, "as": 450, "you": 440, "do": 430,
    "at": 420, "this": 410, "but": 400, "his": 390, "by": 380, "from": 370,
    "hello": 300, "world": 290, "help": 120, "held": 40, "gello": 3,
    "there": 260, "their": 250, "type": 200, "typing": 150, "keyboard": 90,
    "tuntun": 30, "quick": 80, "brown": 70, "fox": 60, "jumps": 25,
]

/// The exact geometry the shipping keyboard decodes against (evenly-spaced,
/// column-major 1D), so the tests exercise the production path — not a
/// staggered layout that never runs. See `KeyboardEngine.layout = language.layout1D`.
private let productionLayout = KeyboardLanguage.english.layout1D

private func makeDecoder(maxEdits: Int = 2) -> Decoder {
    let lexicon = Lexicon(frequencies: sampleFrequencies)
    let lm = NGramLanguageModel(lexicon: lexicon, bigrams: ["hello": ["world": 50], "the": ["quick": 20]])
    let spatial = SpatialModel(layout: productionLayout)
    return Decoder(spatial: spatial, language: lm, maxEdits: maxEdits)
}

/// Perfect taps land exactly on each letter's centre.
private func perfectTaps(for word: String, layout: KeyboardLayout = productionLayout) -> [Double] {
    word.compactMap { layout.geometry(for: $0)?.normalizedX }
}

/// Simulate an imprecise finger: deterministic offset per position (no RNG,
/// so the test is reproducible).
private func noisyTaps(for word: String, jitter: Double, layout: KeyboardLayout = productionLayout) -> [Double] {
    let centres = perfectTaps(for: word, layout: layout)
    return centres.enumerated().map { i, x in
        let sign = (i % 2 == 0) ? 1.0 : -1.0
        return min(1.0, max(0.0, x + sign * jitter))
    }
}

@Test func layoutMapsEveryLetter() {
    let layout = productionLayout
    #expect(layout.keys.count == 26)
    for ch in "abcdefghijklmnopqrstuvwxyz" {
        #expect(layout.geometry(for: ch) != nil)
    }
    // Column-mates are adjacent in the column-major sequence, so they share a
    // near-identical x — that's the deliberate source of tap ambiguity.
    let q = layout.geometry(for: "q")!.normalizedX
    let a = layout.geometry(for: "a")!.normalizedX
    #expect(abs(q - a) < 0.06)
}

@Test func decodesPerfectTaps() {
    let decoder = makeDecoder()
    let candidates = decoder.decode(taps: perfectTaps(for: "hello"))
    #expect(candidates.first?.word == "hello")
}

@Test func decodesSeveralWords() {
    let decoder = makeDecoder()
    for word in ["world", "keyboard", "typing", "quick", "brown"] {
        let candidates = decoder.decode(taps: perfectTaps(for: word))
        #expect(candidates.first?.word == word, "expected \(word), got \(candidates.first?.word ?? "nil")")
    }
}

@Test func recoversFromImpreciseTaps() {
    let decoder = makeDecoder()
    // Jitter smaller than half a key spacing (~0.05 normalized) should still resolve.
    let candidates = decoder.decode(taps: noisyTaps(for: "hello", jitter: 0.03))
    #expect(candidates.first?.word == "hello")
}

@Test func languagePriorBreaksSpatialTies() {
    // "hello" and "gello" are near-identical spatially (h/g are x-neighbours),
    // but the language model strongly prefers the real, frequent word.
    let decoder = makeDecoder()
    let candidates = decoder.decode(taps: perfectTaps(for: "hello"))
    #expect(candidates.first?.word == "hello")
    if let gello = candidates.first(where: { $0.word == "gello" }) {
        #expect(candidates.first!.score > gello.score)
    }
}

@Test func contextRaisesBigramContinuation() {
    let decoder = makeDecoder()
    let taps = perfectTaps(for: "world")
    let withContext = decoder.decode(taps: taps, context: ["hello"])
    #expect(withContext.first?.word == "world")
}

@Test func spatialModelPersonalizationShiftsMean() {
    var spatial = SpatialModel(layout: productionLayout)
    let before = spatial.logLikelihood(tapX: 0.02, for: "q")
    // User consistently taps "q" further left than the nominal centre.
    for _ in 0..<20 { spatial.observe(tapX: 0.02, for: "q") }
    let after = spatial.logLikelihood(tapX: 0.02, for: "q")
    #expect(after > before)
}

@Test func forcedLetterPinsThatPosition() {
    let decoder = makeDecoder()
    // Taps spell "hello", but the user pinned position 0 to 'g' via the magnifier.
    let taps = perfectTaps(for: "hello")
    let candidates = decoder.decode(taps: taps, forced: [0: "g"])
    #expect(candidates.first?.word == "gello")
    // Every returned candidate must honor the pin.
    for c in candidates { #expect(c.word.first == "g") }
}

@Test func emptyForcedMatchesUnforced() {
    let decoder = makeDecoder()
    let taps = perfectTaps(for: "help")
    let a = decoder.decode(taps: taps).map(\.word)
    let b = decoder.decode(taps: taps, forced: [:]).map(\.word)
    #expect(a == b)
}

@Test func returnsRankedAlternatives() {
    let decoder = makeDecoder()
    let candidates = decoder.decode(taps: perfectTaps(for: "help"), maxCandidates: 5)
    #expect(candidates.count >= 1)
    // Scores must be monotonically non-increasing.
    for i in 1..<candidates.count {
        #expect(candidates[i - 1].score >= candidates[i].score)
    }
}

// MARK: - Transliterated vocabulary

private func makeTransliteratedDecoder(_ frequencies: [String: Int],
                                       language: KeyboardLanguage = .english) -> Decoder {
    let lexicon = Lexicon(frequencies: frequencies, transliterator: language.transliterator)
    return Decoder(spatial: SpatialModel(layout: language.layout1D),
                   language: NGramLanguageModel(lexicon: lexicon))
}

@Test func apostropheWordDecodesFromPlainTaps() {
    let decoder = makeTransliteratedDecoder(["don't": 900, "dont": 20, "done": 300])
    let candidates = decoder.decode(taps: perfectTaps(for: "dont"))
    let words = candidates.map(\.word)
    #expect(words.contains("don't"))
    #expect(words.contains("dont"))
    // The far more frequent contraction outranks the bare form.
    #expect(words.firstIndex(of: "don't")! < words.firstIndex(of: "dont")!)
}

@Test func accentedWordDecodesFromPlainTaps() {
    let layout = KeyboardLanguage.french.layout1D
    let decoder = makeTransliteratedDecoder(["été": 500, "avec": 300], language: .french)
    let taps = "ete".compactMap { layout.geometry(for: $0)?.normalizedX }
    #expect(decoder.decode(taps: taps).first?.word == "été")
}

@Test func sharedKeySequenceSurfacesEveryDisplayForm() {
    // "well" and "we'll" collapse onto the same key path; both must surface,
    // ranked by their own priors.
    let decoder = makeTransliteratedDecoder(["well": 1000, "we'll": 200, "west": 100])
    let candidates = decoder.decode(taps: perfectTaps(for: "well"))
    let words = candidates.map(\.word)
    #expect(words.contains("well"))
    #expect(words.contains("we'll"))
    #expect(words.firstIndex(of: "well")! < words.firstIndex(of: "we'll")!)
}

@Test func forcedLetterWorksWithTransliteratedEntries() {
    let decoder = makeTransliteratedDecoder(["don't": 900, "font": 100])
    let taps = perfectTaps(for: "dont")
    let candidates = decoder.decode(taps: taps, forced: [0: "f"])
    #expect(candidates.first?.word == "font")
    for c in candidates { #expect(c.word.first == "f") }
}

// MARK: - Determinism

@Test func decodeIsDeterministicAcrossRepeatsAndBuildOrders() {
    // Identical vocabularies inserted in opposite orders produce tries whose
    // children/entry arrays differ; with exact score ties ("well"/"we'll" share
    // a key sequence and a prior), only a stable tie-break keeps the ranked
    // output identical.
    let words: [(String, Double)] = [
        ("well", -4.0), ("we'll", -4.0), ("wells", -6.0), ("welt", -6.0),
        ("hello", -3.0), ("help", -5.0), ("held", -5.0), ("helm", -5.0),
        ("hell", -5.5), ("he'll", -5.5),
    ]
    func makeOrderedDecoder(_ order: [(String, Double)]) -> Decoder {
        let lexicon = Lexicon(transliterator: KeyboardLanguage.english.transliterator)
        for (word, prior) in order { lexicon.insert(word: word, logPrior: prior) }
        return Decoder(spatial: SpatialModel(layout: productionLayout),
                       language: NGramLanguageModel(lexicon: lexicon))
    }
    let a = makeOrderedDecoder(words)
    let b = makeOrderedDecoder(words.reversed())
    for target in ["well", "hell", "help", "hello"] {
        let taps = perfectTaps(for: target)
        let first = a.decode(taps: taps, maxCandidates: 8)
        #expect(first == a.decode(taps: taps, maxCandidates: 8), "repeat decode differs for \(target)")
        #expect(first == b.decode(taps: taps, maxCandidates: 8), "rebuilt-trie decode differs for \(target)")
    }
    // Exact ties resolve by word order, not construction order.
    let tied = a.decode(taps: perfectTaps(for: "well"), maxCandidates: 8).map(\.word)
    #expect(tied.firstIndex(of: "we'll")! < tied.firstIndex(of: "well")!)
}

// MARK: - Edits

@Test func exactDecodeReportsZeroEdits() {
    let decoder = makeDecoder()
    let hello = decoder.decode(taps: perfectTaps(for: "hello")).first { $0.word == "hello" }
    #expect(hello?.edits == 0)
}

@Test func omittedDoubleLetterStillDecodes() {
    // "helo" (double letter typed once) must recover "hello" via one omission,
    // and the candidate must report that edit so spatial learning can skip it.
    let decoder = makeDecoder()
    let candidates = decoder.decode(taps: perfectTaps(for: "helo"))
    let hello = candidates.first { $0.word == "hello" }
    #expect(hello != nil)
    #expect(hello?.edits == 1)
}

@Test func omissionSurvivesACrowdedBeam() {
    // Flood the beam with edit-free same-length competitors: the omission path
    // for "hello" trails every matched-tap hypothesis by ~omissionPenalty, so
    // raw-score pruning would starve it. Bucketing by taps consumed keeps it.
    var frequencies = sampleFrequencies
    for a in "gjhybu" {
        for b in "edcswx" {
            for c in "klomij" {
                frequencies["\(a)\(b)\(c)o"] = 500
            }
        }
    }
    let lexicon = Lexicon(frequencies: frequencies)
    let lm = NGramLanguageModel(lexicon: lexicon)
    let decoder = Decoder(spatial: SpatialModel(layout: productionLayout), language: lm, beamWidth: 4)
    let candidates = decoder.decode(taps: perfectTaps(for: "helo"), maxCandidates: 10)
    #expect(candidates.contains { $0.word == "hello" })
}
