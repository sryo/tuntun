import Testing
@testable import FilaCore

@Test func everyLanguageProducesValidPlanes() {
    for language in KeyboardLanguage.allCases {
        let layout = language.layout1D
        #expect(!layout.keys.isEmpty, "\(language) has no keys")
        for key in layout.keys {
            #expect(key.normalizedX >= 0 && key.normalizedX <= 1,
                    "\(language) key \(key.letter) x=\(key.normalizedX) out of range")
        }
    }
}

@Test func collapsedSequenceIsColumnMajorAndEvenlySpaced() {
    // English 1D is a column-major flattening of QWERTY.
    let en = KeyboardLanguage.english
    #expect(String(en.collapsedSequence) == "qazwsxedcrfvtgbyhnujmikolp")
    let keys = en.layout1D.keys
    // Evenly spaced, strictly increasing x.
    for i in 1..<keys.count {
        #expect(keys[i].normalizedX > keys[i - 1].normalizedX)
    }
    // Column-mates q/a/z are adjacent (the source of tap ambiguity).
    let q = en.layout1D.geometry(for: "q")!.normalizedX
    let a = en.layout1D.geometry(for: "a")!.normalizedX
    let z = en.layout1D.geometry(for: "z")!.normalizedX
    #expect(q < a && a < z)
    #expect(abs((a - q) - (z - a)) < 1e-9) // uniform spacing
}

@Test func azertyDiffersFromQwerty() {
    // French 1D starts with 'a' (AZERTY), English with 'q'.
    #expect(KeyboardLanguage.french.collapsedSequence.first == "a")
    #expect(KeyboardLanguage.english.collapsedSequence.first == "q")
}

@Test func germanSwapsYandZ() {
    // QWERTZ: the 1D sequence has 'y' where English has 'z' in the first column.
    #expect(String(KeyboardLanguage.german.collapsedSequence).hasPrefix("qay"))
}

@Test func cyrillicPlanesHaveCyrillicLetters() {
    let ru = KeyboardLanguage.russian
    #expect(ru.layout1D.geometry(for: "й") != nil)
    #expect(ru.layout1D.geometry(for: "q") == nil) // no Latin
}

@Test func spanishAddsEnyeKey() {
    #expect(KeyboardLanguage.spanish.layout1D.geometry(for: "ñ") != nil)
}

// MARK: - Transliteration

@Test func apostrophesAndHyphensAreSilent() {
    let en = KeyboardLanguage.english.transliterator
    #expect(en.keySequence(for: "don't") == "dont")
    #expect(en.keySequence(for: "don\u{2019}t") == "dont") // typographic apostrophe
    #expect(en.keySequence(for: "well-known") == "wellknown")
    #expect(en.keySequence(for: "'") == nil) // nothing typeable left
}

@Test func accentsFoldOntoBaseKeys() {
    #expect(KeyboardLanguage.french.transliterator.keySequence(for: "été") == "ete")
    #expect(KeyboardLanguage.french.transliterator.keySequence(for: "être") == "etre")
    #expect(KeyboardLanguage.french.transliterator.keySequence(for: "cœur") == "coeur")
    #expect(KeyboardLanguage.german.transliterator.keySequence(for: "für") == "fur")
    #expect(KeyboardLanguage.german.transliterator.keySequence(for: "weiß") == "weiss")
    #expect(KeyboardLanguage.portuguese.transliterator.keySequence(for: "não") == "nao")
    #expect(KeyboardLanguage.portuguese.transliterator.keySequence(for: "coração") == "coracao")
}

@Test func ownKeyLettersPassThroughBeforeFolding() {
    // ñ is a Spanish key, so it must NOT fold to n on the Spanish layout…
    #expect(KeyboardLanguage.spanish.transliterator.keySequence(for: "año") == "año")
    // …but folds onto n for layouts that lack the key.
    #expect(KeyboardLanguage.english.transliterator.keySequence(for: "año") == "ano")
}

@Test func russianYoFoldsOntoYe() {
    // ё has no key on the collapsed ЙЦУКЕН row; й does.
    let ru = KeyboardLanguage.russian.transliterator
    #expect(ru.keySequence(for: "всё") == "все")
    #expect(ru.keySequence(for: "ещё") == "еще")
    #expect(ru.keySequence(for: "чей") == "чей")
}

@Test func untypeableWordsAreRejected() {
    let en = KeyboardLanguage.english.transliterator
    #expect(en.keySequence(for: "añ0") == nil)   // digit
    #expect(en.keySequence(for: "привет") == nil) // wrong script
}
