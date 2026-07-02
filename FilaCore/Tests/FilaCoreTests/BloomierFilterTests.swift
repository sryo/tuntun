import Testing
import Foundation
@testable import FilaCore

private func makeEntries(_ count: Int) -> [UInt64: UInt8] {
    var entries: [UInt64: UInt8] = [:]
    var x: UInt64 = 0x1234_5678
    for i in 0..<count {
        // Deterministic pseudo-random keys (no RNG so tests are reproducible).
        x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        entries[x] = UInt8(truncatingIfNeeded: i * 7 + 3)
    }
    return entries
}

@Test func bloomierReturnsStoredValuesForAllKeys() throws {
    let entries = makeEntries(500)
    let filter = try BloomierFilter.build(entries: entries)
    for (key, value) in entries {
        #expect(filter.lookup(key) == value, "key \(key) should map to \(value)")
    }
}

@Test func bloomierScalesToManyKeys() throws {
    let entries = makeEntries(20_000)
    let filter = try BloomierFilter.build(entries: entries)
    // Cell overhead should stay near the ~1.25x load factor.
    #expect(filter.cellCount < entries.count * 2)
    for (key, value) in entries {
        #expect(filter.lookup(key) == value)
    }
}

@Test func bloomierSerializationRoundTrips() throws {
    let entries = makeEntries(1_000)
    let filter = try BloomierFilter.build(entries: entries)
    let data = filter.serialized()
    let restored = try BloomierFilter(serialized: data)
    #expect(restored.cellCount == filter.cellCount)
    #expect(restored.seed == filter.seed)
    for (key, value) in entries {
        #expect(restored.lookup(key) == value)
    }
}

@Test func bloomierMemoryMapRoundTrips() throws {
    let entries = makeEntries(2_000)
    let filter = try BloomierFilter.build(entries: entries)
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("tuntun-bloomier-\(entries.count).bin")
    try filter.serialized().write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let mapped = try Data(contentsOf: url, options: .mappedIfSafe)
    let restored = try BloomierFilter(serialized: mapped)
    for (key, value) in entries {
        #expect(restored.lookup(key) == value)
    }
}

@Test func bloomierRejectsBadMagic() {
    var junk = Data([0x00, 0x01, 0x02, 0x03])
    junk.append(contentsOf: [UInt8](repeating: 0, count: 40))
    #expect(throws: BloomierFilter.DeserializeError.self) {
        _ = try BloomierFilter(serialized: junk)
    }
}
