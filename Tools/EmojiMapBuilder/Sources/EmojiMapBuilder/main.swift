import Foundation
import FilaCore

// Offline tool: regenerate FilaCore's EmojiSuggestions.swift word→emoji maps
// from the Unicode CLDR emoji annotations, filtered against each language's
// shipped vocabulary. Sources and licenses: see ATTRIBUTION.md.
//
// Inputs:
//
//  * Keywords: CLDR emoji annotations, `common/annotations/<code>.xml` plus
//    `common/annotationsDerived/<code>.xml` for sequences (Unicode License v3,
//    https://github.com/unicode-org/cldr). Each `<annotation cp="😂">` element
//    lists `|`-separated keywords; `type="tts"` elements carry the emoji's
//    name, which doubles as a keyword and marks its canonical concept.
//
//  * Popularity: Unicode's emoji frequency ranking, hardcoded below
//    (`highFrequencyTier`) because https://www.unicode.org/emoji/frequency.html
//    publishes no machine-readable download. Retrieved 2026-07-02; the page
//    groups emoji into rows by successive halving of median frequency, and the
//    tier takes rows 0–8 (347 emoji). That is deliberately wider than the top
//    ~150: common concrete nouns every language needs (car, pizza, phone,
//    moon) sit in rows 7–8, while row 9 onward is obscure enough to read as
//    noise in a candidate strip.
//
//  * Vocabulary: the shipped model bundles (`<modelsDir>/<lang>/`), loaded via
//    FilaCore, so a keyword only maps if the decoder can actually produce it.
//
// A keyword maps to an emoji when the emoji is in the frequency tier, the
// keyword is a single word of the language's lexicon, and the association is
// unambiguous: an emoji whose CLDR *name* is the keyword always wins; other
// keywords must reach at most two tier emoji (the more frequent one wins).
// Anything broader ("cara", "rojo", "face") is dropped as too generic. On top
// of the derived table, `curatedOverlay` pins entries CLDR cannot supply and
// `excludedKeywords` blocks grammar words CLDR tags for incidental reasons.
//
// Usage: EmojiMapBuilder <cldrDir> <modelsDir> <outFile>
//   cldrDir:   `<code>.xml` + `<code>_derived.xml` annotation files
//   modelsDir: shipped model bundles, `<language.rawValue>/vocab.bin` etc.
//   outFile:   the Swift source to (re)write, normally
//              FilaCore/Sources/FilaCore/Language/EmojiSuggestions.swift

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write(Data("usage: EmojiMapBuilder <cldrDir> <modelsDir> <outFile>\n".utf8))
    exit(2)
}
let cldrDir = URL(fileURLWithPath: args[1])
let modelsDir = URL(fileURLWithPath: args[2])
let outFile = URL(fileURLWithPath: args[3])

