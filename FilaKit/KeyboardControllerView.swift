import UIKit
import FilaCore

/// The complete Fila keyboard — a gesture-driven single row with a suggestion
/// strip and no bottom key row. Writes through a ``TextSink`` so the extension
/// and the in-app playground share one implementation.
///
/// Interaction: tap the row to type; the engine re-decodes after every tap and
/// writes the top hypothesis into the document as real text (rewritten in place —
/// not marked text, so it appears in every host), with alternatives in the strip.
/// Decoded words are auto-capitalized at sentence starts (the lexicon stays
/// lowercase; casing is a presentation transform — see ``cased(_:)``).
/// Editing is gestural — →space · ←delete word (hold = backspace repeat) ·
/// ↑shift (row shows capitals) · ↓return · long-press = precision magnifier
/// (slide up for numbers/symbols). There are no alternate row planes: precise
/// digits/symbols live in the numbers panel (123 on the strip, auto-shown for
/// numeric fields), emoji/cursor panels behind ☺. Keyboard switching is the
/// system globe bar's job.
@MainActor
public final class KeyboardControllerView: UIView {
    /// Where typed text goes. Strongly held — the controller owns its sink (the
    /// host creates it inline, so a weak ref would deallocate it immediately).
    public var sink: TextSink?

    private let engine = KeyboardEngine()
    private var suggestionStrip: SuggestionStripView!
    private var compressedRow: CompressedRowView!

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

    /// Secure/password fields: taps insert the nearest letter verbatim — no
    /// decoding, no rewriting, no suggestions, and nothing is learned.
    public var isSecureField = false {
        didSet { if isSecureField, isSecureField != oldValue { abandonComposition() } }
    }

    /// Numeric fields (PIN, phone, decimal pads): the numbers panel opens
    /// automatically and closes again when the field changes back.
    public var isNumericField = false {
        didSet {
            guard isNumericField != oldValue else { return }
            if isNumericField {
                showPanel(.numbers)
            } else if bonusPanel?.kind == .numbers {
                closePanel()
            }
        }
    }

    /// Manual shift, toggled off → once → lock → off by the up-left gesture.
    private enum ShiftState { case off, once, lock }
    private var shift: ShiftState = .off

    private let stripHeight: CGFloat = 40
    private let rowHeight: CGFloat = 76
    /// Total keyboard height the extension should size its input view to
    /// (strip + gap + row + gap). Without this the row stretches to fill iOS's
    /// default keyboard height.
    public static let preferredHeight: CGFloat = 40 + 6 + 76 + 6

    private let settings = SettingsStore()
    private var settingsToken: AnyObject?
    private var theme: Theme = .dark
    private var bonusPanel: BonusPanelView?

    public init() {
        super.init(frame: .zero)
        buildViews()
        applyTheme()
        updateStrip([])     // idle strip offers Paste right away if the clipboard has text
        // Dictionaries load off-thread; when they land, any word typed in the
        // meantime is re-decoded against the real vocabulary.
        engine.onModelReady = { [weak self] in
            guard let self, !self.tapBuffer.isEmpty else { return }
            self.refreshCandidates()
        }
        settingsToken = SettingsStore.observe { [weak self] in self?.reloadSettings() }
    }

