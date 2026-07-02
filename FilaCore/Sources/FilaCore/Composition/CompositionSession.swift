import Foundation

/// Manual shift, toggled off → once → lock → off.
public enum CompositionShift: Equatable, Sendable { case off, once, lock }

/// One instruction the session asks its host to perform. The host must apply
/// commands synchronously inside `emit` — the session re-reads the document
/// mid-event and relies on prior commands having already landed.
public enum CompositionCommand: Equatable, Sendable {
    /// Delete `count` characters before the caret (one deleteBackward each).
    case deleteBackward(count: Int)
    case insertText(String)
    /// Move the insertion point by `offset` characters (negative = left).
    case moveCursor(by: Int)
    /// Show these candidates in the suggestion strip (empty = idle strip).
    case setStrip([DecodeCandidate])
    /// Reflect the shift state in the key row's rendering.
    case setShift(CompositionShift)
    /// Adapt the spatial model and learn vocabulary for a committed word.
    case learn(word: String, taps: [Double], edits: Int?)
    /// Decrement a word's learned weight (a committed word deleted right back
    /// out is a correction).
    case unlearn(word: String)
}

/// Host-owned knobs the composition depends on. The host pushes a fresh value
/// whenever settings, the active language, or the field type change.
public struct CompositionConfiguration: Equatable, Sendable {
    public var autoCapitalize: Bool
    public var smartSpacing: Bool
    /// Secure/password fields: smart spacing/punctuation never rewrites, and
    /// entry happens verbatim via ``CompositionSession/secureTap(_:)`` —
    /// nothing decoded or learned.
    public var isSecureField: Bool
    /// Casing locale and the English "I" rule.
    public var language: KeyboardLanguage

    public init(autoCapitalize: Bool = true,
                smartSpacing: Bool = true,
                isSecureField: Bool = false,
                language: KeyboardLanguage = .english) {
        self.autoCapitalize = autoCapitalize
        self.smartSpacing = smartSpacing
        self.isSecureField = isSecureField
        self.language = language
    }
}

/// The keyboard's composition state machine, kept free of UIKit so it can be
/// unit-tested: consumes user events (taps, gestures, strip picks, host text
/// changes) and emits ``CompositionCommand``s for the host to apply.
///
/// The candidate ranking is injected (`decode`) because the full policy lives
/// in FilaKit's KeyboardEngine (UITextChecker). Reads of the text before the
/// caret are injected too (`readTextBeforeCursor`) and happen live, mid-event,
/// exactly where the document must be consulted — which is why `emit` must
/// apply commands synchronously.
@MainActor
public final class CompositionSession {

    public private(set) var shift: CompositionShift = .off
    /// Whether a word is currently being composed (taps pending).
    public var isComposing: Bool { !tapBuffer.isEmpty }

    public var configuration: CompositionConfiguration {
        didSet {
            if configuration.isSecureField, !oldValue.isSecureField { abandonComposition() }
        }
    }

    private let decode: @MainActor ([Double], [String], [Int: Character]) -> [DecodeCandidate]
    private let readTextBeforeCursor: @MainActor () -> String?
    private let emit: @MainActor (CompositionCommand) -> Void

    private var tapBuffer: [Double] = []
    /// Tap indices the user pinned to an exact letter via the precision magnifier;
    /// the decoder is forced to honor these. Cleared when the word commits.
    private var forcedLetters: [Int: Character] = [:]
    private var context: [String] = []
    private var currentCandidates: [DecodeCandidate] = []
    /// The provisional word currently written into the document as real text
    /// (rewritten on each tap). Committed on space/selection.
    private var provisional = ""
    /// Whether the word currently being composed should be auto-capitalized
    /// (sentence start). Latched when the word begins, applied at render/commit.
    private var capitalizeCurrentWord = false
    /// The most recently committed word — deleting it right back out is treated
    /// as a correction, so its learned weight is decremented.
    private var lastCommitted: String?

    public init(configuration: CompositionConfiguration,
                decode: @escaping @MainActor ([Double], [String], [Int: Character]) -> [DecodeCandidate],
                readTextBeforeCursor: @escaping @MainActor () -> String?,
                emit: @escaping @MainActor (CompositionCommand) -> Void) {
        self.configuration = configuration
        self.decode = decode
        self.readTextBeforeCursor = readTextBeforeCursor
        self.emit = emit
    }

    // MARK: Composition

    /// Rewrite the provisional word in the document as real text — delete the
    /// old one and insert the new. Plain delete/insert (not marked text), so
    /// characters actually appear in every host.
    private func render(_ newProvisional: String) {
        guard newProvisional != provisional else { return }
        if !provisional.isEmpty { emit(.deleteBackward(count: provisional.count)) }
        if !newProvisional.isEmpty { emit(.insertText(newProvisional)) }
        provisional = newProvisional
    }

