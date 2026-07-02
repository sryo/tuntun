import Foundation
import FilaCore
import UIKit

/// Owns the decoder and the mutable spatial model for the running keyboard.
///
/// The decode substrate is a per-language model bundle (vocab trie + Bloomier
/// n-gram) built offline from OpenSubtitles frequency data and shipped in the
/// FilaKit resource bundle; the active language's `values.blmr` is memory-mapped
/// so resident memory stays well under the ~48 MB extension ceiling. Only the
/// active language is loaded. `UITextChecker` supplies out-of-vocabulary rescue
/// in the same language (system dictionaries, no Full Access).
@MainActor
final class KeyboardEngine {
    private(set) var decoder: Decoder
    private(set) var layout: KeyboardLayout
    /// The default/primary language — sets the layout. Prediction merges all
    /// enabled dictionaries of the same script; there is no in-keyboard switching.
    private(set) var language: KeyboardLanguage
    private var model: MultiLanguageModel

    private let textChecker = UITextChecker()
    private let personalization = PersonalizationStore()
    /// Weight on the language model relative to the spatial likelihood (tunable;
    /// 1.0 = balanced.
    var languageWeight: Double = 1.0

    /// Fires on the main actor whenever a dictionary set finishes loading
    /// (startup or settings change) — the controller re-decodes any word in
    /// progress with the real vocabulary.
    var onModelReady: (() -> Void)?
    /// Guards against a stale async load landing after a newer `activate`.
    private var loadGeneration = 0

    init() {
        let primary = SettingsStore.shared.primaryLanguage
        languageWeight = SettingsStore.shared.languageWeight
        language = primary
        layout = primary.layout1D
        model = MultiLanguageModel(models: [])
        decoder = Decoder(spatial: SpatialModel(layout: layout), language: model, languageWeight: languageWeight)
        activate(primary)
    }

    /// Point the keyboard at `primary` immediately (layout + adapted spatial
    /// model, both cheap) and load the dictionaries off the main thread — trie
    /// construction for the 80k-word vocabularies takes whole seconds on device,
    /// far too slow for the extension's startup path. Until the load lands the
    /// decoder has an empty lexicon, so typing falls back to the raw
    /// nearest-letter reading and the system-checker rescue.
    private func activate(_ primary: KeyboardLanguage) {
        language = primary
        layout = primary.layout1D
        var spatial = SpatialModel(layout: layout)
        spatial.restore(personalization.loadSpatial(primary))
        model = MultiLanguageModel(models: [])
        decoder = Decoder(spatial: spatial, language: model, languageWeight: languageWeight)

        loadGeneration += 1
        let generation = loadGeneration
        let enabled = SettingsStore.shared.enabledDictionaries
            .union([primary])
            .filter { $0.script == primary.script }
        let ordered = [primary] + enabled.subtracting([primary]).sorted { $0.rawValue < $1.rawValue }
        let learned = personalization.loadVocab(primary)
        Task.detached(priority: .userInitiated) {
            let loaded = ordered.compactMap(Self.loadBundle)
            let built = MultiLanguageModel(models: loaded.isEmpty ? [Self.fallbackModel()] : loaded)
            for (word, count) in learned { built.learn(word: word, count: count) }
            await MainActor.run { [weak self] in self?.install(built, generation: generation) }
        }
    }

    private func install(_ built: MultiLanguageModel, generation: Int) {
        guard generation == loadGeneration else { return }   // superseded by a newer load
        model = built
        decoder = Decoder(spatial: decoder.spatial, language: built, languageWeight: languageWeight)
        onModelReady?()
    }

    /// Fold a committed word back into the user's personalization: adapt the
    /// spatial model from the aligned taps and learn the word. Persisted to the
    /// App Group so it carries across sessions.
    ///
    /// Spatial adaptation only happens for zero-edit decodes (`edits == 0`) whose
    /// key sequence matches the tap count — any other alignment is guesswork and
    /// would drift the per-letter Gaussians.
    func learn(word: String, taps: [Double], edits: Int?) {
        let w = word.lowercased()
        guard let keys = language.transliterator.keySequence(for: w) else { return }
        if edits == 0, keys.count == taps.count {
            for (i, ch) in keys.enumerated() { decoder.spatial.observe(tapX: taps[i], for: ch) }
            personalization.saveSpatial(decoder.spatial.snapshot(), language)
        }
        if w.count >= 2 {
            let count = personalization.learn(word: w, language)
            model.learn(word: w, count: count)
        }
    }

    /// Re-read settings and rebuild — but only when something the engine
    /// actually consumes changed. Settings notifications fire on every app
    /// activation and on cosmetic changes (text size); reloading dictionaries
    /// for those would thrash the async model load.
    func applySettings() {
        let primary = SettingsStore.shared.primaryLanguage
        let enabled = SettingsStore.shared.enabledDictionaries
        let weight = SettingsStore.shared.languageWeight
        guard primary != language || enabled != appliedDictionaries || weight != languageWeight else { return }
        languageWeight = weight
        appliedDictionaries = enabled
        activate(primary)
    }
    private var appliedDictionaries = SettingsStore.shared.enabledDictionaries

