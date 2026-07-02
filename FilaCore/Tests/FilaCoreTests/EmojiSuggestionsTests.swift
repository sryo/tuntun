import Testing
@testable import FilaCore

@Test func everyLanguageSuggestsCoreConcepts() {
    let love: [(KeyboardLanguage, String)] = [
        (.english, "love"), (.french, "amour"), (.german, "liebe"), (.spanish, "amor"),
        (.italian, "amore"), (.dutch, "liefde"), (.portuguese, "amor"), (.russian, "любовь"),
    ]
    for (language, word) in love {
        #expect(EmojiSuggestions.emoji(for: word, language: language) == "❤️")
    }
    let fire: [(KeyboardLanguage, String)] = [
        (.english, "fire"), (.french, "feu"), (.german, "feuer"), (.spanish, "fuego"),
        (.italian, "fuoco"), (.dutch, "vuur"), (.portuguese, "fogo"), (.russian, "огонь"),
    ]
    for (language, word) in fire {
        #expect(EmojiSuggestions.emoji(for: word, language: language) == "🔥")
    }
}

// CLDR-derived coverage: "auto" is the everyday word for car in these four
// languages (in Spanish via the curated Rioplatense entry).
@Test func autoSuggestsCarWhereAutoMeansCar() {
    for language in [KeyboardLanguage.spanish, .german, .dutch, .italian] {
        #expect(EmojiSuggestions.emoji(for: "auto", language: language) == "🚗")
    }
}

// Chat slang comes from the curated overlay, not CLDR.
@Test func slangSuggestsLaughter() {
    let slang: [(KeyboardLanguage, String)] = [
        (.english, "lol"), (.french, "mdr"), (.spanish, "jaja"), (.italian, "ahah"),
        (.portuguese, "kkkk"), (.portuguese, "rsrs"), (.russian, "лол"), (.russian, "ахаха"),
    ]
    for (language, word) in slang {
        #expect(EmojiSuggestions.emoji(for: word, language: language) == "😂")
    }
}

@Test func lookupIsLanguageScoped() {
    #expect(EmojiSuggestions.emoji(for: "amour", language: .english) == nil)
    #expect(EmojiSuggestions.emoji(for: "love", language: .russian) == nil)
    // False friends must not leak across languages: German Gift is poison,
    // Portuguese bravo is angry.
    #expect(EmojiSuggestions.emoji(for: "gift", language: .german) == nil)
    #expect(EmojiSuggestions.emoji(for: "bravo", language: .portuguese) == nil)
    #expect(EmojiSuggestions.emoji(for: "bravo", language: .russian) == nil)
}

@Test func lookupFoldsCase() {
    #expect(EmojiSuggestions.emoji(for: "Liebe", language: .german) == "❤️")
    #expect(EmojiSuggestions.emoji(for: "ПРИВЕТ", language: .russian) == "👋")
}

// Lookup lowercases the incoming word, so an uppercase key could never match.
@Test func allMapKeysAreLowercase() {
    for language in KeyboardLanguage.allCases {
        for word in EmojiSuggestions.allWords(for: language) {
            #expect(word == word.lowercased(), "non-lowercase key '\(word)' in \(language)")
        }
    }
}

@Test func everyLanguageHasAMap() {
    for language in KeyboardLanguage.allCases {
        #expect(!EmojiSuggestions.allWords(for: language).isEmpty, "\(language) has no emoji map")
    }
}