    /// Re-decode the tap buffer and refresh the strip and provisional. Also the
    /// host's entry point after the dictionary model loads or a word is forgotten.
    public func refreshCandidates() {
        guard !tapBuffer.isEmpty else {
            currentCandidates = []
            emit(.setStrip([]))
            render("")
            return
        }
        let candidates = decode(tapBuffer, context, forcedLetters)
        // Auto-capitalize for display and commit; the lexicon/decoder stay lowercase.
        let display = candidates.map { DecodeCandidate(word: cased($0.word), score: $0.score, edits: $0.edits) }
        currentCandidates = display
        emit(.setStrip(display))
        render(display.first?.word ?? "")
    }

    /// Apply casing to a decoded (lowercase) word: manual shift wins, else
    /// auto-capitalization for the active language and latched sentence-start.
    private func cased(_ word: String) -> String {
        let locale = Locale(identifier: configuration.language.rawValue)
        switch shift {
        case .lock:
            return word.uppercased(with: locale)
        case .once:
            return word.prefix(1).uppercased(with: locale) + word.dropFirst()
        case .off:
            return Autocapitalization.cased(word,
                                            sentenceStart: capitalizeCurrentWord,
                                            english: configuration.language == .english,
                                            locale: locale)
        }
    }

    /// All shift changes go through here so the host's row rendering stays in sync.
    private func setShift(_ newValue: CompositionShift) {
        shift = newValue
        emit(.setShift(newValue))
    }

    public func toggleShift() {
        switch shift {
        case .off:  setShift(.once)
        case .once: setShift(.lock)
        case .lock: setShift(.off)
        }
        refreshCandidates()   // re-case the in-progress word live
    }

    /// Rebuild the prediction context from the document itself (excluding any
    /// in-progress word), so it stays correct after deletions of any granularity.
    private func recomputeContext() {
        guard let before = readTextBeforeCursor() else { context = []; return }
        var text = before[...]
        if !provisional.isEmpty, text.hasSuffix(provisional) {
            text = text.dropLast(provisional.count)
        }
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        context = words.suffix(8).map(String.init)
    }

    /// Finalize the current word (defaults to the shown provisional, or an
    /// explicitly chosen suggestion), leaving it as permanent text.
    private func commit(word: String?) {
        let chosen = word ?? currentCandidates.first?.word ?? provisional
        render(chosen)                 // make the document match the chosen word
        if !chosen.isEmpty {
            context.append(chosen)
            if context.count > 8 { context.removeFirst() }
            let edits = currentCandidates.first(where: { $0.word == chosen })?.edits
            emit(.learn(word: chosen, taps: tapBuffer, edits: edits))   // adapt spatial + learn vocab
            lastCommitted = chosen
        }
        provisional = ""               // now permanent — don't rewrite it later
        tapBuffer.removeAll()
        forcedLetters.removeAll()
        currentCandidates = []
        emit(.setStrip([]))
        if shift == .once { setShift(.off) }  // one-shot spent
    }

    /// Drop any in-progress composition WITHOUT touching the document — used when
    /// the document changed under us (caret moved, host edited) or the field
    /// turned secure.
    private func abandonComposition() {
        provisional = ""
        tapBuffer.removeAll()
        forcedLetters.removeAll()
        currentCandidates = []
        emit(.setStrip([]))
    }

    /// Called by the host whenever the document text or selection changes. If the
    /// change wasn't ours (the text before the caret no longer ends with the
    /// provisional word), the composition is abandoned in place — rewriting it
    /// would delete unrelated text — and the prediction context is rebuilt.
    public func hostTextDidChange() {
        if provisional.isEmpty {
            recomputeContext()
            // Idle → let the host re-evaluate the Paste chip (the clipboard may
            // have changed while another app or field had focus).
            if tapBuffer.isEmpty { emit(.setStrip([])) }
            return
        }
        let before = readTextBeforeCursor() ?? ""
        if !before.hasSuffix(provisional) {
            abandonComposition()
            recomputeContext()
        }
    }

    // MARK: Events

    public func tap(at x: Double) {
        if tapBuffer.isEmpty {
            capitalizeCurrentWord = configuration.autoCapitalize
                && Autocapitalization.isSentenceStart(readTextBeforeCursor())
        }
        tapBuffer.append(x)
        refreshCandidates()
    }

