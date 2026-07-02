import Foundation

/// Binary layout so the filter can be built offline and memory-mapped in place
/// from the shipped model bundle, keeping the keyboard extension's resident
/// memory low.
///
/// Header (little-endian): magic "BLMR" · version u32 · hashCount u32 ·
/// cellCount u64 · seed u64, followed by `cellCount` table bytes.
extension BloomierFilter {
    private static let magic: [UInt8] = Array("BLMR".utf8)
    private static let version: UInt32 = 1
    private static let headerSize = 4 + 4 + 4 + 8 + 8

    public func serialized() -> Data {
        var data = Data()
        data.append(contentsOf: Self.magic)
        data.appendLE(Self.version)
        data.appendLE(UInt32(hashCount))
        data.appendLE(UInt64(cellCount))
        data.appendLE(seed)
        data.append(table)
        return data
    }

    /// Parse a serialized blob. Pass a memory-mapped `Data`
    /// (`Data(contentsOf:options:.mappedIfSafe)`) to avoid resident copies: the
    /// header is read byte-by-byte and the cell table is taken as a *slice* of the
    /// same backing store, so the mapping is never materialized into the heap.
    public init(serialized data: Data) throws {
        guard data.count >= Self.headerSize else { throw DeserializeError.truncated }
        let base = data.startIndex
        func u32(_ o: Int) -> UInt32 {
            var v: UInt32 = 0
            for i in 0..<4 { v |= UInt32(data[base + o + i]) << (8 * i) }
            return v
        }
        func u64(_ o: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(data[base + o + i]) << (8 * i) }
            return v
        }
        for i in 0..<4 where data[base + i] != Self.magic[i] { throw DeserializeError.badMagic }
        let version = u32(4)
        guard version == Self.version else { throw DeserializeError.unsupportedVersion(version) }
        let hashCount = u32(8)
        let cellCount = u64(12)
        let seed = u64(20)
        let expected = Self.headerSize + Int(cellCount)
        guard data.count >= expected else { throw DeserializeError.truncated }
        // Sub-Data sharing `data`'s (possibly mmapped) storage — no copy.
        let table = data[(base + Self.headerSize)..<(base + expected)]
        self.init(cellCount: Int(cellCount), hashCount: Int(hashCount), seed: seed, table: table)
    }

    public enum DeserializeError: Error, Equatable {
        case truncated, badMagic, unsupportedVersion(UInt32)
    }
}

// MARK: - Little-endian helpers

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
