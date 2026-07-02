import Foundation

/// Models `P(tap | intended letter)` — how likely a touch at a given horizontal
/// position was *aimed* at a particular letter.
///
/// This is the "spatial" half of the decoder. Because the row is collapsed, the
/// three letters in a QWERTY column share (nearly) the same `normalizedX`, so a
/// single tap is inherently ambiguous between them; the language model resolves
/// the rest. The model is *dynamic* — it adapts to each user's real tap
/// distribution over time via ``observe(tapX:for:)`` and Welford-style running stats.
public struct SpatialModel: Sendable {
    /// Per-letter tap statistics, learned from the user (seeded from the layout).
    public struct KeyStat: Sendable, Equatable {
        public var mean: Double
        public var variance: Double
        public var count: Double

        public init(mean: Double, variance: Double, count: Double) {
            self.mean = mean
            self.variance = variance
            self.count = count
        }
    }

    /// Minimum standard deviation, so a confident user can't collapse a key to a
    /// delta spike (which would make out-of-column letters impossible to recover).
    public let minSigma: Double
    private(set) var stats: [Character: KeyStat]

    public init(layout: KeyboardLayout,
                initialSigma: Double = 0.05,
                minSigma: Double = 0.025,
                priorCount: Double = 4) {
        self.minSigma = minSigma
        var stats: [Character: KeyStat] = [:]
        for key in layout.keys {
            stats[key.letter] = KeyStat(mean: key.normalizedX,
                                        variance: initialSigma * initialSigma,
                                        count: priorCount)
        }
        self.stats = stats
    }

    /// Log `P(tapX | letter)` under the letter's current Gaussian. Returns
    /// `-.infinity` for unknown letters so they can't be silently matched.
    public func logLikelihood(tapX: Double, for letter: Character) -> Double {
        guard let stat = stats[letter] else { return -.infinity }
        let sigma = max(sqrt(stat.variance), minSigma)
        let d = tapX - stat.mean
        // log of N(tapX; mean, sigma): -0.5*log(2πσ²) - (d²)/(2σ²)
        return -0.5 * log(2 * .pi * sigma * sigma) - (d * d) / (2 * sigma * sigma)
    }

    /// Fold a confirmed (tap, letter) observation into the per-letter statistics,
    /// personalizing the model. Uses Welford's online mean/variance update.
    public mutating func observe(tapX: Double, for letter: Character) {
        guard var stat = stats[letter] else { return }
        let newCount = stat.count + 1
        let delta = tapX - stat.mean
        let newMean = stat.mean + delta / newCount
        let delta2 = tapX - newMean
        // Blend running variance toward the sample; keep it bounded by minSigma.
        let m2 = stat.variance * stat.count + delta * delta2
        stat.mean = newMean
        stat.variance = max(m2 / newCount, minSigma * minSigma)
        stat.count = newCount
        stats[letter] = stat
    }

    /// Current per-letter parameters, for persistence to the App Group container.
    public func snapshot() -> [Character: KeyStat] { stats }

    public mutating func restore(_ snapshot: [Character: KeyStat]) {
        for (letter, stat) in snapshot where stats[letter] != nil {
            stats[letter] = stat
        }
    }
}