/// Unicode's emoji frequency ranking, most frequent first (see header).
let highFrequencyTier: [String] = [
    "😂", "❤️", "😍", "🤣", "😊", "🙏", "💕", "😭", "😘", "👍", "😅", "👏",
    "😁", "♥️", "🔥", "💔", "💖", "💙", "😢", "🤔", "😆", "🙄", "💪", "😉",
    "☺️", "👌", "🤗", "💜", "😔", "😎", "😇", "🌹", "🤦", "🎉", "‼️", "💞",
    "✌️", "✨", "🤷", "😱", "😌", "🌸", "🙌", "😋", "💗", "💚", "😏", "💛",
    "🙂", "💓", "🤩", "😄", "😀", "🖤", "😃", "💯", "🙈", "👇", "🎶", "😒",
    "🤭", "❣️", "❗", "😜", "💋", "👀", "😪", "😑", "💥", "🙋", "😞", "😩",
    "😡", "🤪", "👊", "☀️", "😥", "🤤", "👉", "💃", "😳", "✋", "😚", "😝",
    "😴", "🌟", "😬", "🙃", "🍀", "🌷", "😻", "😓", "⭐", "✅", "🌈", "😈",
    "🤘", "💦", "✔️", "😣", "🏃", "💐", "☹️", "🎊", "💘", "😠", "☝️", "😕",
    "🌺", "🎂", "🌻", "😐", "🖕", "💝", "🙊", "😹", "🗣️", "💫", "💀", "👑",
    "🎵", "🤞", "😛", "🔴", "😤", "🌼", "😫", "⚽", "🤙", "☕", "🏆", "🧡",
    "🎁", "⚡", "🌞", "🎈", "❌", "✊", "👋", "😲", "🌿", "🤫", "👈", "😮",
    "🙆", "🍻", "🍃", "🐶", "💁", "😰", "🤨", "😶", "🤝", "🚶", "💰", "🍓",
    "💢", "🇺🇸", "🤟", "🙁", "🚨", "💨", "🤬", "✈️", "🎀", "🍺", "🤓", "😙",
    "💟", "🌱", "😖", "👶", "▶️", "➡️", "❓", "💎", "💸", "⬇️", "😨", "🌚",
    "🦋", "😷", "🕺", "⚠️", "🙅", "😟", "😵", "👎", "🤲", "🤠", "🤧", "📌",
    "🔵", "💅", "🧐", "🐾", "🍒", "😗", "🤑", "🚀", "🌊", "🤯", "🐷", "☎️",
    "💧", "😯", "💆", "👆", "🎤", "🙇", "🍑", "❄️", "🌴", "🇧🇷", "💣", "🐸",
    "💌", "📍", "🥀", "🤢", "👅", "💡", "💩", "⁉️", "👐", "📸", "👻", "🤐",
    "🤮", "🎼", "✍️", "🚩", "🍎", "🍊", "👼", "💍", "📣", "🥂", "⤵️", "📱",
    "☔", "🌙", "🍾", "🎧", "🍁", "⭕", "🏀", "☠️", "⚫", "🖐️", "😧", "🎯",
    "📲", "☘️", "👁️", "🍷", "👄", "🐟", "🍰", "💤", "🕊️", "📺", "💭", "🐱",
    "🐝", "🇲🇽", "🧚", "🔝", "📢", "📷", "🐕", "🎸", "🔫", "🤚", "🍭", "🍆",
    "💉", "🌎", "😦", "🌀", "👿", "☑️", "🎥", "🌧️", "👽", "🍋", "🤒", "🤡",
    "🍫", "📚", "🏁", "🤕", "🦄", "🍅", "🚗", "🚫", "💵", "⚾", "🔪", "🔔",
    "♨️", "🌳", "🔊", "🍬", "💏", "🍼", "🍜", "🐼", "🙉", "🐈", "🐻", "🤸",
    "🌝", "👸", "🍕", "🍌", "🍦", "⚪", "👩", "😿", "🍂", "📞", "⏰", "🔞",
    "🌍", "🌠", "🙀", "▪️", "☁️", "👹", "🍉", "🐥", "🌶️", "1️⃣", "🌵", "🇮🇳",
    "👧", "🍄", "👮", "💮", "🐰", "🔷", "🌾", "🔹", "🇹🇷", "🥇", "🇮🇹",
]

let configs: [(cldrCode: String, language: KeyboardLanguage)] = [
    ("en", .english), ("fr", .french), ("de", .german), ("es", .spanish),
    ("it", .italian), ("nl", .dutch), ("pt", .portuguese), ("ru", .russian),
]

