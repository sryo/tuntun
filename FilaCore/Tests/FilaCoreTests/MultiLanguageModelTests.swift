import Testing
@testable import FilaCore

private func makeEnglish() throws -> QuantizedNGramModel {
    try NGramModelBuilder().build(
        unigrams: ["hello": 500, "world": 300, "don't": 250, "the": 900],
        bigrams: ["hello": ["world": 40]],
        language: .english)
}

private func makeSpanish() throws -> QuantizedNGramModel {
    try NGramModelBuilder().build(
        unigrams: ["hola": 500, "año": 300, "está": 250],
        bigrams: [:],
        language: .spanish)
}

@Test func mergedLexiconKeysByPrimaryTransliteration() throws {
    // Spanish "año" merged onto the English (primary) layout folds ñ → n, so it
    // is reachable from plain a-n-o taps and keeps its display form.
    let multi = MultiLanguageModel(models: [try makeEnglish(), try makeSpanish()])
    #expect(multi.lexicon.contains("año"))
    #expect(multi.lexicon.contains("don't"))

    let layout = KeyboardLanguage.english.layout1D
    let decoder = Decoder(spatial: SpatialModel(layout: layout), language: multi)
    let taps = "ano".compactMap { layout.geometry(for: $0)?.normalizedX }
    #expect(decoder.decode(taps: taps).contains { $0.word == "año" })
}

@Test func learnedWordScoresWithTwoDictionariesEnabled() throws {
    let multi = MultiLanguageModel(models: [try makeEnglish(), try makeSpanish()])
    #expect(multi.logProbability(of: "sryo", given: []) == -.infinity)

    multi.learn(word: "sryo", count: 3)
    let expected = MultiLanguageModel.learnedLogPrior(count: 3)
    #expect(multi.logProbability(of: "sryo", given: []) == expected)
    #expect(multi.logProbability(of: "sryo", given: ["hello"]) == expected)
    #expect(multi.lexicon.logPrior(of: "sryo") == expected)

    // The learned word must be decodable, not just scoreable.
    let layout = KeyboardLanguage.english.layout1D
    let decoder = Decoder(spatial: SpatialModel(layout: layout), language: multi)
    let taps = "sryo".compactMap { layout.geometry(for: $0)?.normalizedX }
    #expect(decoder.decode(taps: taps).contains { $0.word == "sryo" })
}

@Test func learnedPriorGrowsWithCountAndCaps() throws {
    let multi = MultiLanguageModel(models: [try makeEnglish()])
    multi.learn(word: "sryo", count: 1)
    let low = multi.logProbability(of: "sryo", given: [])
    multi.learn(word: "sryo", count: 10)
    let high = multi.logProbability(of: "sryo", given: [])
    #expect(high > low)
    #expect(MultiLanguageModel.learnedLogPrior(count: 30) == MultiLanguageModel.learnedLogPrior(count: 400))
}

@Test func forgetRemovesLearnedWord() throws {
    let multi = MultiLanguageModel(models: [try makeEnglish(), try makeSpanish()])
    multi.learn(word: "sryo", count: 5)
    #expect(multi.lexicon.contains("sryo"))

    multi.forget(word: "sryo")
    #expect(!multi.lexicon.contains("sryo"))
    #expect(multi.logProbability(of: "sryo", given: []) == -.infinity)
}

@Test func forgettingADictionaryWordRestoresItsPrior() throws {
    let multi = MultiLanguageModel(models: [try makeEnglish(), try makeSpanish()])
    let base = multi.lexicon.logPrior(of: "world")!

    // Learned heavily enough to outgrow the corpus prior…
    multi.learn(word: "world", count: 30)
    #expect(multi.lexicon.logPrior(of: "world")! >= base)

    // …but forgetting must fall back to the dictionary, not erase the word.
    multi.forget(word: "world")
    #expect(multi.lexicon.logPrior(of: "world") == base)
    #expect(multi.logProbability(of: "world", given: []) > -.infinity)
}

@Test func learnedApostropheWordIsTypeable() throws {
    let multi = MultiLanguageModel(models: [try makeEnglish(), try makeSpanish()])
    multi.learn(word: "y'all", count: 4)

    let layout = KeyboardLanguage.english.layout1D
    let decoder = Decoder(spatial: SpatialModel(layout: layout), language: multi)
    let taps = "yall".compactMap { layout.geometry(for: $0)?.normalizedX }
    #expect(decoder.decode(taps: taps).contains { $0.word == "y'all" })
}
