import Foundation
import FilaCore

// Offline decode-accuracy benchmark: synthesizes noisy tap sequences for known
// words and measures how well the decoder recovers them against a shipped model
// bundle. The decode wiring mirrors the keyboard's (`KeyboardEngine`): the
// bundle is wrapped in a `MultiLanguageModel` and driven through `Decoder` with
// a fresh `SpatialModel` on the bundle language's collapsed 1D layout.
//
// Fully deterministic: word sampling, tap noise, and context selection all come
// from one seeded RNG, so a --compare run replays the *identical* test plan
// against a second bundle directory. The plan derives from the primary bundle's
// vocabulary; the compare bundle is measured on the same words/taps/contexts.
//
// Usage: DecodeBench [--models <dir>] [--lang <code> | --all] [-n <count>]
//                    [--sigma <x>] [--seed <n>] [--words <file>] [--compare <dir>]
//   --models   directory of per-language bundles (default ../../FilaKit/Resources/Models)
//   --lang     language bundle to test (default en)
//   --all      benchmark every bundle directory under --models
//   -n         number of test words (default 1000), sampled by unigram prior
//   --sigma    tap noise stddev in normalized [0,1] x (default 0.05, the
//              SpatialModel's initialSigma — noise matches the decoder's belief)
//   --seed     RNG seed (default 42)
//   --words    newline-separated word list instead of vocabulary sampling
//   --compare  second bundle directory; runs the identical plan, prints deltas

struct Options {
    var models = URL(fileURLWithPath: "../../FilaKit/Resources/Models")
    var lang = "en"
    var all = false
    var count = 1000
    var sigma = 0.05
    var seed: UInt64 = 42
    var words: URL?
    var compare: URL?
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("DecodeBench: \(message)\n".utf8))
    exit(2)
}

func require<T>(_ value: T?, _ message: String) -> T {
    guard let value else { fail(message) }
    return value
}

func parseOptions(_ args: [String]) -> Options {
    var options = Options()
    var i = 1
    func value(_ flag: String) -> String {
        i += 1
        guard i < args.count else { fail("\(flag) requires a value") }
        return args[i]
    }
    while i < args.count {
        switch args[i] {
        case "--models": options.models = URL(fileURLWithPath: value("--models"))
        case "--lang": options.lang = value("--lang")
        case "--all": options.all = true
        case "-n": options.count = require(Int(value("-n")), "-n must be an integer")
        case "--sigma": options.sigma = require(Double(value("--sigma")), "--sigma must be a number")
        case "--seed": options.seed = require(UInt64(value("--seed")), "--seed must be an unsigned integer")
        case "--words": options.words = URL(fileURLWithPath: value("--words"))
        case "--compare": options.compare = URL(fileURLWithPath: value("--compare"))
        default: fail("unknown argument \(args[i])")
        }
        i += 1
    }
    return options
}

// MARK: - Seeded RNG (SplitMix64 + Box-Muller)

struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in (0,1) — never exactly 0, safe under log().
    mutating func uniform() -> Double {
        (Double(next() >> 11) + 0.5) * 0x1p-53
    }

    mutating func gaussian() -> Double {
        sqrt(-2 * log(uniform())) * cos(2 * .pi * uniform())
    }

    mutating func index(below n: Int) -> Int {
        Int(next() % UInt64(n))
    }
}

// MARK: - Bundle loading

struct LoadedBundle {
    let model: MultiLanguageModel
    let language: KeyboardLanguage?
}

func loadBundle(at dir: URL) -> LoadedBundle {
    do {
        let raw = try QuantizedNGramModel.load(from: dir)
        // Production wiring: KeyboardEngine wraps bundles in a MultiLanguageModel.
        return LoadedBundle(model: MultiLanguageModel(models: [raw]), language: raw.language)
    } catch {
        fail("cannot load bundle \(dir.path): \(error)")
    }
}

// MARK: - Test plan

struct TestCase {
    let word: String
    let taps: [Double]
    /// One preceding word: a real bigram continuation context when the primary
    /// model knows one, otherwise a prior-weighted random word.
    let context: [String]
    let bigramContext: Bool
}

struct Plan {
    let cases: [TestCase]
    /// Intended words the layout cannot produce (no key sequence) — counted
    /// into OOV for every bundle since they can never decode.
    let untypeable: Int
    var total: Int { cases.count + untypeable }
}

/// Prior-weighted sampler over `(word, logPrior)` terminals.
struct VocabularySampler {
    private let words: [String]
    private let cumulative: [Double]
    private let total: Double

    init(terminals: [(word: String, logPrior: Double)]) {
        // Trie iteration order is dictionary-hash order; sort for determinism.
        let sorted = terminals.sorted { $0.word < $1.word }
        var cumulative: [Double] = []
        cumulative.reserveCapacity(sorted.count)
        var total = 0.0
        for terminal in sorted {
            total += exp(terminal.logPrior)
            cumulative.append(total)
        }
        self.words = sorted.map(\.word)
        self.cumulative = cumulative
        self.total = total
    }