/// Closed-class grammar words and numerals that CLDR tags onto emoji for
/// incidental reasons ("un" on 1️⃣, "в" on 🏁 via "в клетку", "bij" the
/// preposition on 🐝 the bee, "new" via "new moon"). They are among the most
/// frequent words of each language, so an emoji riding along on every article
/// or pronoun would be pure noise. Content words stay, however common —
/// "merci", "gracias", "да" are exactly what the map is for.
let excludedKeywords: [KeyboardLanguage: Set<String>] = [
    .english: ["me", "this", "here", "who", "out", "off", "over", "back", "away",
               "again", "go", "got", "well", "way", "time", "new", "big", "won",
               "place", "one", "two", "three", "keep", "like"],
    .french: ["est", "un", "une", "moi", "ici", "rien", "comment", "air", "petit",
              "deux", "trois"],
    .german: ["ich", "nicht", "mal", "weiß", "muss", "kein", "ohne", "gute",
              "morgen", "nacht", "ein", "eine", "eins", "zwei", "drei"],
    .spanish: ["o", "este", "esta", "uno", "una", "dos", "tres"],
    .italian: ["io", "tu", "qui", "tutto", "uno", "una", "due", "tre", "andare",
               "lavoro", "ah", "eh", "oh", "uh"],
    .dutch: ["een", "één", "twee", "drie", "dit", "uit", "bij", "kom", "weg",
             "houden", "werk"],
    .portuguese: ["o", "eu", "um", "uma", "dois", "duas", "três", "ser", "fazer",
                  "anos", "grande"],
    .russian: ["что", "в", "и", "так", "все", "за", "когда", "вот", "быть",
               "почему", "очень", "ничего", "больше", "хотел", "много", "себе",
               "вместе", "один", "одна", "два", "две", "три", "день"],
]

/// Entries CLDR cannot supply, applied last so they win any collision. Two
/// kinds: chat slang the annotations will never carry ("kkkk", "mdr", "jaja"),
/// and anchors the product pins in FilaCoreTests — the love→❤️ family (CLDR
/// scatters "love" across a dozen hearts, so the specificity filter drops it),
/// привет→👋 (CLDR ru ranks 🤗 above the wave), and Rioplatense "auto"→🚗
/// (absent from CLDR's base-es annotations).
let curatedOverlay: [KeyboardLanguage: [String: String]] = [
    .english: ["love": "❤️", "lol": "😂", "haha": "😂"],
    .french: ["amour": "❤️", "lol": "😂", "mdr": "😂", "haha": "😂"],
    .german: ["liebe": "❤️", "lol": "😂", "haha": "😂"],
    .spanish: ["amor": "❤️", "jaja": "😂", "jajaja": "😂", "lol": "😂", "auto": "🚗"],
    .italian: ["amore": "❤️", "ahah": "😂", "haha": "😂", "lol": "😂"],
    .dutch: ["liefde": "❤️", "lol": "😂", "haha": "😂"],
    .portuguese: ["amor": "❤️", "kkk": "😂", "kkkk": "😂", "rsrs": "😂", "haha": "😂"],
    .russian: ["любовь": "❤️", "лол": "😂", "ахаха": "😂", "хаха": "😂", "привет": "👋"],
]

/// Emoji matching ignores the variation selector: CLDR writes unqualified code
/// points (`cp="❤"`) where the frequency page publishes qualified ones (❤️).
/// The qualified tier form is what the generated map emits.
func dequalified(_ emoji: String) -> String {
    String(String.UnicodeScalarView(emoji.unicodeScalars.filter { $0.value != 0xFE0F }))
}

/// Skin-tone variants carry the same keywords as their base emoji; only the
/// base belongs in the map.
func hasSkinToneModifier(_ emoji: String) -> Bool {
    emoji.unicodeScalars.contains { (0x1F3FB...0x1F3FF).contains($0.value) }
}

/// Collects `<annotation cp="…">kw | kw | …</annotation>` elements; `tts`
/// entries are both keywords and the emoji's name.
final class AnnotationParser: NSObject, XMLParserDelegate {
    private(set) var keywords: [String: Set<String>] = [:] // dequalified cp → keywords
    private(set) var names: [String: Set<String>] = [:] // dequalified cp → tts names
    private var currentCp: String?
    private var currentIsName = false
    private var currentText = ""

    func parse(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw parser.parserError ?? CocoaError(.fileReadCorruptFile)
        }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        guard name == "annotation", let cp = attributes["cp"] else { return }
        currentCp = dequalified(cp)
        currentIsName = attributes["type"] == "tts"
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentCp != nil { currentText += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        guard name == "annotation", let cp = currentCp else { return }
        currentCp = nil
        guard !hasSkinToneModifier(cp) else { return }
        let words = currentText.split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        keywords[cp, default: []].formUnion(words)
        if currentIsName { names[cp, default: []].formUnion(words) }
    }
}

