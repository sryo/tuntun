/// The languages Fila supports, each defined by its collapsed **1D** sequence
/// (column-major QWERTY flattening into one evenly-spaced line — what the
/// decoder sees).
public enum KeyboardLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case french = "fr"       // AZERTY
    case german = "de"       // QWERTZ
    case spanish = "es"
    case italian = "it"
    case dutch = "nl"
    case portuguese = "pt-BR"
    case russian = "ru"      // ЙЦУКЕН (Cyrillic)

    /// The collapsed one-row glyph order (column-major flattening).
    public var collapsedSequence: [Character] {
        switch self {
        case .english, .italian, .dutch, .portuguese:
            return Array("qazwsxedcrfvtgbyhnujmikolp")
        case .spanish:
            return Array("qazwsxedcrfvtgbyhnujmikolpñ")
        case .french:
            return Array("aqwzsxedcrfvtgbyhnujikolpm")
        case .german:
            return Array("qaywsxedcrfvtgbzhnujmikolp")
        case .russian:
            return Array("йфяцычувскамепинртгоьшлбщдюзжхэъ")
        }
    }

    /// Collapsed one-row layout (what the decoder scores taps against).
    public var layout1D: KeyboardLayout { KeyboardLayout.make1D(collapsedSequence) }

    /// Writing system — only same-script dictionaries can be typed on a given
    /// layout, so multilingual prediction merges dictionaries within a script.
    public enum Script: Sendable { case latin, cyrillic }
    public var script: Script { self == .russian ? .cyrillic : .latin }
}
