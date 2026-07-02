import Foundation
import FilaCore

/// Persists per-user personalization to the App Group, per language, so typing
/// improves across sessions: the adaptive spatial tap model (per-user tap
/// distributions) and a learned-vocabulary count table.
@MainActor
final class PersonalizationStore {
    private let defaults = UserDefaults(suiteName: FilaConfig.appGroupID)
    private let maxVocab = 2_000

    // MARK: Spatial model  ([char: [mean, variance, count]] per language)

    func loadSpatial(_ language: KeyboardLanguage) -> [Character: SpatialModel.KeyStat] {
        guard let dict = defaults?.dictionary(forKey: "spatial.\(language.rawValue)") as? [String: [Double]]
        else { return [:] }
        var out: [Character: SpatialModel.KeyStat] = [:]
        for (key, v) in dict where v.count == 3 {
            if let ch = key.first {
                out[ch] = SpatialModel.KeyStat(mean: v[0], variance: v[1], count: v[2])
            }
        }
        return out
    }

    func saveSpatial(_ snapshot: [Character: SpatialModel.KeyStat], _ language: KeyboardLanguage) {
        var dict: [String: [Double]] = [:]
        for (ch, s) in snapshot { dict[String(ch)] = [s.mean, s.variance, s.count] }
        defaults?.set(dict, forKey: "spatial.\(language.rawValue)")
    }

    // MARK: Learned vocabulary  ([word: count] per language)

    func loadVocab(_ language: KeyboardLanguage) -> [String: Int] {
        defaults?.dictionary(forKey: "vocab.\(language.rawValue)") as? [String: Int] ?? [:]
    }

    /// Record one use of `word`; returns its new count. Prunes the rarest entries
    /// when the table grows past `maxVocab`.
    @discardableResult
    func learn(word: String, _ language: KeyboardLanguage) -> Int {
        var vocab = loadVocab(language)
        let count = (vocab[word] ?? 0) + 1
        vocab[word] = count
        if vocab.count > maxVocab {
            for key in vocab.sorted(by: { $0.value < $1.value }).prefix(vocab.count - maxVocab).map(\.key) {
                vocab.removeValue(forKey: key)
            }
        }
        defaults?.set(vocab, forKey: "vocab.\(language.rawValue)")
        return count
    }

    /// Decrement `word` (a rejected commit or an explicit removal), dropping it
    /// entirely at zero. Returns false if the word was never learned.
    @discardableResult
    func forget(word: String, _ language: KeyboardLanguage) -> Bool {
        var vocab = loadVocab(language)
        guard let count = vocab[word] else { return false }
        if count <= 1 { vocab.removeValue(forKey: word) } else { vocab[word] = count - 1 }
        defaults?.set(vocab, forKey: "vocab.\(language.rawValue)")
        return true
    }
}
