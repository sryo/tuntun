import Testing
@testable import FilaCore

@Test func doubleSpaceBecomesPeriodAfterWord() {
    #expect(TypingBehavior.shouldConvertDoubleSpaceToPeriod("hello "))
    #expect(TypingBehavior.shouldConvertDoubleSpaceToPeriod("in 2020 "))
}

@Test func doubleSpaceDoesNotTriggerAfterPunctuationOrSpace() {
    #expect(!TypingBehavior.shouldConvertDoubleSpaceToPeriod("hello. "))   // already terminated
    #expect(!TypingBehavior.shouldConvertDoubleSpaceToPeriod("hello  "))   // two spaces already
    #expect(!TypingBehavior.shouldConvertDoubleSpaceToPeriod("hello"))     // no trailing space
    #expect(!TypingBehavior.shouldConvertDoubleSpaceToPeriod(""))
}

@Test func smartPunctuationMovesSpaceAfterTerminator() {
    #expect(TypingBehavior.smartPunctuation(".", before: "hello ") == ". ")
    #expect(TypingBehavior.smartPunctuation("?", before: "why ") == "? ")
}

@Test func smartPunctuationHugsCommaWithoutTrailingSpace() {
    #expect(TypingBehavior.smartPunctuation(",", before: "one ") == ",")
    #expect(TypingBehavior.smartPunctuation(";", before: "a ") == ";")
}

@Test func smartPunctuationIgnoredMidNumberAndWithoutSpace() {
    #expect(TypingBehavior.smartPunctuation(".", before: "3") == nil)     // "3.14"
    #expect(TypingBehavior.smartPunctuation(".", before: "hello") == nil) // no preceding space
    #expect(TypingBehavior.smartPunctuation("@", before: "user ") == nil) // not spacing punctuation
}
