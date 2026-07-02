/// A single physical key in the full QWERTY grid, projected onto the horizontal
/// axis of the collapsed Fila row.
///
/// Fila's core trick is to discard the vertical dimension: every letter keeps
/// its natural QWERTY *horizontal* position, so typing becomes a 1-D motion. A
/// tap at some x is therefore ambiguous between the ~3 letters stacked in that
/// column — disambiguation is deferred to the decoder, not the tap.
public struct KeyGeometry: Sendable, Equatable {
    public let letter: Character
    /// Row in the source QWERTY grid: 0 = top (QWERTY…), 1 = home (ASDF…), 2 = bottom (ZXCV…).
    public let row: Int
    /// Horizontal centre in normalized coordinates, 0 = left edge, 1 = right edge of the row.
    public let normalizedX: Double

    public init(letter: Character, row: Int, normalizedX: Double) {
        self.letter = letter
        self.row = row
        self.normalizedX = normalizedX
    }
}

/// The immutable geometry of the compressed single-row keyboard.
///
/// This is fully determined by standard staggered-QWERTY key positions and is
/// independent of any platform rendering. The extension supplies real touch
/// points in normalized [0,1] space; the decoder scores them against these
/// letter centres via the ``SpatialModel``.
public struct KeyboardLayout: Sendable {
    public let keys: [KeyGeometry]
    /// Letters indexed for fast lookup.
    public let keysByLetter: [Character: KeyGeometry]

    public init(keys: [KeyGeometry]) {
        self.keys = keys
        self.keysByLetter = Dictionary(uniqueKeysWithValues: keys.map { ($0.letter, $0) })
    }

    public func geometry(for letter: Character) -> KeyGeometry? {
        keysByLetter[Character(letter.lowercased())]
    }

    /// Build the collapsed one-row (1D) layout from an ordered glyph sequence.
    ///
    /// QWERTY flattened **column-major** — q,a,z, w,s,x, e,d,c, … — into a single
    /// evenly-spaced line. A tap's x is ambiguous between the ~3 adjacent glyphs
    /// of a column; the decoder resolves it. Every glyph sits on one baseline
    /// (row 0) — there are no vertical bands.
    public static func make1D(_ sequence: [Character]) -> KeyboardLayout {
        let count = max(sequence.count, 1)
        let keys = sequence.enumerated().map { index, ch in
            // `row` cycles 0,1,2,0,1,2… down the line; the renderer nudges each
            // glyph's y by (row-1) so the single line gently zig-zags up/mid/down.
            KeyGeometry(letter: ch, row: index % 3, normalizedX: (Double(index) + 0.5) / Double(count))
        }
        return KeyboardLayout(keys: keys)
    }

    /// A single flat row of precise keys (all on the middle baseline, `row = 1`,
    /// so the renderer draws them level with no zig-zag). Used for the numbers
    /// and symbols planes.
    public static func makeRow(_ sequence: [Character]) -> KeyboardLayout {
        let count = max(sequence.count, 1)
        let keys = sequence.enumerated().map { index, ch in
            KeyGeometry(letter: ch, row: 1, normalizedX: (Double(index) + 0.5) / Double(count))
        }
        return KeyboardLayout(keys: keys)
    }

    /// Numbers plane.
    public static let numbers1D = makeRow(Array("1234567890-/:"))

    /// Symbols plane.
    public static let symbols1D = makeRow(Array("~$%^&*+=<>|;'\"@#()_!,.?[]"))

    /// The faint secondary hint line shown above the letters (numbers +
    /// punctuation), rendered dim near the top.
    public static let lettersHint1D = makeRow(Array("1234567890:;'\"@#()_!,.?-/"))
}