    var isEmpty: Bool { words.isEmpty }

    mutating func sample(using rng: inout SplitMix64) -> String {
        let target = rng.uniform() * total
        var lo = 0, hi = cumulative.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if cumulative[mid] < target { lo = mid + 1 } else { hi = mid }
        }
        return words[lo]
    }
}

func buildPlan(model: any LanguageModel, layout: KeyboardLayout, options: Options) -> Plan {
    var rng = SplitMix64(seed: options.seed)
    let transliterator = model.lexicon.transliterator
    let terminals = model.lexicon.terminals()
    guard !terminals.isEmpty else { fail("bundle vocabulary is empty") }
    var sampler = VocabularySampler(terminals: terminals)

    let intended: [String]
    if let file = options.words {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            fail("cannot read word list \(file.path)")
        }
        intended = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    } else {
        intended = (0..<options.count).map { _ in sampler.sample(using: &rng) }
    }

    // The most frequent words are the candidate bigram contexts ("the", "to"…).
    let contextPool = terminals
        .sorted { $0.logPrior != $1.logPrior ? $0.logPrior > $1.logPrior : $0.word < $1.word }
        .prefix(256)
        .map(\.word)

    var cases: [TestCase] = []
    cases.reserveCapacity(intended.count)
    var untypeable = 0
    for word in intended {
        guard let key = transliterator.keySequence(for: word),
              case let centers = key.compactMap({ layout.geometry(for: $0)?.normalizedX }),
              centers.count == key.count else {
            untypeable += 1
            continue
        }
        let taps = centers.map { min(1.0, max(0.0, $0 + options.sigma * rng.gaussian())) }

        // Probe frequent words for one whose bigram genuinely boosts this word;
        // fall back to a random frequent word so the condition is always exercised.
        let unigram = model.logProbability(of: word, given: [])
        var context = [contextPool[rng.index(below: contextPool.count)]]
        var bigram = false
        for _ in 0..<min(64, contextPool.count) {
            let candidate = contextPool[rng.index(below: contextPool.count)]
            if model.logProbability(of: word, given: [candidate]) > unigram + 0.01 {
                context = [candidate]
                bigram = true
                break
            }
        }
        cases.append(TestCase(word: word, taps: taps, context: context, bigramContext: bigram))
    }
    return Plan(cases: cases, untypeable: untypeable)
}

// MARK: - Evaluation

let topK = 10

struct ConditionResult {
    var attempts = 0
    var top1 = 0
    var top3 = 0
    var found = 0
    var rankSum = 0

    var top1Rate: Double { attempts == 0 ? 0 : Double(top1) / Double(attempts) }
    var top3Rate: Double { attempts == 0 ? 0 : Double(top3) / Double(attempts) }
    var recallAtK: Double { attempts == 0 ? 0 : Double(found) / Double(attempts) }
    /// Mean rank of the intended word among decodes where it appeared in the
    /// top `topK` candidates (1 = best).
    var meanRank: Double { found == 0 ? .nan : Double(rankSum) / Double(found) }
}

struct BundleResult {
    let path: String
    var oov = 0
    var total = 0
    var bigramContexts = 0
    var noContext = ConditionResult()
    var withContext = ConditionResult()
    var latencies: [Double] = []

    var oovRate: Double { total == 0 ? 0 : Double(oov) / Double(total) }
    func latency(_ p: Double) -> Double {
        guard !latencies.isEmpty else { return 0 }
        let sorted = latencies.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }
}

func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
}

func evaluate(model: any LanguageModel, layout: KeyboardLayout, plan: Plan, path: String) -> BundleResult {
    let decoder = Decoder(spatial: SpatialModel(layout: layout), language: model)
    var result = BundleResult(path: path)
    result.total = plan.total
    result.oov = plan.untypeable
    let clock = ContinuousClock()

    for testCase in plan.cases {
        guard model.lexicon.contains(testCase.word) else {
            result.oov += 1
            continue
        }
        if testCase.bigramContext { result.bigramContexts += 1 }
        for context in [[], testCase.context] {
            let start = clock.now
            let candidates = decoder.decode(taps: testCase.taps, context: context, maxCandidates: topK)
            result.latencies.append(seconds(clock.now - start))
            var metrics = context.isEmpty ? result.noContext : result.withContext
            metrics.attempts += 1
            if let rank = candidates.firstIndex(where: { $0.word == testCase.word }) {
                metrics.found += 1
                metrics.rankSum += rank + 1
                if rank == 0 { metrics.top1 += 1 }
                if rank < 3 { metrics.top3 += 1 }
            }
            if context.isEmpty { result.noContext = metrics } else { result.withContext = metrics }
        }
    }
    return result
}

// MARK: - Reporting