    /// Memory-map one language's shipped model bundle, if present.
    private nonisolated static func loadBundle(_ language: KeyboardLanguage) -> QuantizedNGramModel? {
        guard let dir = modelsDirectory?.appendingPathComponent(language.rawValue) else { return nil }
        return try? QuantizedNGramModel.load(from: dir)
    }

    /// Last resort if a primary bundle fails to load: the shipped English bundle,
    /// or an empty model (decoder then relies on the nearest-letter fallback).
    private nonisolated static func fallbackModel() -> QuantizedNGramModel {
        loadBundle(.english) ?? (try! NGramModelBuilder().build(unigrams: [:], bigrams: [:]))
    }

    /// The bundled `Models/` folder inside the FilaKit resource bundle.
    private nonisolated static let modelsDirectory: URL? = {
        Bundle(for: KeyboardEngine.self).url(forResource: "Models", withExtension: nil)
    }()

    /// The one-row keys the decoder resolves taps against.
    var keys: [KeyGeometry] { layout.keys }

    /// Decode a tap sequence into ranked candidates, augmented with system-dictionary
    /// rescue for out-of-vocabulary words the shipped model can't reconstruct.
    func candidates(for taps: [Double], context: [String], forced: [Int: Character] = [:]) -> [DecodeCandidate] {
        var result = decoder.decode(taps: taps, context: context, maxCandidates: 10, forced: forced)
        let raw = nearestLetters(for: taps, forced: forced)
        if raw.count >= 2 {
            let seen = Set(result.map(\.word))
            for word in systemSuggestions(for: raw) where !seen.contains(word) {
                // Sit below the trie-decoded candidates but above the raw literal.
                // edits 1: a checker correction's letters don't align with the taps.
                result.append(DecodeCandidate(word: word, score: -Double(taps.count) * 5, edits: 1))
            }
        }
        // Smart-emoji: suggest an emoji for the top word (just below it in the strip).
        if let top = result.first, let emoji = EmojiSuggestions.emoji(for: top.word) {
            result.insert(DecodeCandidate(word: emoji, score: top.score - 0.01), at: min(1, result.count))
        }
        return result
    }

    /// `UITextChecker` corrections + completions for the literal reading, in the
    /// active language's system dictionary. On-device, no Full Access.
    private func systemSuggestions(for raw: String) -> [String] {
        let ns = raw as NSString
        let range = NSRange(location: 0, length: ns.length)
        var out: [String] = []
        if let guesses = textChecker.guesses(forWordRange: range, in: raw, language: checkerCode) {
            out += guesses.prefix(3)
        }
        if let completions = textChecker.completions(forPartialWordRange: range, in: raw, language: checkerCode) {
            out += completions.prefix(2)
        }
        return out
    }

    /// Fila language → `UITextChecker` locale code (all verified present in
    /// `UITextChecker.availableLanguages` on-device).
    private var checkerCode: String {
        switch language {
        case .english: return "en_US"
        case .french: return "fr_FR"
        case .german: return "de_DE"
        case .spanish: return "es_ES"
        case .italian: return "it_IT"
        case .dutch: return "nl_NL"
        case .portuguese: return "pt_BR"
        case .russian: return "ru_RU"
        }
    }

    /// The literal reading: the single most-likely letter under each tap, ignoring
    /// the language model. This is the out-of-vocabulary escape hatch — names,
    /// slang, and passwords that the decoder can't reconstruct still appear as a
    /// selectable raw candidate (Fila's decisive failure mode, mitigated).
    func nearestLetters(for taps: [Double], forced: [Int: Character] = [:]) -> String {
        var result = ""
        for (i, x) in taps.enumerated() {
            if let pinned = forced[i] { result.append(pinned); continue }
            var best: Character? = nil
            var bestLL = -Double.infinity
            for key in layout.keys {
                let ll = decoder.spatial.logLikelihood(tapX: x, for: key.letter)
                if ll > bestLL { bestLL = ll; best = key.letter }
            }
            if let best { result.append(best) }
        }
        return result
    }

    /// Unlearn one use of `word` (the user corrected or removed it). Returns false
    /// if the word was never learned — built-in dictionary words are untouchable.
    @discardableResult
    func forget(word: String) -> Bool {
        let w = word.lowercased()
        guard personalization.forget(word: w, language) else { return false }
        if let remaining = personalization.loadVocab(language)[w] {
            model.learn(word: w, count: remaining)   // still learned, at a lower count
        } else {
            model.forget(word: w)
        }
        return true
    }
}
