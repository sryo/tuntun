import Testing
import Foundation
@testable import FilaCore

private let unigrams: [String: Int] = [
    "the": 2300, "hello": 300, "world": 290, "help": 120, "held": 40,
    "there": 260, "type": 200, "quick": 80, "brown": 70, "fox": 60,
    "keyboard": 90, "tuntun": 30, "friend": 110, "great": 150,
]
private let bigrams: [String: [String: Int]] = [
    "hello": ["world": 80, "there": 20, "friend": 15],
    "the": ["quick": 30, "brown": 10],
    "quick": ["brown": 25],
    "brown": ["fox": 40],
]

private func buildModel() throws -> QuantizedNGramModel {
    try NGramModelBuilder().build(unigrams: unigrams, bigrams: bigrams)
}

@Test func quantizedModelKnowsVocabPriors() throws {
    let model = try buildModel()
    #expect(model.lexicon.contains("hello"))
    #expect(model.lexicon.logPrior(of: "the")! > model.lexicon.logPrior(of: "tuntun")!)
}

@Test func quantizedModelBoostsKnownBigram() throws {
    let model = try buildModel()
    // "hello world" is a strong bigram; with context, world should outrank a
    // non-following word of similar unigram frequency.
    let worldWithCtx = model.logProbability(of: "world", given: ["hello"])
    let worldNoCtx = model.logProbability(of: "world", given: [])
    #expect(worldWithCtx > worldNoCtx)
}

@Test func quantizedModelBacksOffForUnknownBigram() throws {
    let model = try buildModel()
    // "tuntun world" was never seen; membership filter should reject it and the
    // score should equal the plain unigram backoff (no garbage from the Bloomier).
    let unknown = model.logProbability(of: "world", given: ["tuntun"])
    let unigram = model.logProbability(of: "world", given: [])
    #expect(abs(unknown - unigram) < 1e-9)
}

@Test func quantizedModelDrivesDecoder() throws {
    let model = try buildModel()
    let layout = KeyboardLanguage.english.layout1D   // the shipping geometry
    let decoder = Decoder(spatial: SpatialModel(layout: layout), language: model)
    let taps = "world".compactMap { layout.geometry(for: $0)?.normalizedX }
    let candidates = decoder.decode(taps: taps, context: ["hello"])
    #expect(candidates.first?.word == "world")
}

@Test func modelBundleRoundTripsThroughDisk() throws {
    let model = try buildModel()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tuntun-model-test")
    try? FileManager.default.removeItem(at: dir)
    try model.write(to: dir)
    defer { try? FileManager.default.removeItem(at: dir) }

    let loaded = try QuantizedNGramModel.load(from: dir)
    #expect(loaded.lexicon.contains("keyboard"))
    // Scores must match the in-memory model after a mmap reload.
    let a = model.logProbability(of: "world", given: ["hello"])
    let b = loaded.logProbability(of: "world", given: ["hello"])
    #expect(abs(a - b) < 1e-9)
}

@Test func bundleRoundTripsLanguageAndTransliteration() throws {
    let model = try NGramModelBuilder().build(
        unigrams: ["été": 100, "être": 80, "c'est": 200, "avec": 150],
        bigrams: ["c'est": ["été": 10]],
        language: .french)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fila-model-fr-test")
    try? FileManager.default.removeItem(at: dir)
    try model.write(to: dir)
    defer { try? FileManager.default.removeItem(at: dir) }

    let loaded = try QuantizedNGramModel.load(from: dir)
    #expect(loaded.language == .french)
    // Accented/apostrophe entries survive and stay reachable via key sequences.
    #expect(loaded.lexicon.contains("été"))
    #expect(loaded.lexicon.contains("c'est"))
    #expect(abs(loaded.lexicon.logPrior(of: "être")! - model.lexicon.logPrior(of: "être")!) < 1e-6)
    let a = model.logProbability(of: "été", given: ["c'est"])
    let b = loaded.logProbability(of: "été", given: ["c'est"])
    #expect(abs(a - b) < 1e-9)
}

@Test func contextTokensAreNormalizedAtLookup() throws {
    let model = try buildModel()
    // Callers may hand the model raw text fragments; case and trailing
    // punctuation must not lose the bigram.
    let clean = model.logProbability(of: "world", given: ["hello"])
    #expect(abs(model.logProbability(of: "world", given: ["Hello."]) - clean) < 1e-9)
    #expect(abs(model.logProbability(of: "world", given: ["HELLO?!"]) - clean) < 1e-9)
    #expect(abs(model.logProbability(of: "world", given: ["hello\")"]) - clean) < 1e-9)
}

@Test func contextTokensAreNormalizedAtBuild() throws {
    // Dirty context keys at build time merge into the canonical form.
    let dirty = try NGramModelBuilder().build(unigrams: unigrams,
                                              bigrams: ["Hello.": ["world": 80]])
    #expect(dirty.logProbability(of: "world", given: ["hello"])
            > dirty.logProbability(of: "world", given: []))
}

@Test func membershipFalsePositiveCannotResurrectUnknownWord() throws {
    let model = try buildModel()
    // Even if the Bloom filter ever answered yes for this pair, a word outside
    // the vocabulary must stay at -inf.
    #expect(model.logProbability(of: "zzzzq", given: ["hello"]) == -.infinity)
}

@Test func bigramBoostIsClamped() throws {
    // "of" is deliberately rare while the bigram P(of | best) is 1.0 — decoding
    // to logP 0. Unclamped, that's a ~e¹² boost over the unigram; the cap keeps
    // it at e⁸ so a Bloomier byte for a false-positive key can't do worse.
    let model = try NGramModelBuilder().build(
        unigrams: ["best": 100_000, "of": 1, "the": 100_000],
        bigrams: ["best": ["of": 50]])
    let unigram = model.logProbability(of: "of", given: [])
    let boosted = model.logProbability(of: "of", given: ["best"])
    let lambda = 0.7
    let cap = log(lambda * exp(unigram + 8.0) + (1 - lambda) * exp(unigram))
    #expect(boosted > unigram)
    #expect(boosted <= cap + 1e-9)
}