func pct(_ value: Double) -> String { String(format: "%6.1f%%", value * 100) }
func rank(_ value: Double) -> String { value.isNaN ? "    n/a" : String(format: "%7.2f", value) }
func ms(_ value: Double) -> String { String(format: "%7.2f", value * 1000) }

func printSingle(_ result: BundleResult) {
    print("                     no-context   bigram-context")
    print("  top-1 accuracy    \(pct(result.noContext.top1Rate))      \(pct(result.withContext.top1Rate))")
    print("  top-3 accuracy    \(pct(result.noContext.top3Rate))      \(pct(result.withContext.top3Rate))")
    print("  recall@\(topK)         \(pct(result.noContext.recallAtK))      \(pct(result.withContext.recallAtK))")
    print("  mean rank         \(rank(result.noContext.meanRank))      \(rank(result.withContext.meanRank))")
    print("")
    print("  OOV rate          \(pct(result.oovRate))  (\(result.oov)/\(result.total))")
    print("  latency p50/p95   \(ms(result.latency(0.5))) / \(ms(result.latency(0.95))) ms")
}

func printComparison(current: BundleResult, baseline: BundleResult) {
    func deltaPct(_ a: Double, _ b: Double) -> String { String(format: "%+.1f pp", (a - b) * 100) }
    func deltaNum(_ a: Double, _ b: Double) -> String {
        (a.isNaN || b.isNaN) ? "n/a" : String(format: "%+.2f", a - b)
    }
    func deltaMs(_ a: Double, _ b: Double) -> String { String(format: "%+.2f ms", (a - b) * 1000) }
    func row(_ name: String, _ current: String, _ baseline: String, _ delta: String) {
        print("  \(name.padding(toLength: 22, withPad: " ", startingAt: 0))\(current)    \(baseline)    \(delta)")
    }
    print("  metric                current    baseline   delta (current - baseline)")
    for (label, keyPath) in [("no ctx", \BundleResult.noContext), ("bigram ctx", \BundleResult.withContext)] {
        let c = current[keyPath: keyPath], b = baseline[keyPath: keyPath]
        row("top-1 (\(label))", pct(c.top1Rate), pct(b.top1Rate), deltaPct(c.top1Rate, b.top1Rate))
        row("top-3 (\(label))", pct(c.top3Rate), pct(b.top3Rate), deltaPct(c.top3Rate, b.top3Rate))
        row("recall@\(topK) (\(label))", pct(c.recallAtK), pct(b.recallAtK), deltaPct(c.recallAtK, b.recallAtK))
        row("mean rank (\(label))", rank(c.meanRank), rank(b.meanRank), deltaNum(c.meanRank, b.meanRank))
    }
    row("OOV rate", pct(current.oovRate), pct(baseline.oovRate), deltaPct(current.oovRate, baseline.oovRate))
    row("latency p50 (ms)", ms(current.latency(0.5)), ms(baseline.latency(0.5)), deltaMs(current.latency(0.5), baseline.latency(0.5)))
    row("latency p95 (ms)", ms(current.latency(0.95)), ms(baseline.latency(0.95)), deltaMs(current.latency(0.95), baseline.latency(0.95)))
}

// MARK: - Main

let options = parseOptions(CommandLine.arguments)

let languageCodes: [String]
if options.all {
    guard let entries = try? FileManager.default.contentsOfDirectory(at: options.models, includingPropertiesForKeys: nil) else {
        fail("cannot list models directory \(options.models.path)")
    }
    languageCodes = entries
        .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("meta.bin").path) }
        .map(\.lastPathComponent)
        .sorted()
    guard !languageCodes.isEmpty else { fail("no model bundles under \(options.models.path)") }
} else {
    languageCodes = [options.lang]
}

for code in languageCodes {
    let bundleDir = options.models.appendingPathComponent(code)
    let bundle = loadBundle(at: bundleDir)
    guard let language = bundle.language else {
        fail("bundle \(code) declares no language in its meta")
    }
    let layout = language.layout1D
    let vocabulary = bundle.model.lexicon.terminals().count

    let plan = buildPlan(model: bundle.model, layout: layout, options: options)
    let result = evaluate(model: bundle.model, layout: layout, plan: plan, path: bundleDir.path)
    let bigramShare = plan.cases.isEmpty ? 0 : Double(result.bigramContexts) / Double(plan.cases.count)

    print("DecodeBench — \(code) (\(bundleDir.path))")
    print("  vocab \(vocabulary) words · n \(plan.total) · sigma \(options.sigma) · seed \(options.seed) · bigram context for \(pct(bigramShare).trimmingCharacters(in: .whitespaces)) of words")
    print("")

    if let compareDir = options.compare {
        let baselineDir = compareDir.appendingPathComponent(code)
        let baselineBundle = loadBundle(at: baselineDir)
        let baseline = evaluate(model: baselineBundle.model, layout: layout, plan: plan, path: baselineDir.path)
        print("  baseline: \(baselineDir.path)")
        printComparison(current: result, baseline: baseline)
    } else {
        printSingle(result)
    }
    print("")
}