    public override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if traitCollection.userInterfaceStyle != previous?.userInterfaceStyle { applyTheme() }
    }

    /// Repaint the palette for the current appearance. The keyboard surface is
    /// always transparent — the host's `UIInputView` blur (the native keyboard
    /// material) shows through, and it already follows the host's light/dark style.
    private func applyTheme() {
        theme = Theme.forTraits(traitCollection)
        backgroundColor = .clear
        compressedRow.theme = theme
        suggestionStrip.theme = theme
        bonusPanel?.theme = theme
    }

    /// Applied when the container app changes a setting (via Darwin notification):
    /// rebuild the engine for the new default language + enabled dictionaries.
    private func reloadSettings() {
        engine.applySettings()
        compressedRow.setKeys(engine.keys)
        compressedRow.glyphScale = settings.textScale
        compressedRow.glyphWidth = settings.textWidth
        applyTheme()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: Layout

    private func buildViews() {
        suggestionStrip = SuggestionStripView()
        suggestionStrip.delegate = self
        suggestionStrip.translatesAutoresizingMaskIntoConstraints = false

        compressedRow = CompressedRowView(keys: engine.keys)
        compressedRow.glyphScale = settings.textScale
        compressedRow.glyphWidth = settings.textWidth
        compressedRow.delegate = self
        compressedRow.translatesAutoresizingMaskIntoConstraints = false

        addSubview(suggestionStrip)
        addSubview(compressedRow)

        // The row keeps a fixed height; its bottom pin yields (low priority) so an
        // unexpected container height leaves empty space rather than stretching it.
        let rowBottom = compressedRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        rowBottom.priority = .defaultLow

        NSLayoutConstraint.activate([
            suggestionStrip.topAnchor.constraint(equalTo: topAnchor),
            suggestionStrip.leadingAnchor.constraint(equalTo: leadingAnchor),
            suggestionStrip.trailingAnchor.constraint(equalTo: trailingAnchor),
            suggestionStrip.heightAnchor.constraint(equalToConstant: stripHeight),

            compressedRow.topAnchor.constraint(equalTo: suggestionStrip.bottomAnchor, constant: 6),
            compressedRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            compressedRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            compressedRow.heightAnchor.constraint(equalToConstant: rowHeight),
            rowBottom,
        ])
    }

    // MARK: Composition

    /// Rewrite the provisional word in the document as real text — delete the old
    /// one and insert the new. Uses plain insert/delete (not marked text), so
    /// characters actually appear in every host, including the playground.
    private func render(_ newProvisional: String) {
        guard newProvisional != provisional else { return }
        for _ in 0..<provisional.count { sink?.deleteBackward() }
        if !newProvisional.isEmpty { sink?.insertText(newProvisional) }
        provisional = newProvisional
    }

    /// Every strip refresh re-evaluates the clipboard: an idle strip offers a
    /// Paste chip when the pasteboard holds text. `hasStrings` is a metadata
    /// check — it never reads content, so no system paste alert fires. Without
    /// Full Access the extension's pasteboard reads as empty and the chip
    /// simply never appears.
    private func updateStrip(_ candidates: [DecodeCandidate]) {
        suggestionStrip.update(with: candidates,
                               showPaste: candidates.isEmpty && UIPasteboard.general.hasStrings)
    }

    private func refreshCandidates() {
        guard !tapBuffer.isEmpty else {
            currentCandidates = []
            updateStrip([])
            render("")
            return
        }
        var candidates = engine.candidates(for: tapBuffer, context: context, forced: forcedLetters)
        let raw = engine.nearestLetters(for: tapBuffer, forced: forcedLetters)
        if !raw.isEmpty && !candidates.contains(where: { $0.word == raw }) {
            // The literal reading is aligned by construction — edits 0.
            candidates.append(DecodeCandidate(word: raw, score: -Double(tapBuffer.count) * 10))
        }
        // Auto-capitalize for display and commit; the lexicon/decoder stay lowercase.
        let display = candidates.map { DecodeCandidate(word: cased($0.word), score: $0.score, edits: $0.edits) }
        currentCandidates = display
        updateStrip(display)
        render(display.first?.word ?? "")
    }

    /// Apply casing to a decoded (lowercase) word: manual shift wins, else
    /// auto-capitalization for the active language and latched sentence-start.
    private func cased(_ word: String) -> String {
        let locale = Locale(identifier: engine.language.rawValue)
        switch shift {
        case .lock:
            return word.uppercased(with: locale)
        case .once:
            return word.prefix(1).uppercased(with: locale) + word.dropFirst()
        case .off:
            return Autocapitalization.cased(word,
                                            sentenceStart: capitalizeCurrentWord,
                                            english: engine.language == .english,
                                            locale: locale)
        }
    }

    /// All shift changes go through here so the row's rendering stays in sync.
    private func setShift(_ newValue: ShiftState) {
        shift = newValue
        switch newValue {
        case .off:  compressedRow.shiftDisplay = .off
        case .once: compressedRow.shiftDisplay = .once
        case .lock: compressedRow.shiftDisplay = .lock
        }
    }

    private func toggleShift() {
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
        guard let before = sink?.textBeforeCursor else { context = []; return }
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
            engine.learn(word: chosen, taps: tapBuffer, edits: edits)   // adapt spatial + learn vocab
            lastCommitted = chosen
        }
        provisional = ""               // now permanent — don't rewrite it later
        tapBuffer.removeAll()
        forcedLetters.removeAll()
        currentCandidates = []
        updateStrip([])
        if shift == .once { setShift(.off) }  // one-shot spent
    }

    /// Drop any in-progress composition WITHOUT touching the document — used when
    /// the document changed under us (caret moved, host edited) or the field is secure.
    private func abandonComposition() {
        provisional = ""
        tapBuffer.removeAll()
        forcedLetters.removeAll()
        currentCandidates = []
        updateStrip([])
    }

    /// Called by the host whenever the document text or selection changes. If the
    /// change wasn't ours (the text before the caret no longer ends with the
    /// provisional word), the composition is abandoned in place — rewriting it
    /// would delete unrelated text — and the prediction context is rebuilt.
    public func hostTextDidChange() {
        if provisional.isEmpty {
            recomputeContext()
            // Idle → re-evaluate the Paste chip (the clipboard may have changed
            // while another app or field had focus).
            if tapBuffer.isEmpty { updateStrip([]) }
            return
        }
        let before = sink?.textBeforeCursor ?? ""
        if !before.hasSuffix(provisional) {
            abandonComposition()
            recomputeContext()
        }
    }

    // MARK: Actions

    private func insertSpace() {
        if !tapBuffer.isEmpty { commit(word: nil) }
        let before = sink?.textBeforeCursor ?? ""
        if settings.smartSpacing, !isSecureField, TypingBehavior.shouldConvertDoubleSpaceToPeriod(before) {
            sink?.deleteBackward()      // drop the existing trailing space
            sink?.insertText(". ")      // …and make it ". "
        } else {
            sink?.insertText(" ")
        }
        recomputeContext()
    }

    private func insertReturn() {
        if !tapBuffer.isEmpty { commit(word: nil) }
        sink?.insertText("\n")
    }

    /// Single-character backspace (delete-aware: peels a tap before touching
    /// committed text). Called repeatedly by the row's hold-to-repeat.
    private func backspace() {
        if !tapBuffer.isEmpty {
            tapBuffer.removeLast()
            forcedLetters[tapBuffer.count] = nil   // drop any pin on the removed tap
            refreshCandidates()       // re-renders the shorter provisional (or clears it)
        } else {
            sink?.deleteBackward()    // no composition: delete a committed character
            recomputeContext()        // a char delete must not drop a whole context word
        }
    }

    private func deleteWord() {
        if !tapBuffer.isEmpty {
            render("")
            tapBuffer.removeAll()
            forcedLetters.removeAll()
            currentCandidates = []
            updateStrip([])
            return
        }
        if let before = sink?.textBeforeCursor {
            let trailingSpaces = before.reversed().prefix { $0 == " " }.count
            for _ in 0..<trailingSpaces { sink?.deleteBackward() }
            let word = String(before.dropLast(trailingSpaces).reversed().prefix { !$0.isWhitespace }.reversed())
            for _ in 0..<word.count { sink?.deleteBackward() }
            // Deleting the word we just committed is a correction — unlearn it.
            if let last = lastCommitted, word == last {
                engine.forget(word: last)
                lastCommitted = nil
            }
        }
        recomputeContext()
    }

    // MARK: Bonus panels (overlay the row, toggled from the suggestion strip)

    private func cyclePanel() {
        let next: BonusPanelView.Kind?
        switch bonusPanel?.kind {
        case .none, .numbers: next = .emoji   // ☺ owns emoji/cursor; 123 owns numbers
        case .emoji:          next = .cursor
        case .cursor:         next = nil
        }
        if let next { showPanel(next) } else { closePanel() }
    }

    private func showPanel(_ kind: BonusPanelView.Kind) {
        if !tapBuffer.isEmpty { commit(word: nil) }
        bonusPanel?.removeFromSuperview()
        let panel = BonusPanelView(kind: kind, theme: theme)
        panel.delegate = self
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        NSLayoutConstraint.activate([                 // take the compressed row's place
            panel.topAnchor.constraint(equalTo: compressedRow.topAnchor),
            panel.bottomAnchor.constraint(equalTo: compressedRow.bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: compressedRow.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: compressedRow.trailingAnchor),
        ])
        // Hide the row rather than paint over it — the panel is transparent too,
        // so the keyboard's backdrop stays visible behind it.
        compressedRow.isHidden = true
        bonusPanel = panel
    }

    private func closePanel() {
        bonusPanel?.removeFromSuperview()
        bonusPanel = nil
        compressedRow.isHidden = false
    }
}

