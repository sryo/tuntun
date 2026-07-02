import Testing
import Foundation
@testable import FilaCore

private let en = Locale(identifier: "en")

@Test func sentenceStartDetectsDocumentStart() {
    #expect(Autocapitalization.isSentenceStart(nil))
    #expect(Autocapitalization.isSentenceStart(""))
    #expect(Autocapitalization.isSentenceStart("   "))
}

@Test func sentenceStartAfterTerminatorAndNewline() {
    #expect(Autocapitalization.isSentenceStart("Hello world. "))
    #expect(Autocapitalization.isSentenceStart("Really?! "))
    #expect(Autocapitalization.isSentenceStart("He said \"go.\" "))
    #expect(Autocapitalization.isSentenceStart("line one\n"))
}

@Test func notSentenceStartMidSentence() {
    #expect(!Autocapitalization.isSentenceStart("hello "))
    #expect(!Autocapitalization.isSentenceStart("the quick "))
    #expect(!Autocapitalization.isSentenceStart("a comma, "))
}

@Test func casesSentenceStart() {
    #expect(Autocapitalization.cased("hello", sentenceStart: true, english: true, locale: en) == "Hello")
    #expect(Autocapitalization.cased("hello", sentenceStart: false, english: true, locale: en) == "hello")
}

@Test func englishPronounAlwaysUppercase() {
    #expect(Autocapitalization.cased("i", sentenceStart: false, english: true, locale: en) == "I")
    #expect(Autocapitalization.cased("i'm", sentenceStart: false, english: true, locale: en) == "I'm")
    #expect(Autocapitalization.cased("i'll", sentenceStart: false, english: true, locale: en) == "I'll")
    // "in" is a normal word, not the pronoun.
    #expect(Autocapitalization.cased("in", sentenceStart: false, english: true, locale: en) == "in")
    // Non-English: no pronoun rule.
    #expect(Autocapitalization.cased("i", sentenceStart: false, english: false, locale: Locale(identifier: "it")) == "i")
}

@Test func emptyWordUnchanged() {
    #expect(Autocapitalization.cased("", sentenceStart: true, english: true, locale: en) == "")
}
