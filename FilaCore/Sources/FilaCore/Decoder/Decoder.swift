/// A ranked word hypothesis produced by the decoder.
public struct DecodeCandidate: Sendable, Equatable {
    public let word: String
    /// Combined log-score: spatial log-likelihood + weighted language log-prob.
    public let score: Double
    /// Insertions + omissions the winning path needed. 0 means every tap matched
    /// a letter in order — the only alignment safe to feed back into spatial
    /// learning (`SpatialModel.observe`).
    public let edits: Int

    public init(word: String, score: Double, edits: Int = 0) {
        self.word = word
        self.score = score
        self.edits = edits
    }
}

/// Reconstructs the intended word from an imprecise sequence of taps.
///
/// This is Fila's Bayesian decoder: it beam-searches the lexicon trie, scoring
/// each surviving path by `P(taps | word)` (from the ``SpatialModel``) and, at
/// word completion, `P(word | context)` (from the ``LanguageModel``). Because the
/// search only follows real dictionary paths, a sloppy one-row tap sequence
/// collapses onto valid words. Insertions and omissions (an extra or missed tap)
/// are handled as penalized edits so the user need not hit every letter exactly.
public struct Decoder: Sendable {
    public var spatial: SpatialModel
    public let language: LanguageModel

    /// Number of partial hypotheses kept between expansion rounds.
    public var beamWidth: Int
    /// Multiplier on the language log-prob relative to the spatial log-likelihood.
    public var languageWeight: Double
    /// Log penalty for consuming a tap that matches no intended letter (extra tap).
    public var insertionPenalty: Double
    /// Log penalty for advancing over a letter with no tap (missed key).
    public var omissionPenalty: Double
    /// Max combined insertions+omissions per hypothesis, to bound the search.
    public var maxEdits: Int

    public init(spatial: SpatialModel,
                language: LanguageModel,
                beamWidth: Int = 32,
                languageWeight: Double = 1.0,
                insertionPenalty: Double = -4.0,
                omissionPenalty: Double = -4.0,
                maxEdits: Int = 2) {
        self.spatial = spatial
        self.language = language
        self.beamWidth = beamWidth
        self.languageWeight = languageWeight
        self.insertionPenalty = insertionPenalty
        self.omissionPenalty = omissionPenalty
        self.maxEdits = maxEdits
    }

    private struct State {
        let node: Lexicon.Node
        let tapIndex: Int
        let edits: Int
        let spatialScore: Double
        /// Key characters consumed so far — the node's identity in *semantic*
        /// form. Unlike `ObjectIdentifier`, it is stable across runs and trie
        /// build orders, so exact score ties break reproducibly.
        let prefix: String
    }

