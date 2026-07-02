import Testing
import Foundation
@testable import FilaCore

// MARK: - Harness

/// Applies session commands to a plain string and records the full stream, so
/// tests can assert both the final document text and the exact commands emitted.
@MainActor
private final class FakeDocument {
    var text = ""
    var commands: [CompositionCommand] = []
    var strip: [DecodeCandidate] = []
    var shiftDisplay: CompositionShift = .off

    func apply(_ command: CompositionCommand) {
        commands.append(command)
        switch command {
        case .insertText(let s):     text += s
        case .deleteBackward(let n): text = String(text.dropLast(n))
        case .moveCursor:            break
        case .setStrip(let c):       strip = c
        case .setShift(let s):       shiftDisplay = s
        case .learn, .unlearn:       break
        }
    }

    func commands(after mark: Int) -> [CompositionCommand] {
        Array(commands.dropFirst(mark))
    }
}

/// Session wired to a fake document and a ladder decoder: one lowercase
/// candidate per tap count (like the real engine's top hypothesis), empty
/// beyond the ladder. `onDecode` observes the decoder's inputs.
@MainActor
private func makeSession(_ doc: FakeDocument,
                         ladder: [String] = ["h", "he", "hey"],
                         configuration: CompositionConfiguration = .init(autoCapitalize: false),
                         onDecode: (@MainActor ([Double], [String], [Int: Character]) -> Void)? = nil)
    -> CompositionSession {
    CompositionSession(
        configuration: configuration,
        decode: { taps, context, forced in
            onDecode?(taps, context, forced)
            guard !taps.isEmpty, taps.count <= ladder.count else { return [] }
            return [DecodeCandidate(word: ladder[taps.count - 1], score: 0, edits: 0)]
        },
        readTextBeforeCursor: { doc.text },
        emit: { doc.apply($0) })
}

private func candidate(_ word: String) -> DecodeCandidate {
    DecodeCandidate(word: word, score: 0, edits: 0)
}

// MARK: - Provisional replacement

@Test @MainActor func provisionalReplacementAsTapsAccumulate() {
    let doc = FakeDocument()
    let session = makeSession(doc)
    session.tap(at: 0.1)
    #expect(doc.text == "h")
    let mark = doc.commands.count
    session.tap(at: 0.2)
    #expect(doc.text == "he")
    // Strip refresh precedes the in-place rewrite of the old provisional.
    #expect(doc.commands(after: mark) == [
        .setStrip([candidate("he")]),
        .deleteBackward(count: 1),
        .insertText("he"),
    ])
    session.tap(at: 0.3)
    #expect(doc.text == "hey")
    #expect(session.isComposing)
}

// MARK: - Commit

@Test @MainActor func commitOnSpaceEmitsNoRewrite() {
    let doc = FakeDocument()
    let session = makeSession(doc)
    session.tap(at: 0.1); session.tap(at: 0.2); session.tap(at: 0.3)
    let mark = doc.commands.count
    session.insertSpace()
    #expect(doc.text == "hey ")
    // The provisional already matches the top candidate, so committing must not
    // rewrite it — only learn, clear the strip, and add the space.
    #expect(doc.commands(after: mark) == [
        .learn(word: "hey", taps: [0.1, 0.2, 0.3], edits: 0),
        .setStrip([]),
        .insertText(" "),
    ])
    #expect(!session.isComposing)
}

@Test @MainActor func doubleSpaceBecomesPeriod() {
    let doc = FakeDocument()
    let session = makeSession(doc)
    session.tap(at: 0.1); session.tap(at: 0.2); session.tap(at: 0.3)
    session.insertSpace()
    let mark = doc.commands.count
    session.insertSpace()
    #expect(doc.text == "hey. ")
    #expect(doc.commands(after: mark) == [.deleteBackward(count: 1), .insertText(". ")])

    let plain = FakeDocument()
    let plainSession = makeSession(plain, configuration: .init(autoCapitalize: false, smartSpacing: false))
    plainSession.tap(at: 0.1); plainSession.tap(at: 0.2); plainSession.tap(at: 0.3)
    plainSession.insertSpace()
    plainSession.insertSpace()
    #expect(plain.text == "hey  ")
}

@Test @MainActor func commitOnPunctuationViaInsertPrecise() {
    let doc = FakeDocument()
    let session = makeSession(doc)
    session.tap(at: 0.1); session.tap(at: 0.2); session.tap(at: 0.3)
    session.insertSpace()
    session.insertPrecise(".")
    // Smart punctuation moves the committed word's trailing space after the period.
    #expect(doc.text == "hey. ")

    let direct = FakeDocument()
    let directSession = makeSession(direct)
    directSession.tap(at: 0.1); directSession.tap(at: 0.2); directSession.tap(at: 0.3)
    directSession.insertPrecise(".")
    // No space between word and punctuation → verbatim insert, still commits.
    #expect(direct.text == "hey.")
    #expect(!directSession.isComposing)
}