var tierRank: [String: (rank: Int, emoji: String)] = [:]
for (rank, emoji) in highFrequencyTier.enumerated() {
    let key = dequalified(emoji)
    if tierRank[key] == nil { tierRank[key] = (rank, emoji) }
}

var generatedMaps: [(language: KeyboardLanguage, map: [String: String])] = []
for (cldrCode, language) in configs {
    let annotations = AnnotationParser()
    try annotations.parse(cldrDir.appendingPathComponent("\(cldrCode).xml"))
    try annotations.parse(cldrDir.appendingPathComponent("\(cldrCode)_derived.xml"))

    let lexicon = try QuantizedNGramModel
        .load(from: modelsDir.appendingPathComponent(language.rawValue))
        .lexicon
    let excluded = excludedKeywords[language] ?? []

    // Invert emoji→keywords into keyword→candidate emoji.
    var candidates: [String: Set<String>] = [:]
    for (cp, words) in annotations.keywords {
        guard tierRank[cp] != nil else { continue }
        for word in words {
            guard !word.contains(where: \.isWhitespace),
                  !excluded.contains(word),
                  lexicon.contains(word) else { continue }
            candidates[word, default: []].insert(cp)
        }
    }

    var map: [String: String] = [:]
    for (word, cps) in candidates {
        let ranked = cps.compactMap { tierRank[$0] }.sorted { $0.rank < $1.rank }
        if let named = ranked.first(where: { annotations.names[dequalified($0.emoji)]?.contains(word) == true }) {
            map[word] = named.emoji
        } else if ranked.count <= 2, let best = ranked.first {
            map[word] = best.emoji
        }
    }
    for (word, emoji) in curatedOverlay[language] ?? [:] { map[word] = emoji }
    generatedMaps.append((language, map))
}

// MARK: - Emit the Swift source

func swiftLiteral(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

func mapLiteral(name: String, map: [String: String]) -> String {
    var lines = ["    private static let \(name): [String: String] = ["]
    var line = ""
    for key in map.keys.sorted() {
        let entry = "\(swiftLiteral(key)): \(swiftLiteral(map[key]!)),"
        if line.isEmpty {
            line = "        " + entry
        } else if line.count + entry.count + 1 <= 96 {
            line += " " + entry
        } else {
            lines.append(line)
            line = "        " + entry
        }
    }
    if !line.isEmpty { lines.append(line) }
    lines.append("    ]")
    return lines.joined(separator: "\n")
}

let caseNames: [KeyboardLanguage: String] = [
    .english: "english", .french: "french", .german: "german", .spanish: "spanish",
    .italian: "italian", .dutch: "dutch", .portuguese: "portuguese", .russian: "russian",
]

var source = """
// Generated by Tools/EmojiMapBuilder — do not edit by hand.
// Regenerate with Tools/rebuild-emoji-maps.sh.

/// A word→emoji map per language so the candidate strip can suggest an emoji
/// for the word being typed ("smart emoji"). Lookup is language-scoped with no
/// cross-language fallback, so false friends never fire (German "gift" is
/// poison, not 🎁; Portuguese "bravo" is angry, not 👏). Keys are lowercase
/// display forms, diacritics included, matching what the decoder emits before
/// casing is applied.
public enum EmojiSuggestions {
    public static func emoji(for word: String, language: KeyboardLanguage) -> String? {
        maps[language]?[word.lowercased()]
    }

    /// Every trigger word for one language (tests assert map invariants).
    static func allWords(for language: KeyboardLanguage) -> [String] {
        maps[language].map { Array($0.keys) } ?? []
    }

    private static let maps: [KeyboardLanguage: [String: String]] = [
        .english: english, .french: french, .german: german, .spanish: spanish,
        .italian: italian, .dutch: dutch, .portuguese: portuguese, .russian: russian,
    ]

"""

source += "\n"
source += generatedMaps
    .map { mapLiteral(name: caseNames[$0.language]!, map: $0.map) }
    .joined(separator: "\n\n")
source += "\n}\n"

try Data(source.utf8).write(to: outFile)
for (language, map) in generatedMaps {
    print("\(language.rawValue): \(map.count) trigger words")
}
print("wrote \(outFile.path)")
