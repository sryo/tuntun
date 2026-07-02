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
