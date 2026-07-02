import Foundation

/// Builds a ``QuantizedNGramModel`` from raw corpus counts, and serializes it to
/// a directory (the App Group container in production) so the extension can
/// memory-map it instead of rebuilding at launch.
public struct NGramModelBuilder {
    public init() {}

    /// - Parameters:
    ///   - unigrams: `[word: count]`.
    ///   - bigrams: `[previousWord: [word: count]]`.
    ///   - language: keys the lexicon by this language's transliterated key
    ///     sequences (nil = words are their own key sequences).
    public func build(unigrams: [String: Int],
                      bigrams: [String: [String: Int]],
                      language: KeyboardLanguage? = nil,
                      lambda: Double = 0.7) throws -> QuantizedNGramModel {
        let lexicon = Lexicon(frequencies: unigrams,
                              transliterator: language?.transliterator ?? .identity)

        // Context tokens get the same canonicalization as at lookup time, merging
        // counts that differ only by case/trailing punctuation.
        var normalized: [String: [String: Int]] = [:]
        for (prevRaw, following) in bigrams {
            let prev = NGram.normalizeContext(prevRaw)
            guard !prev.isEmpty else { continue }
            for (word, count) in following where count > 0 {
                normalized[prev, default: [:]][word.lowercased(), default: 0] += count
            }
        }

        // Collect raw bigram log-probs to size the quantizer.
        var raw: [(key: UInt64, logProb: Double)] = []
        for (prev, following) in normalized {
            let total = Double(following.values.reduce(0, +))
            guard total > 0 else { continue }
            for (word, count) in following {
                raw.append((NGram.key([prev, word]), log(Double(count) / total)))
            }
        }

        let logs = raw.map(\.logProb)
        let quantizer = LogProbQuantizer(minLog: logs.min() ?? -12, maxLog: logs.max() ?? 0)

        var entries: [UInt64: UInt8] = [:]
        entries.reserveCapacity(raw.count)
        for (key, logProb) in raw { entries[key] = quantizer.encode(logProb) }

        let values = try BloomierFilter.build(entries: entries)
        let membership = BloomFilter.build(keys: raw.map(\.key))
        return QuantizedNGramModel(lexicon: lexicon, language: language,
                                   membership: membership,
                                   values: values, quantizer: quantizer, lambda: lambda)
    }
}

// MARK: - On-disk bundle (App Group)

public extension QuantizedNGramModel {
    enum File {
        public static let vocab = "vocab.bin"
        public static let membership = "membership.blmf"
        public static let values = "values.blmr"
        public static let meta = "meta.bin"
    }

    /// Write the four model files into `directory`.
    func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try serializeVocab().write(to: directory.appendingPathComponent(File.vocab))
        try membership.serialized().write(to: directory.appendingPathComponent(File.membership))
        try values.serialized().write(to: directory.appendingPathComponent(File.values))
        try serializeMeta().write(to: directory.appendingPathComponent(File.meta))
    }

    /// Load a model, memory-mapping the large Bloomier value table.
    static func load(from directory: URL) throws -> QuantizedNGramModel {
        let (quantizer, lambda, language) = try deserializeMeta(Data(contentsOf: directory.appendingPathComponent(File.meta)))
        let lexicon = try deserializeVocab(Data(contentsOf: directory.appendingPathComponent(File.vocab)),
                                           transliterator: language?.transliterator ?? .identity)
        let membership = try BloomFilter(serialized: Data(contentsOf: directory.appendingPathComponent(File.membership), options: .mappedIfSafe))
        let values = try BloomierFilter(serialized: Data(contentsOf: directory.appendingPathComponent(File.values), options: .mappedIfSafe))
        return QuantizedNGramModel(lexicon: lexicon, language: language,
                                   membership: membership,
                                   values: values, quantizer: quantizer, lambda: lambda)
    }

    // MARK: Vocab: u32 count, then per entry u16 len + utf8 + Float32 logPrior
    //
    // NOTE: unlike the two filters, the vocabulary is rebuilt into a resident
    // `Lexicon` trie on load (`deserializeVocab`) — it is NOT memory-mapped. The
    // trie is the decoder's search structure and is mutated for personalization,
    // so mapping it would require a separate immutable on-disk trie format (e.g. a
    // succinct/LOUDS or double-array trie queried in place). That's a larger change
    // tracked separately; for now the trie's RAM cost scales with vocabulary size.

    private func serializeVocab() -> Data {
        let terminals = lexicon.terminals()
        var data = Data()
        var count = UInt32(terminals.count).littleEndian
        Swift.withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        for (word, logPrior) in terminals {
            let utf8 = Array(word.utf8)
            var len = UInt16(utf8.count).littleEndian
            Swift.withUnsafeBytes(of: &len) { data.append(contentsOf: $0) }
            data.append(contentsOf: utf8)
            var lp = Float32(logPrior).bitPattern.littleEndian
            Swift.withUnsafeBytes(of: &lp) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func deserializeVocab(_ data: Data, transliterator: Transliterator) throws -> Lexicon {
        let bytes = [UInt8](data)
        var offset = 0
        func u16() -> Int { let v = Int(bytes[offset]) | (Int(bytes[offset+1]) << 8); offset += 2; return v }
        func u32() -> Int { var v = 0; for i in 0..<4 { v |= Int(bytes[offset+i]) << (8*i) }; offset += 4; return v }
        func f32() -> Double {
            var bits: UInt32 = 0; for i in 0..<4 { bits |= UInt32(bytes[offset+i]) << (8*i) }
            offset += 4; return Double(Float32(bitPattern: bits))
        }
        let count = u32()
        let lexicon = Lexicon(transliterator: transliterator)
        for _ in 0..<count {
            let len = u16()
            let word = String(decoding: bytes[offset..<offset+len], as: UTF8.self)
            offset += len
            lexicon.insert(word: word, logPrior: f32())
        }
        return lexicon
    }

    // MARK: Meta: magic "FMT2" · minLog, maxLog, lambda as 3 Float64 LE ·
    // u8 length + UTF-8 language code (empty = identity transliteration).

    private static let metaMagic: [UInt8] = Array("FMT2".utf8)

    private func serializeMeta() -> Data {
        var data = Data()
        data.append(contentsOf: Self.metaMagic)
        for value in [quantizer.minLog, quantizer.maxLog, lambda] {
            var bits = value.bitPattern.littleEndian
            Swift.withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        let code = Array((language?.rawValue ?? "").utf8)
        data.append(UInt8(code.count))
        data.append(contentsOf: code)
        return data
    }

    private static func deserializeMeta(_ data: Data) throws -> (LogProbQuantizer, Double, KeyboardLanguage?) {
        let bytes = [UInt8](data)
        guard bytes.count >= metaMagic.count + 25 else { throw BloomierFilter.DeserializeError.truncated }
        guard Array(bytes[0..<4]) == metaMagic else { throw BloomierFilter.DeserializeError.badMagic }
        func f64(_ off: Int) -> Double {
            var bits: UInt64 = 0; for i in 0..<8 { bits |= UInt64(bytes[off+i]) << (8*i) }
            return Double(bitPattern: bits)
        }
        let codeLen = Int(bytes[28])
        guard bytes.count >= 29 + codeLen else { throw BloomierFilter.DeserializeError.truncated }
        let code = String(decoding: bytes[29..<29+codeLen], as: UTF8.self)
        return (LogProbQuantizer(minLog: f64(4), maxLog: f64(12)), f64(20),
                code.isEmpty ? nil : KeyboardLanguage(rawValue: code))
    }
}