@Test @MainActor func insertPreciseMultiCharSkipsSmartPunctuation() {
    let doc = FakeDocument()
    let session = makeSession(doc)
    doc.text = "hey "
    session.insertPrecise(":-)")
    #expect(doc.text == "hey :-)")
}

@Test @MainActor func candidateSelectionRewritesLearnsAndInsertsSpace() {
    let doc = FakeDocument()
    let session = CompositionSession(
        configuration: .init(autoCapitalize: false),
        decode: { _, _, _ in
            [DecodeCandidate(word: "hey", score: -1, edits: 0),
             DecodeCandidate(word: "hex", score: -2, edits: 1)]
        },
        readTextBeforeCursor: { doc.text },
        emit: { doc.apply($0) })
    session.tap(at: 0.1); session.tap(at: 0.2); session.tap(at: 0.3)
    #expect(doc.text == "hey")
    let mark = doc.commands.count
    session.selectCandidate("hex")
    #expect(doc.text == "hex ")
    // Picking a non-top candidate is the one commit path that rewrites, and it
    // learns with that candidate's edit count.
    #expect(doc.commands(after: mark) == [
        .deleteBackward(count: 3),
        .insertText("hex"),
        .learn(word: "hex", taps: [0.1, 0.2, 0.3], edits: 1),
        .setStrip([]),
        .insertText(" "),
    ])
}

@Test @MainActor func insertReturnCommitsAndInsertsNewline() {
    let doc = FakeDocument()
    let session = makeSession(doc)
    session.tap(at: 0.1); session.tap(at: 0.2); session.tap(at: 0.3)
    session.insertReturn()
    #expect(doc.text == "hey\n")
    #expect(!session.isComposing)
}

@Test @MainActor func moveCursorCommitsThenMoves() {
    let doc = FakeDocument()
    let session = makeSession(doc)
    session.tap(at: 0.1); session.tap(at: 0.2); session.tap(at: 0.3)
    let mark = doc.commands.count
    session.moveCursor(by: -2)
    #expect(doc.commands(after: mark) == [
        .learn(word: "hey", taps: [0.1, 0.2, 0.3], edits: 0),
        .setStrip([]),
        .moveCursor(by: -2),
    ])
    #expect(!session.isComposing)
}

// MARK: - Stale-provisional invariant

@Test @MainActor func staleProvisionalAbandonsWithoutTextCommands() {
    let doc = FakeDocument()
    let session = makeSession(doc)
    session.tap(at: 0.1); session.tap(at: 0.2); session.tap(at: 0.3)
    #expect(doc.text == "hey")
    doc.text = "totally different"          // the host edited the document under us
    let mark = doc.commands.count
    session.hostTextDidChange()
    // A stale provisional never deletes unrelated text: abandon in place.
    #expect(doc.commands(after: mark) == [.setStrip([])])
    #expect(doc.text == "totally different")
    #expect(!session.isComposing)
}

@Test @MainActor func hostChangeMatchingProvisionalKeepsComposition() {
    let doc = FakeDocument()
    let session = makeSession(doc, ladder: ["h", "he", "hey", "heya"])
    session.tap(at: 0.1); session.tap(at: 0.2); session.tap(at: 0.3)
    let mark = doc.commands.count
    session.hostTextDidChange()             // our own edit echoing back — suffix still matches
    #expect(doc.commands.count == mark)
    #expect(session.isComposing)
    session.tap(at: 0.4)
    #expect(doc.text == "heya")
}

@Test @MainActor func idleHostChangeRebuildsContext() {
    let doc = FakeDocument()
    var seenContext: [String]?
    let session = makeSession(doc, onDecode: { _, context, _ in seenContext = context })
    doc.text = "hello brave world "
    let mark = doc.commands.count
    session.hostTextDidChange()
    #expect(doc.commands(after: mark) == [.setStrip([])])   // idle strip re-evaluates Paste chip
    session.tap(at: 0.1)
    #expect(seenContext == ["hello", "brave", "world"])
}

@Test @MainActor func contextCapsAtEightWords() {
    let doc = FakeDocument()
    var seenContext: [String]?
    let session = makeSession(doc, ladder: ["h"], onDecode: { _, context, _ in seenContext = context })
    for _ in 0..<10 {
        session.tap(at: 0.5)
        session.insertSpace()
    }
    session.tap(at: 0.5)
    #expect(seenContext == Array(repeating: "h", count: 8))
}

// MARK: - Shift

