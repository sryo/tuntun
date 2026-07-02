import Foundation

/// A Bloomier filter: an immutable map from a set of known integer keys to small
/// values, using ~1.23·n cells and *no* per-key key storage. Unknown keys return
/// an arbitrary value (there is no membership guarantee), which is exactly the
/// trade Fila makes for its n-gram model — known n-grams get their quantized
/// log-prob in O(1); unknown ones fall back via the caller's backoff.
///
/// Construction uses hypergraph peeling (Chazelle et al. 2004): each key maps to
/// `k` cells; we repeatedly strip keys that own a cell no other remaining key
/// touches, then assign values in reverse so each key's cells XOR to its value.
/// This is the compact, memory-mappable structure the teardown found in
/// `ngramsbits` (cellBytes/nCells/nHashes/quantized log-probs).
public struct BloomierFilter: Sendable {
    public let cellCount: Int
    public let hashCount: Int
    public let seed: UInt64
    /// One byte per cell (the teardown's model quantizes log-probs to a byte range).
    /// Held as `Data`, not `[UInt8]`, so a memory-mapped blob passed to
    /// ``init(serialized:)`` is indexed *in place* rather than copied onto the heap
    /// — this is what actually keeps the value table off the extension's resident
    /// budget. Cells are addressed relative to `table.startIndex` (a mapped slice
    /// begins at a non-zero index), see ``lookup(_:)``.
    let table: Data

    init(cellCount: Int, hashCount: Int, seed: UInt64, table: Data) {
        self.cellCount = cellCount
        self.hashCount = hashCount
        self.seed = seed
        self.table = table
    }

    // MARK: Hashing

    /// splitmix64 finalizer — cheap, well-distributed, deterministic.
    private static func mix(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// `k` distinct cell indices for a key, plus a value mask byte.
    private static func locations(key: UInt64, seed: UInt64, hashCount: Int, cellCount: Int) -> (cells: [Int], mask: UInt8) {
        var cells: [Int] = []
        cells.reserveCapacity(hashCount)
        var i: UInt64 = 0
        while cells.count < hashCount {
            let h = mix(key &+ seed &+ (i &* 0x1000_0000_0000_0001))
            let idx = Int(h % UInt64(cellCount))
            if !cells.contains(idx) { cells.append(idx) }
            i += 1
            if i > UInt64(hashCount) * 64 { break } // pathological guard
        }
        let mask = UInt8(truncatingIfNeeded: mix(key ^ 0xD1B5_4A32_D192_ED03 &+ seed))
        return (cells, mask)
    }

    // MARK: Query

    /// The value stored for `key` (arbitrary if `key` was never inserted).
    public func lookup(_ key: UInt64) -> UInt8 {
        let (cells, mask) = Self.locations(key: key, seed: seed, hashCount: hashCount, cellCount: cellCount)
        var acc: UInt8 = mask
        let base = table.startIndex
        for c in cells { acc ^= table[base + c] }
        return acc
    }

    // MARK: Construction

    public enum BuildError: Error { case peelingFailed }

    /// Build from `[key: value]`. Retries with more cells / new seeds if peeling
    /// fails (dense random hypergraphs occasionally aren't fully peelable).
    public static func build(entries: [UInt64: UInt8],
                             hashCount: Int = 3,
                             loadFactor: Double = 1.25,
                             maxAttempts: Int = 12) throws -> BloomierFilter {
        let n = entries.count
        guard n > 0 else {
            return BloomierFilter(cellCount: 1, hashCount: hashCount, seed: 0, table: Data([0]))
        }
        let keys = Array(entries.keys)
        var cellCount = max(hashCount + 1, Int((Double(n) * loadFactor).rounded(.up)))

        for attempt in 0..<maxAttempts {
            let seed = 0xA5A5_0000_0000_0001 &* UInt64(attempt + 1)
            if let order = peel(keys: keys, seed: seed, hashCount: hashCount, cellCount: cellCount) {
                let table = assign(entries: entries, order: order, seed: seed,
                                   hashCount: hashCount, cellCount: cellCount)
                return BloomierFilter(cellCount: cellCount, hashCount: hashCount, seed: seed, table: Data(table))
            }
            // Grow ~8% each failed attempt.
            cellCount = Int((Double(cellCount) * 1.08).rounded(.up))
        }
        throw BuildError.peelingFailed
    }

    /// Returns keys in the order to *assign* them (reverse peel order), or nil.
    private static func peel(keys: [UInt64], seed: UInt64, hashCount: Int, cellCount: Int) -> [(key: UInt64, cell: Int)]? {
        // Incidence: for each cell, which key-indices touch it (XOR trick for degree).
        var degree = [Int](repeating: 0, count: cellCount)
        var xorKeyIndex = [Int](repeating: 0, count: cellCount)
        let keyCells: [[Int]] = keys.map { locations(key: $0, seed: seed, hashCount: hashCount, cellCount: cellCount).cells }

        for (ki, cells) in keyCells.enumerated() {
            for c in cells { degree[c] += 1; xorKeyIndex[c] ^= ki }
        }

        var queue = (0..<cellCount).filter { degree[$0] == 1 }
        var removed = [Bool](repeating: false, count: keys.count)
        var order: [(key: UInt64, cell: Int)] = []
        order.reserveCapacity(keys.count)

        while let cell = queue.popLast() {
            guard degree[cell] == 1 else { continue }
            let ki = xorKeyIndex[cell]
            guard !removed[ki] else { continue }
            removed[ki] = true
            order.append((key: keys[ki], cell: cell))
            for c in keyCells[ki] {
                degree[c] -= 1
                xorKeyIndex[c] ^= ki
                if degree[c] == 1 { queue.append(c) }
            }
        }

        return order.count == keys.count ? order.reversed() : nil
    }

    /// Assign cell bytes so each key's cells XOR (with its mask) to its value.
    private static func assign(entries: [UInt64: UInt8], order: [(key: UInt64, cell: Int)],
                               seed: UInt64, hashCount: Int, cellCount: Int) -> [UInt8] {
        var table = [UInt8](repeating: 0, count: cellCount)
        var assigned = [Bool](repeating: false, count: cellCount)
        for (key, cell) in order {
            let (cells, mask) = locations(key: key, seed: seed, hashCount: hashCount, cellCount: cellCount)
            var acc: UInt8 = (entries[key] ?? 0) ^ mask
            for c in cells where c != cell {
                acc ^= table[c] // singleton at peel time ⇒ these are already set
            }
            table[cell] = acc
            assigned[cell] = true
        }
        return table
    }
}
