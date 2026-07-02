import Foundation

/// A language model that predicts across several enabled dictionaries at once
/// (multilingual typing). The layout is fixed to the user's default language; the
/// dictionaries just supply vocabulary + priors. Their tries are merged into one
/// combined lexicon the decoder walks (keyed by the primary language's
/// transliteration), and a word's probability is the best across the enabled
/// dictionaries and the user's learned vocabulary.
public struct MultiLanguageModel: LanguageModel {
    public let lexicon: Lexicon
    private let models: [QuantizedNGramModel]
    private let learned = LearnedVocabulary()

    /// `models.first` is the primary language: its transliteration keys the
    /// combined lexicon, so merged foreign words fold onto the primary layout
    /// (e.g. Spanish "año" reachable as a-n-o on an English row).
    public init(models: [QuantizedNGramModel]) {
        self.models = models
        guard models.count > 1 else {
            lexicon = models.first?.lexicon ?? Lexicon()
            return
        }
        // Union the vocabularies, keeping the highest prior for shared words.
        let combined = Lexicon(transliterator: models[0].lexicon.transliterator)
        for model in models {
            for (word, logPrior) in model.lexicon.terminals() {
                if let existing = combined.logPrior(of: word) {
                    if logPrior > existing { combined.insert(word: word, logPrior: logPrior) }
                } else {
                    combined.insert(word: word, logPrior: logPrior)
                }
            }
        }
        lexicon = combined
    }

    public func logProbability(of word: String, given context: [String]) -> Double {
        var best = learned.priors[word.lowercased()] ?? -.infinity
        for model in models {
            best = max(best, model.logProbability(of: word, given: context))
        }
        return best
    }

    // MARK: - User vocabulary

    /// The prior a word learned `count` times deserves: real but modest, growing
    /// with use and capped so a pet word can't outrank core vocabulary.
    public static func learnedLogPrior(count: Int) -> Double {
        -7.0 + log(Double(min(max(count, 1), 30)))
    }

    /// Learn (or re-price, on repeat commits) a user word. The word becomes
    /// walkable in the combined trie and scores via ``learnedLogPrior(count:)``
    /// in every context, regardless of which dictionaries are enabled.
    public func learn(word: String, count: Int) {
        let w = word.lowercased()
        guard !w.isEmpty else { return }
        let prior = Self.learnedLogPrior(count: count)
        if let existing = lexicon.logPrior(of: w) {
            if learned.insertedNew.contains(w) {
                lexicon.insert(word: w, logPrior: prior)
            } else if prior > existing {
                // Outgrew the dictionary prior: remember it for forget-restore.
                if learned.replacedBase[w] == nil { learned.replacedBase[w] = existing }
                lexicon.insert(word: w, logPrior: prior)
            }
        } else {
            lexicon.insert(word: w, logPrior: prior)
            if lexicon.contains(w) { learned.insertedNew.insert(w) }
        }
        learned.priors[w] = prior
    }

    /// Forget a learned word: drop its overlay prior and undo its trie effect
    /// (remove a pure user word; restore the dictionary prior it had displaced).
    public func forget(word: String) {
        let w = word.lowercased()
        guard learned.priors.removeValue(forKey: w) != nil else { return }
        if learned.insertedNew.remove(w) != nil {
            lexicon.remove(word: w)
        } else if let base = learned.replacedBase.removeValue(forKey: w) {
            lexicon.insert(word: w, logPrior: base)
        }
    }
}

/// Reference storage so the overlay survives the model being copied around by
/// value. Mutated only from the keyboard's main actor, like ``Lexicon``.
private final class LearnedVocabulary: @unchecked Sendable {
    var priors: [String: Double] = [:]
    var insertedNew: Set<String> = []
    var replacedBase: [String: Double] = [:]
}