@Test @MainActor func shiftOnceCapitalizesAndIsConsumedOnCommit() {
    let doc = FakeDocument()
    let session = makeSession(doc)
    session.toggleShift()
    #expect(doc.shiftDisplay == .once)
    session.tap(at: 0.1); session.tap(at: 0.2); session.tap(at: 0.3)
    #expect(doc.text == "Hey")
    let mark = doc.commands.count
    session.insertSpace()
    // One-shot shift is spent by the commit, after the strip clears.
    #expect(doc.commands(after: mark) == [
        .learn(word: "Hey", taps: [0.1, 0.2, 0.3], edits: 0),
        .setStrip([]),
        .setShift(.off),
        .insertText(" "),
    ])
    session.tap(at: 0.1)
    #expect(doc.text == "Hey h")
}

@Test @MainActor func shiftLockUppercasesAndPersists() {
    let doc = FakeDocument()
    let session = makeSession(doc)
    session.toggleShift(); session.toggleShift()
    #expect(doc.shiftDisplay == .lock)
    session.tap(at: 0.1); session.tap(at: 0.2); session.tap(at: 0.3)
    #expect(doc.text == "HEY")
    session.insertSpace()
    #expect(session.shift == .lock)
    session.tap(at: 0.1)
    #expect(doc.text == "HEY H")
}

@Test @MainActor func toggleShiftRecasesLiveWord() {
    let doc = FakeDocument()
    let session = makeSession(doc)
    session.tap(at: 0.1); session.tap(at: 0.2); session.tap(at: 0.3)
    let mark = doc.commands.count
    session.toggleShift()
    #expect(doc.text == "Hey")
    #expect(doc.commands(after: mark) == [
        .setShift(.once),
        .setStrip([candidate("Hey")]),
        .deleteBackward(count: 3),
        .insertText("Hey"),
    ])
}

@Test @MainActor func sentenceStartLatchCapitalizes() {
    let doc = FakeDocument()
    let session = makeSession(doc, configuration: .init())   // autoCapitalize on
    session.tap(at: 0.1); session.tap(at: 0.2); session.tap(at: 0.3)
    #expect(doc.text == "Hey")                               // document start
    session.insertSpace()
    session.tap(at: 0.1); session.tap(at: 0.2); session.tap(at: 0.3)
    #expect(doc.text == "Hey hey")                           // mid-sentence stays lowercase
    session.insertPrecise(".")
    session.insertSpace()
    session.tap(at: 0.1)
    #expect(doc.text == "Hey hey. H")                        // capitalized again after terminator
}

// MARK: - Backspace

@Test @MainActor func backspaceWithinCompositionPeelsTapAndPin() {
    let doc = FakeDocument()
    var seenTaps: [Double]?
    var seenForced: [Int: Character]?
    let session = makeSession(doc, onDecode: { taps, _, forced in seenTaps = taps; seenForced = forced })
    session.tap(at: 0.1); session.tap(at: 0.2)
    session.pickLetter("z", at: 0.5)
    #expect(seenForced == [2: "z"])
    session.backspace()
    #expect(seenTaps == [0.1, 0.2])
    #expect(seenForced == [:])                // the pin fell away with its tap
    #expect(doc.text == "he")
    session.backspace()
    session.backspace()
    #expect(doc.text == "")
    #expect(!session.isComposing)
}

@Test @MainActor func backspaceOutsideCompositionDeletesOneChar() {
    let doc = FakeDocument()
    var seenContext: [String]?
    let session = makeSession(doc, onDecode: { _, context, _ in seenContext = context })
    doc.text = "hey "
    let mark = doc.commands.count
    session.backspace()
    #expect(doc.commands(after: mark) == [.deleteBackward(count: 1)])
    #expect(doc.text == "hey")
    session.tap(at: 0.1)
    #expect(seenContext == ["hey"])           // context recomputed after the delete
}

// MARK: - Delete word

@Test @MainActor func deleteWordWithinCompositionClearsProvisional() {
    let doc = FakeDocument()
    let session = makeSession(doc)
    session.tap(at: 0.1); session.tap(at: 0.2); session.tap(at: 0.3)
    let mark = doc.commands.count
    session.deleteWord()
    #expect(doc.commands(after: mark) == [.deleteBackward(count: 3), .setStrip([])])
    #expect(doc.text == "")
    #expect(!session.isComposing)
}

@Test @MainActor func deleteWordOutsideCompositionRemovesSpacesThenWord() {
    let doc = FakeDocument()
    let session = makeSession(doc)
    doc.text = "one two  "
    let mark = doc.commands.count
    session.deleteWord()
    // Two batches: the trailing space run, then the word.
    #expect(doc.commands(after: mark) == [.deleteBackward(count: 2), .deleteBackward(count: 3)])
    #expect(doc.text == "one ")
}

