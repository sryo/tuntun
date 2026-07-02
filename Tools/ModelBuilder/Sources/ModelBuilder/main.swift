import Foundation
import FilaCore

// Offline tool: build per-language Fila model bundles (vocab + Bloomier bigrams
// + meta) that the app bundles and the keyboard extension memory-maps.
//
// Two inputs, both derived from OpenSubtitles so their statistics agree:
//
//  * Unigrams: Hermit Dave's FrequencyWords FULL 2018 lists
//    (https://github.com/hermitdave/FrequencyWords, CC-BY-SA 4.0) — the whole
//    list, cleaned (see `cleanedListWord`), is the ranking source; the top
//    `maxWords` per language ship. The 2018 tokenizer split clitics
//    ("don't" → "don" + "'t", "c'est" → "c'" + "est") and routed Brazilian
//    Portuguese hyphenated clitics ("deixe-me") to the `_ignored` file, so:
//      – apostrophe forms are restored from the raw corpus (below) with counts
//        rescaled into the list's count space by the total-token ratio;
//      – pt-BR clitic forms are merged back from `{code}_ignored.txt`;
//      – bare fragments ("'t", "c'") and English orphan stems ("didn") drop.
//
//  * Bigrams (and the apostrophe restoration): a raw-text slice of the OPUS
//    OpenSubtitles v2018 mono corpora (one sentence per line), e.g.
//    curl -r 0-41943039 https://object.pouta.csc.fi/OPUS-OpenSubtitles/v2018/mono/{code}.txt.gz
//    (a truncated gzip prefix decompresses to a valid line stream).
//
// Usage: ModelBuilder <freqDir> <corpusDir> <outDir> [maxBigrams]
//   freqDir:   `{code}_full.txt` files (word<space>count per line), plus the
//              optional `pt_br_ignored.txt` clitic source
//   corpusDir: `{code}.txt` files (raw sentences, UTF-8)
//   outDir:    writes <outDir>/<language.rawValue>/{vocab,membership,values,meta}

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write(Data("usage: ModelBuilder <freqDir> <corpusDir> <outDir> [maxBigrams]\n".utf8))
    exit(2)
}
let freqDir = URL(fileURLWithPath: args[1])
let corpusDir = URL(fileURLWithPath: args[2])
let outDir = URL(fileURLWithPath: args[3])
let maxBigrams = args.count > 4 ? Int(args[4]) ?? 200_000 : 200_000

/// Per-language vocabulary budget and cleaning thresholds.
///
/// `maxWords` balances corpus coverage against the extension's resident trie
/// (~250 B/word measured): 80k ≈ 20 MB, 100k ≈ 25 MB. German and Russian get
/// the deeper cut for compounding/morphology; coverage research suggested
/// 100–150k everywhere, but that costs 25–37 MB of trie against a ~50 MB
/// keyboard-extension ceiling. `minCount` floors cut the OCR/typo tail.
/// `maxRun` drops elongations ("sooooo"); German allows triple letters
/// (Schifffahrt) and longer compounds.
struct LanguageConfig {
    let code: String
    let language: KeyboardLanguage
    let maxWords: Int
    let minCount: Int
    let maxLength: Int
    let maxRun: Int
    let mergeIgnoredClitics: Bool

    init(_ code: String, _ language: KeyboardLanguage, maxWords: Int, minCount: Int,
         maxLength: Int = 24, maxRun: Int = 3, mergeIgnoredClitics: Bool = false) {
        self.code = code
        self.language = language
        self.maxWords = maxWords
        self.minCount = minCount
        self.maxLength = maxLength
        self.maxRun = maxRun
        self.mergeIgnoredClitics = mergeIgnoredClitics
    }
}

let configs: [LanguageConfig] = [
    LanguageConfig("en", .english, maxWords: 80_000, minCount: 40),
    LanguageConfig("fr", .french, maxWords: 80_000, minCount: 25),
    LanguageConfig("de", .german, maxWords: 100_000, minCount: 10, maxLength: 32, maxRun: 4),
    LanguageConfig("es", .spanish, maxWords: 80_000, minCount: 30),
    LanguageConfig("it", .italian, maxWords: 80_000, minCount: 25),
    LanguageConfig("nl", .dutch, maxWords: 80_000, minCount: 20),
    LanguageConfig("pt_br", .portuguese, maxWords: 80_000, minCount: 30, mergeIgnoredClitics: true),
    LanguageConfig("ru", .russian, maxWords: 100_000, minCount: 25),
]

/// Single characters that are real words in each language (everything else
/// single-char in the lists is tokenizer shrapnel).
let singleCharWords: [KeyboardLanguage: Set<String>] = [
    .english: ["a", "i"],
    .french: ["a", "e", "o", "à", "é", "y"],
    .german: [],
    .spanish: ["a", "e", "o", "u", "y"],
    .italian: ["a", "e", "è", "i", "o"],
    .dutch: ["u"],
    .portuguese: ["a", "à", "e", "é", "o"],
    .russian: ["а", "в", "и", "к", "о", "с", "у", "я"],
]