    /// Precision-magnifier pick: a tap whose letter the user pinned exactly.
    public func pickLetter(_ letter: Character, at x: Double) {
        if tapBuffer.isEmpty {
            capitalizeCurrentWord = configuration.autoCapitalize
                && Autocapitalization.isSentenceStart(readTextBeforeCursor())
        }
        tapBuffer.append(x)                                 // keep alignment for learning
        forcedLetters[tapBuffer.count - 1] = Character(letter.lowercased())
        refreshCandidates()
    }

    /// Verbatim entry for secure fields: the exact letter, shift applied, written
    /// straight through — never decoded or learned.
    public func secureTap(_ letter: Character) {
        var s = String(letter)
        if shift != .off {
            s = s.uppercased(with: Locale(identifier: configuration.language.rawValue))
            if shift == .once { setShift(.off) }
        }
        emit(.insertText(s))
    }

    public func insertSpace() {
        if !tapBuffer.isEmpty { commit(word: nil) }
        let before = readTextBeforeCursor() ?? ""
        if configuration.smartSpacing, !configuration.isSecureField,
           TypingBehavior.shouldConvertDoubleSpaceToPeriod(before) {
            emit(.deleteBackward(count: 1))   // drop the existing trailing space
            emit(.insertText(". "))           // …and make it ". "
        } else {
            emit(.insertText(" "))
        }
        recomputeContext()
    }

    public func insertReturn() {
        if !tapBuffer.isEmpty { commit(word: nil) }
        emit(.insertText("\n"))
    }

    /// Single-character backspace (delete-aware: peels a tap before touching
    /// committed text). Called repeatedly by the row's hold-to-repeat.
    public func backspace() {
        if !tapBuffer.isEmpty {
            tapBuffer.removeLast()
            forcedLetters[tapBuffer.count] = nil   // drop any pin on the removed tap
            refreshCandidates()       // re-renders the shorter provisional (or clears it)
        } else {
            emit(.deleteBackward(count: 1))   // no composition: delete a committed character
            recomputeContext()        // a char delete must not drop a whole context word
        }
    }

    public func deleteWord() {
        if !tapBuffer.isEmpty {
            render("")
            tapBuffer.removeAll()
            forcedLetters.removeAll()
            currentCandidates = []
            emit(.setStrip([]))
            return
        }
        guard let before = readTextBeforeCursor() else {
            // The document proxy reports nil context in the brief window after the
            // keyboard re-activates on an app switch, so the word boundary is
            // unknown. Delete a single character rather than nothing — the flick
            // still acts, and the edit re-syncs the proxy so the next one deletes a
            // whole word.
            emit(.deleteBackward(count: 1))
            return
        }
        let trailingSpaces = before.reversed().prefix { $0 == " " }.count
        if trailingSpaces > 0 { emit(.deleteBackward(count: trailingSpaces)) }
        let word = String(before.dropLast(trailingSpaces).reversed().prefix { !$0.isWhitespace }.reversed())
        if !word.isEmpty { emit(.deleteBackward(count: word.count)) }
        // Deleting the word we just committed is a correction — unlearn it.
        if let last = lastCommitted, word == last {
            emit(.unlearn(word: last))
            lastCommitted = nil
        }
        recomputeContext()
    }

    /// Strip pick: finalize the chosen suggestion and follow it with a space.
    public func selectCandidate(_ word: String) {
        commit(word: word)
        emit(.insertText(" "))
    }

    /// Shared verbatim insertion for magnifier hint picks and panel chips, with
    /// smart punctuation re-spacing applied where it makes sense.
    public func insertPrecise(_ text: String) {
        if !tapBuffer.isEmpty { commit(word: nil) }
        let before = readTextBeforeCursor() ?? ""
        if configuration.smartSpacing, !configuration.isSecureField, text.count == 1, let ch = text.first,
           let replacement = TypingBehavior.smartPunctuation(ch, before: before) {
            emit(.deleteBackward(count: 1))   // move the space to after the punctuation
            emit(.insertText(replacement))
        } else {
            emit(.insertText(text))
        }
        recomputeContext()
    }

    /// Verbatim insertion without smart punctuation (paste). The caller commits
    /// separately via ``commitComposition()`` — a paste attempt commits even
    /// when the clipboard turns out to be empty.
    public func insertVerbatim(_ text: String) {
        emit(.insertText(text))
        recomputeContext()
    }

    public func moveCursor(by offset: Int) {
        if !tapBuffer.isEmpty { commit(word: nil) }
        emit(.moveCursor(by: offset))
        recomputeContext()
    }

    /// Finalize any in-progress word (panel opening, paste) without other edits.
    public func commitComposition() {
        if !tapBuffer.isEmpty { commit(word: nil) }
    }
}