@Test @MainActor func deleteWordUnlearnsLastCommitted() {
    let doc = FakeDocument()
    let session = makeSession(doc)
    session.tap(at: 0.1); session.tap(at: 0.2); session.tap(at: 0.3)
    session.insertSpace()
    let mark = doc.commands.count
    session.deleteWord()
    #expect(doc.commands(after: mark) == [
        .deleteBackward(count: 1),
        .deleteBackward(count: 3),
        .unlearn(word: "hey"),
    ])
    #expect(doc.text == "")

    doc.text = "hey "
    let secondMark = doc.commands.count
    session.deleteWord()
    // lastCommitted was cleared by the first unlearn — no repeat.
    #expect(!doc.commands(after: secondMark).contains { if case .unlearn = $0 { return true }; return false })
}

@Test @MainActor func deleteWordDoesNotUnlearnDifferentWord() {
    let doc = FakeDocument()
    let session = makeSession(doc)
    session.tap(at: 0.1); session.tap(at: 0.2); session.tap(at: 0.3)
    session.insertSpace()
    session.insertPrecise("abc")
    #expect(doc.text == "hey abc")
    let mark = doc.commands.count
    session.deleteWord()
    #expect(doc.text == "hey ")
    #expect(!doc.commands(after: mark).contains { if case .unlearn = $0 { return true }; return false })
}

// documentContextBeforeInput returns nil in the window right after the keyboard
// re-activates on an app switch. The word boundary is then unknown, so the flick
// deletes one character instead of silently doing nothing.
@Test @MainActor func deleteWordFallsBackToCharDeleteWhenContextUnavailable() {
    let doc = FakeDocument()
    let session = CompositionSession(
        configuration: .init(autoCapitalize: false),
        decode: { _, _, _ in [] },
        readTextBeforeCursor: { nil as String? },
        emit: { doc.apply($0) })
    session.deleteWord()
    #expect(doc.commands == [.deleteBackward(count: 1)])
}

// MARK: - Secure fields

@Test @MainActor func secureFieldAbandonsInPlaceAndTypesVerbatim() {
    let doc = FakeDocument()
    let session = makeSession(doc)
    session.tap(at: 0.1); session.tap(at: 0.2)
    #expect(doc.text == "he")
    let mark = doc.commands.count
    session.configuration.isSecureField = true
    // Turning secure abandons the composition without touching the document.
    #expect(doc.commands(after: mark) == [.setStrip([])])
    #expect(doc.text == "he")
    #expect(!session.isComposing)

    session.secureTap("x")
    #expect(doc.text == "hex")
    session.toggleShift()
    session.secureTap("y")
    #expect(doc.text == "hexY")
    #expect(session.shift == .off)            // one-shot spent
    session.toggleShift(); session.toggleShift()
    session.secureTap("z")
    #expect(doc.text == "hexYZ")
    #expect(session.shift == .lock)           // lock persists
    #expect(!doc.commands.contains { if case .learn = $0 { return true }; return false })
}

// MARK: - Misc

@Test @MainActor func emojiCandidateUsesCharacterCounts() {
    let doc = FakeDocument()
    let session = makeSession(doc, ladder: ["🇦🇷", "🇦🇷🙂"])
    session.tap(at: 0.1)
    #expect(doc.text == "🇦🇷")
    let mark = doc.commands.count
    session.tap(at: 0.2)
    // The flag is one Character (many UTF-16 units) — exactly one delete.
    #expect(doc.commands(after: mark) == [
        .setStrip([candidate("🇦🇷🙂")]),
        .deleteBackward(count: 1),
        .insertText("🇦🇷🙂"),
    ])
    #expect(doc.text == "🇦🇷🙂")
}

@Test @MainActor func insertVerbatimRecomputesContext() {
    let doc = FakeDocument()
    var seenContext: [String]?
    let session = makeSession(doc, onDecode: { _, context, _ in seenContext = context })
    session.insertVerbatim("lorem ipsum ")
    #expect(doc.text == "lorem ipsum ")
    session.tap(at: 0.1)
    #expect(seenContext == ["lorem", "ipsum"])
}

@Test @MainActor func refreshCandidatesAfterModelLoadRewritesWord() {
    let doc = FakeDocument()
    var vocabLoaded = false
    let session = CompositionSession(
        configuration: .init(autoCapitalize: false),
        decode: { taps, _, _ in
            let word = vocabLoaded ? "hey" : "xxx"
            return [DecodeCandidate(word: String(word.prefix(taps.count)), score: 0, edits: 0)]
        },
        readTextBeforeCursor: { doc.text },
        emit: { doc.apply($0) })
    session.tap(at: 0.1); session.tap(at: 0.2); session.tap(at: 0.3)
    #expect(doc.text == "xxx")
    vocabLoaded = true
    session.refreshCandidates()
    #expect(doc.text == "hey")
}