// MARK: - CompressedRowViewDelegate

extension KeyboardControllerView: CompressedRowViewDelegate {
    /// Verbatim entry for secure fields: the exact letter (or the tap's nearest
    /// letter), shift applied, written straight through — never decoded or learned.
    private func insertSecure(_ letter: Character) {
        var s = String(letter)
        if shift != .off {
            s = s.uppercased(with: Locale(identifier: engine.language.rawValue))
            if shift == .once { setShift(.off) }
        }
        sink?.insertText(s)
    }

    func compressedRow(_ view: CompressedRowView, didTapAtNormalizedX x: Double) {
        if isSecureField {
            if let letter = engine.nearestLetters(for: [x]).first { insertSecure(letter) }
            return
        }
        if tapBuffer.isEmpty {
            capitalizeCurrentWord = settings.autoCapitalize && Autocapitalization.isSentenceStart(sink?.textBeforeCursor)
        }
        tapBuffer.append(x)
        refreshCandidates()
    }

    func compressedRow(_ view: CompressedRowView, didPickLetter letter: Character, atNormalizedX x: Double) {
        if isSecureField {
            insertSecure(letter)
            return
        }
        if tapBuffer.isEmpty {
            capitalizeCurrentWord = settings.autoCapitalize && Autocapitalization.isSentenceStart(sink?.textBeforeCursor)
        }
        tapBuffer.append(x)                                 // keep alignment for learning
        forcedLetters[tapBuffer.count - 1] = Character(letter.lowercased())
        refreshCandidates()
    }