/// Words legitimately spelled with an edge apostrophe (Italian truncations,
/// English informal clippings). Every other edge-apostrophe list entry is a
/// split-clitic fragment ("'t", "c'", "l'") and is dropped.
let edgeApostropheWords: [KeyboardLanguage: Set<String>] = [
    .english: ["'em", "'cause"],
    .italian: ["po'", "va'", "fa'", "sta'", "da'", "di'", "mo'"],
]

/// Abbreviations kept despite the '.', typed via their letters (the period is a
/// silent transliteration character).
let dottedAbbreviations: Set<String> = [
    "mr.", "mrs.", "ms.", "dr.", "st.", "jr.", "sr.", "sra.", "prof.", "vs.",
]

/// English stems that only exist because the 2018 tokenizer amputated "n't"
/// ("didn't" → "didn" + "'t"). "don" is included: its list count is almost
/// entirely don't-shrapnel. Real homographs with independent use (won, can,
/// haven) stay.
let englishOrphanStems: Set<String> = [
    "don", "didn", "isn", "wasn", "doesn", "couldn", "shouldn", "wouldn",
    "hasn", "hadn", "aren", "weren", "ain", "needn", "mustn", "mightn",
    "oughtn", "shan",
]

/// pt-BR verb + clitic pronoun forms ("deixe-me", "vê-lo") the 2018 pipeline
/// routed to the ignored file.
let ptCliticPattern = try! NSRegularExpression(
    pattern: "^\\p{L}+-(?:me|te|se|lhe|lhes|nos|vos|lo|la|los|las|no|na|nas)$")
let ptCliticMinCount = 30

/// Splits a line into display-form tokens: runs of letters with word-internal
/// apostrophes/hyphens kept ("don't", "c'est", "est-ce"), lowercased, curly
/// apostrophes straightened. Sentence punctuation between tokens is reported as
/// a break so bigrams never span clauses.
struct Tokenizer {
    private static let letters = CharacterSet.letters
    private static let joiners: Set<Unicode.Scalar> = ["'", "\u{2019}", "-"]
    private static let clauseBreaks: Set<Unicode.Scalar> = [".", "!", "?", ";", ":", "\u{2026}"]

    enum Piece {
        case token(String)
        case clauseBreak
    }

    static func pieces(of line: Substring) -> [Piece] {
        var out: [Piece] = []
        var current: [Unicode.Scalar] = []

        func flush() {
            // Joiners only count word-internally; strip them from the edges
            // (dialogue dashes, quoting apostrophes).
            var scalars = current
            current.removeAll(keepingCapacity: true)
            while let first = scalars.first, joiners.contains(first) { scalars.removeFirst() }
            while let last = scalars.last, joiners.contains(last) { scalars.removeLast() }
            guard !scalars.isEmpty else { return }
            let token = String(String.UnicodeScalarView(scalars))
                .lowercased()
                .replacingOccurrences(of: "\u{2019}", with: "'")
                .precomposedStringWithCanonicalMapping
            out.append(.token(token))
        }

        for scalar in line.unicodeScalars {
            if letters.contains(scalar) || joiners.contains(scalar) {
                current.append(scalar)
            } else {
                flush()
                if clauseBreaks.contains(scalar) { out.append(.clauseBreak) }
            }
        }
        flush()
        return out
    }
}