    /// Decode a tap sequence into the top word candidates, best first.
    ///
    /// - Parameters:
    ///   - taps: normalized x-positions ([0,1]) in typed order.
    ///   - context: preceding words (most recent last) for the language model.
    ///   - maxCandidates: how many hypotheses to return.
    /// - Parameter forced: tap indices the user pinned to an exact letter (via the
    ///   precision magnifier). At a forced index only that letter may match, scored
    ///   as certain — so the decoded word always contains the letters the user chose.
    public func decode(taps: [Double],
                       context: [String] = [],
                       maxCandidates: Int = 5,
                       forced: [Int: Character] = [:]) -> [DecodeCandidate] {
        guard !taps.isEmpty else { return [] }
        let lexicon = language.lexicon

        var frontier: [State] = [State(node: lexicon.root, tapIndex: 0, edits: 0, spatialScore: 0, prefix: "")]
        var completed: [DecodeCandidate] = []

        // Expand until no partial hypothesis can advance. Each round either
        // consumes a tap (match/insertion) or an edit budget (omission), so the
        // search is finite.
        while !frontier.isEmpty {
            var next: [State] = []
            for state in frontier {
                let pinned = state.tapIndex < taps.count ? forced[state.tapIndex] : nil
                for (letter, child) in state.node.children {
                    // Match: this tap was aimed at `letter`. A pinned tap only matches
                    // its forced letter, scored as certain (ll = 0).
                    if state.tapIndex < taps.count {
                        if let pinned {
                            if letter == pinned {
                                next.append(State(node: child,
                                                  tapIndex: state.tapIndex + 1,
                                                  edits: state.edits,
                                                  spatialScore: state.spatialScore,
                                                  prefix: state.prefix + String(letter)))
                            }
                        } else {
                            let ll = spatial.logLikelihood(tapX: taps[state.tapIndex], for: letter)
                            if ll > -.infinity {
                                next.append(State(node: child,
                                                  tapIndex: state.tapIndex + 1,
                                                  edits: state.edits,
                                                  spatialScore: state.spatialScore + ll,
                                                  prefix: state.prefix + String(letter)))
                            }
                        }
                    }
                    // Omission: the user meant `letter` but produced no tap for it.
                    if state.edits < maxEdits {
                        next.append(State(node: child,
                                          tapIndex: state.tapIndex,
                                          edits: state.edits + 1,
                                          spatialScore: state.spatialScore + omissionPenalty,
                                          prefix: state.prefix + String(letter)))
                    }
                }
                // Insertion: this tap was spurious; stay on the same node. Never drop a
                // pinned tap this way.
                if pinned == nil && state.tapIndex < taps.count && state.edits < maxEdits {
                    next.append(State(node: state.node,
                                      tapIndex: state.tapIndex + 1,
                                      edits: state.edits + 1,
                                      spatialScore: state.spatialScore + insertionPenalty,
                                      prefix: state.prefix))
                }
                // Completion: a node that has consumed every tap yields every display
                // form sharing its key sequence ("well" and "we'll"), each scored
                // with its own language prior.
                if state.tapIndex == taps.count {
                    for entry in state.node.entries {
                        let lm = language.logProbability(of: entry.word, given: context)
                        completed.append(DecodeCandidate(word: entry.word,
                                                         score: state.spatialScore + languageWeight * lm,
                                                         edits: state.edits))
                    }
                }
            }
            frontier = prune(next)
        }

        // Best score per unique word (ties prefer fewer edits), then rank.
        // Ranking ties break on the word so the output is reproducible.
        var bestByWord: [String: DecodeCandidate] = [:]
        for cand in completed {
            if let existing = bestByWord[cand.word] {
                let better = cand.score > existing.score
                    || (cand.score == existing.score && cand.edits < existing.edits)
                if !better { continue }
            }
            bestByWord[cand.word] = cand
        }
        return bestByWord.values
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                return a.word < b.word
            }
            .prefix(maxCandidates)
            .map { $0 }
    }

    /// Dedup key: same trie node, same taps consumed, same edit budget spent.
    /// Edits must participate: two paths at the same (node, tapIndex) with
    /// different edit counts diverge later — an edit-free path can afford future
    /// edits that would complete the intended word, so it must not be evicted by
    /// a currently higher-scoring edit-bearing twin (or vice versa).
    private struct PruneKey: Hashable {
        let node: ObjectIdentifier
        let tapIndex: Int
        let edits: Int
    }

    /// Keep the highest-scoring `beamWidth` states *per taps-consumed bucket*.
    /// Partial spatial scores are only comparable at equal `tapIndex`: every
    /// matched tap adds a large positive log-density (≈ +2 nats at σ = 0.05), so
    /// ranking mixed-tapIndex states on raw score would starve omission-carrying
    /// hypotheses ("helo" → "hello") that are one tap behind. Buckets are bounded:
    /// only omissions hold `tapIndex` back, so there are at most `maxEdits + 1`.
    ///
    /// The returned frontier is fully ordered (bucket, then ``beamOrder``) so a
    /// decode is a pure function of taps + model — never of heap layout.
    private func prune(_ states: [State]) -> [State] {
        var bestByKey: [PruneKey: State] = [:]
        for state in states {
            let key = PruneKey(node: ObjectIdentifier(state.node),
                               tapIndex: state.tapIndex,
                               edits: state.edits)
            if let existing = bestByKey[key] {
                if state.spatialScore > existing.spatialScore { bestByKey[key] = state }
            } else {
                bestByKey[key] = state
            }
        }
        var buckets: [Int: [State]] = [:]
        for state in bestByKey.values {
            buckets[state.tapIndex, default: []].append(state)
        }
        var kept: [State] = []
        kept.reserveCapacity(min(bestByKey.count, buckets.count * beamWidth))
        for tapIndex in buckets.keys.sorted() {
            kept.append(contentsOf: buckets[tapIndex]!
                .sorted(by: Self.beamOrder)
                .prefix(beamWidth))
        }
        return kept
    }

    /// Deterministic beam ordering: score first, then fewer edits, then the
    /// consumed key prefix — a total order over deduplicated states (states with
    /// equal prefix, tapIndex, and edits share a ``PruneKey``), so exact score
    /// ties never fall back to allocation order.
    private static func beamOrder(_ a: State, _ b: State) -> Bool {
        if a.spatialScore != b.spatialScore { return a.spatialScore > b.spatialScore }
        if a.edits != b.edits { return a.edits < b.edits }
        return a.prefix < b.prefix
    }
}