    func compressedRow(_ view: CompressedRowView, didTapLetter letter: Character) {
        insertPrecise(String(letter))
    }

    /// Shared verbatim insertion for magnifier hint picks and panel chips, with
    /// smart punctuation re-spacing applied where it makes sense.
    private func insertPrecise(_ text: String) {
        if !tapBuffer.isEmpty { commit(word: nil) }
        let before = sink?.textBeforeCursor ?? ""
        if settings.smartSpacing, !isSecureField, text.count == 1, let ch = text.first,
           let replacement = TypingBehavior.smartPunctuation(ch, before: before) {
            sink?.deleteBackward()          // move the space to after the punctuation
            sink?.insertText(replacement)
        } else {
            sink?.insertText(text)
        }
        recomputeContext()
    }

    func compressedRowInsertSpace(_ view: CompressedRowView) { insertSpace() }
    func compressedRowInsertReturn(_ view: CompressedRowView) { insertReturn() }
    func compressedRowBackspace(_ view: CompressedRowView) { backspace() }
    func compressedRowDeleteWord(_ view: CompressedRowView) { deleteWord() }
    func compressedRowToggleShift(_ view: CompressedRowView) { toggleShift() }
}

// MARK: - SuggestionStripViewDelegate

extension KeyboardControllerView: SuggestionStripViewDelegate {
    func suggestionStrip(_ view: SuggestionStripView, didSelect word: String) {
        commit(word: word)
        sink?.insertText(" ")
    }

    // Long-press a candidate to remove it from the learned dictionary.
    func suggestionStrip(_ view: SuggestionStripView, didLongPress word: String) {
        guard engine.forget(word: word) else { return }   // only learned words are removable
        refreshCandidates()
    }

    func suggestionStripDidTogglePanels(_ view: SuggestionStripView) {
        cyclePanel()
    }

    func suggestionStripDidToggleNumbers(_ view: SuggestionStripView) {
        if bonusPanel?.kind == .numbers { closePanel() } else { showPanel(.numbers) }
    }

    func suggestionStripDidPaste(_ view: SuggestionStripView) {
        pasteFromClipboard()
    }
}

// MARK: - BonusPanelDelegate

extension KeyboardControllerView: BonusPanelDelegate {
    func panelInsert(_ text: String) {
        insertPrecise(text)
    }
    func panelMoveCursor(by offset: Int) {
        if !tapBuffer.isEmpty { commit(word: nil) }
        sink?.moveCursor(by: offset)
        recomputeContext()
    }
    func panelBackspace() { backspace() }
    func panelPaste() { pasteFromClipboard() }
    func panelClose() { closePanel() }
}

extension KeyboardControllerView {
    /// The one place pasteboard *content* is read — user-initiated, so the
    /// system's paste banner/alert here is expected.
    private func pasteFromClipboard() {
        if !tapBuffer.isEmpty { commit(word: nil) }
        if let s = UIPasteboard.general.string, !s.isEmpty { sink?.insertText(s); recomputeContext() }
    }
}