for config in configs {
    let code = config.code
    let language = config.language
    let freqFile = freqDir.appendingPathComponent("\(code)_full.txt")
    let corpusFile = corpusDir.appendingPathComponent("\(code).txt")
    guard let freqText = try? String(contentsOf: freqFile, encoding: .utf8) else {
        print("skip \(code): missing \(freqFile.path)")
        continue
    }
    guard let corpusText = try? String(contentsOf: corpusFile, encoding: .utf8) else {
        print("skip \(code): missing \(corpusFile.path)")
        continue
    }
    let transliterator = language.transliterator
    let singles = singleCharWords[language] ?? []
    let edgeKeep = edgeApostropheWords[language] ?? []

    func isJoiner(_ ch: Character) -> Bool { ch == "'" || ch == "-" }

    /// Shape gate: letters with single, word-internal joiners only.
    func isWellFormed(_ word: String) -> Bool {
        var previousWasJoiner = true // rejects a leading joiner
        for ch in word {
            if ch.isLetter {
                previousWasJoiner = false
            } else if isJoiner(ch) {
                if previousWasJoiner { return false }
                previousWasJoiner = true
            } else {
                return false
            }
        }
        return !previousWasJoiner // rejects a trailing joiner
    }

    func hasElongation(_ word: String) -> Bool {
        var run = 0
        var previous: Character? = nil
        for ch in word {
            run = ch == previous ? run + 1 : 1
            if run >= config.maxRun { return true }
            previous = ch
        }
        return false
    }

    /// Frequency-list entry → clean display form, or nil to drop.
    func cleanedListWord(_ raw: String) -> String? {
        var word = raw
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .precomposedStringWithCanonicalMapping
        guard !word.contains(where: { $0.isUppercase }) else { return nil } // OCR/case bleed
        if language == .italian && word == "e'" { word = "è" } // subtitle spelling of è
        if !dottedAbbreviations.contains(word) && !edgeKeep.contains(word) {
            guard isWellFormed(word) else { return nil }
        }
        guard word.count <= config.maxLength, !hasElongation(word) else { return nil }
        if word.count == 1 && !singles.contains(word) { return nil }
        if language == .english && englishOrphanStems.contains(word) { return nil }
        guard transliterator.keySequence(for: word) != nil else { return nil } // digits, wrong script
        return word
    }

    // 1. Clean the full frequency list, merging normalization collisions.
    var listCounts: [String: Int] = [:]
    listCounts.reserveCapacity(1 << 20)
    var listTotal = 0
    for line in freqText.split(separator: "\n") {
        let parts = line.split(separator: " ")
        guard parts.count == 2, let count = Int(parts[1]) else { continue }
        listTotal += count
        guard let word = cleanedListWord(String(parts[0])) else { continue }
        listCounts[word, default: 0] += count
    }

    // 2. pt-BR: merge hyphenated clitic forms back from the ignored file.
    var cliticsMerged = 0
    if config.mergeIgnoredClitics,
       let ignored = try? String(contentsOf: freqDir.appendingPathComponent("\(code)_ignored.txt"),
                                 encoding: .utf8) {
        for line in ignored.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let count = Int(parts[1]), count >= ptCliticMinCount else { continue }
            let token = String(parts[0])
            let range = NSRange(token.startIndex..., in: token)
            guard ptCliticPattern.firstMatch(in: token, range: range) != nil,
                  let word = cleanedListWord(token) else { continue }
            listCounts[word, default: 0] += count
            cliticsMerged += 1
        }
    }

    // 3. Corpus pass 1: total tokens + apostrophe-word counts (the forms the
    //    list's tokenizer destroyed).
    let corpusLines = corpusText.split(separator: "\n", omittingEmptySubsequences: true)
    var apostropheCounts: [String: Int] = [:]
    var corpusTotal = 0
    for line in corpusLines {
        for piece in Tokenizer.pieces(of: line) {
            guard case .token(let token) = piece else { continue }
            corpusTotal += 1
            if token.contains("'") { apostropheCounts[token, default: 0] += 1 }
        }
    }

    // 4. Restore apostrophe forms at list scale.
    let scale = corpusTotal > 0 ? Double(listTotal) / Double(corpusTotal) : 0
    var restored = 0
    for (token, count) in apostropheCounts {
        let scaled = Int((Double(count) * scale).rounded())
        guard scaled >= config.minCount, let word = cleanedListWord(token) else { continue }
        if scaled > listCounts[word, default: 0] {
            listCounts[word] = scaled
            restored += 1
        }
    }

    // 5. Vocabulary: the top maxWords by count above the noise floor.
    let unigrams = Dictionary(uniqueKeysWithValues: listCounts
        .filter { $0.value >= config.minCount }
        .sorted { $0.value > $1.value }
        .prefix(config.maxWords)
        .map { ($0.key, $0.value) })
    let vocab = Set(unigrams.keys)

    // 6. Corpus pass 2: bigram counts restricted to vocabulary pairs.
    var pairCounts: [String: [String: Int]] = [:]
    for line in corpusLines {
        var prev: String? = nil
        for piece in Tokenizer.pieces(of: line) {
            switch piece {
            case .clauseBreak:
                prev = nil
            case .token(let token):
                guard vocab.contains(token) else { prev = nil; continue }
                if let prev { pairCounts[prev, default: [:]][token, default: 0] += 1 }
                prev = token
            }
        }
    }

    // 7. Keep the strongest maxBigrams pairs; count ≥ 2 drops one-off noise.
    var flat: [(prev: String, word: String, count: Int)] = []
    flat.reserveCapacity(1 << 20)
    for (prev, following) in pairCounts {
        for (word, count) in following where count >= 2 {
            flat.append((prev, word, count))
        }
    }
    flat.sort { $0.count > $1.count }
    var bigrams: [String: [String: Int]] = [:]
    for (prev, word, count) in flat.prefix(maxBigrams) {
        bigrams[prev, default: [:]][word] = count
    }
    let bigramCount = min(flat.count, maxBigrams)

    let model = try NGramModelBuilder().build(unigrams: unigrams, bigrams: bigrams, language: language)
    let dir = outDir.appendingPathComponent(language.rawValue)
    try model.write(to: dir)
    let bytes = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]))?
        .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } ?? 0
    print("\(language.rawValue): \(unigrams.count) words " +
          "(\(restored) apostrophe forms restored, \(cliticsMerged) clitics merged), " +
          "\(bigramCount) bigrams → \(dir.lastPathComponent) (\(bytes / 1024) KB)")
}
print("done")
