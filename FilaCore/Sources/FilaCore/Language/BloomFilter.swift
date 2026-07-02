import Foundation

/// A classic Bloom filter for approximate set membership. Paired with a
/// ``BloomierFilter`` it answers "is this n-gram in the model?" before trusting
/// the Bloomier value — the exact pattern the teardown found (`ngramsbloom`
/// alongside `ngramsbits`). No false negatives; a tunable false-positive rate.
public struct BloomFilter: Sendable {
    public let bitCount: Int
    public let hashCount: Int
    /// The bit array as little-endian `UInt64` words, held as `Data` so a
    /// memory-mapped blob is read in place rather than copied to the heap. Words
    /// are addressed relative to `bits.startIndex` (see ``word(_:)``).
    private let bits: Data

    init(bitCount: Int, hashCount: Int, bits: Data) {
        self.bitCount = bitCount
        self.hashCount = hashCount
        self.bits = bits
    }

    /// The `i`-th 64-bit word, assembled from little-endian bytes.
    private func word(_ i: Int) -> UInt64 {
        let o = bits.startIndex + i * 8
        var v: UInt64 = 0
        for j in 0..<8 { v |= UInt64(bits[o + j]) << (8 * j) }
        return v
    }

    private static func pack(_ words: [UInt64]) -> Data {
        var data = Data(capacity: words.count * 8)
        for w in words {
            var le = w.littleEndian
            Swift.withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func mix(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    private func indices(_ key: UInt64) -> [Int] {
        // Double hashing: h_i = h1 + i·h2, standard Kirsch–Mitzenmacher.
        let h1 = Self.mix(key)
        let h2 = Self.mix(key ^ 0x5BD1_E995_A5A5_1234) | 1
        return (0..<hashCount).map { Int((h1 &+ UInt64($0) &* h2) % UInt64(bitCount)) }
    }

    public func contains(_ key: UInt64) -> Bool {
        for idx in indices(key) {
            if word(idx >> 6) & (1 << UInt64(idx & 63)) == 0 { return false }
        }
        return true
    }

    /// Build sized for `count` keys at the target false-positive rate.
    public static func build(keys: some Collection<UInt64>, falsePositiveRate: Double = 0.001) -> BloomFilter {
        let n = max(1, keys.count)
        let m = max(64, Int((-Double(n) * log(falsePositiveRate) / (log(2) * log(2))).rounded(.up)))
        let k = max(1, Int((Double(m) / Double(n) * log(2)).rounded()))
        var words = [UInt64](repeating: 0, count: (m + 63) / 64)
        // `indices` reads only bitCount/hashCount, so a bit-less probe suffices.
        let probe = BloomFilter(bitCount: m, hashCount: k, bits: Data())
        for key in keys {
            for idx in probe.indices(key) { words[idx >> 6] |= (1 << UInt64(idx & 63)) }
        }
        return BloomFilter(bitCount: m, hashCount: k, bits: pack(words))
    }

    // MARK: Serialization (magic "BLMF")

    private static let magic: [UInt8] = Array("BLMF".utf8)

    public func serialized() -> Data {
        var data = Data()
        data.append(contentsOf: Self.magic)
        var m = UInt64(bitCount).littleEndian
        var k = UInt32(hashCount).littleEndian
        Swift.withUnsafeBytes(of: &m) { data.append(contentsOf: $0) }
        Swift.withUnsafeBytes(of: &k) { data.append(contentsOf: $0) }
        data.append(bits) // already little-endian words
        return data
    }

    /// Parse a serialized blob. Pass a memory-mapped `Data` to avoid a resident
    /// copy: the word array is taken as a slice of the same backing store.
    public init(serialized data: Data) throws {
        guard data.count >= 16 else { throw BloomierFilter.DeserializeError.truncated }
        let base = data.startIndex
        for i in 0..<4 where data[base + i] != Self.magic[i] {
            throw BloomierFilter.DeserializeError.badMagic
        }
        func u64(_ off: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(data[base + off + i]) << (8 * i) }
            return v
        }
        let m = Int(u64(4))
        var k: UInt32 = 0
        for i in 0..<4 { k |= UInt32(data[base + 12 + i]) << (8 * i) }
        let expected = 16 + ((m + 63) / 64) * 8
        guard data.count >= expected else { throw BloomierFilter.DeserializeError.truncated }
        let bits = data[(base + 16)..<(base + expected)] // sub-Data, shares (mmapped) storage
        self.init(bitCount: m, hashCount: Int(k), bits: bits)
    }
}
