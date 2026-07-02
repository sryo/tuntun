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
/// lowercase; casing is a presentation transform).
/// Editing is gestural — →space · ←delete word (hold = backspace repeat) ·
/// ↑shift (row shows capitals) · ↓return · long-press = precision magnifier
/// (slide up for numbers/symbols). There are no alternate row planes: precise
/// digits/symbols live in the numbers panel (123 on the strip, auto-shown for
/// numeric fields), emoji/cursor panels behind ☺. Keyboard switching is the
/// system globe bar's job.
///
/// All composition state lives in ``CompositionSession`` (FilaCore, where it is
/// unit-tested); this view forwards gestures as session events and applies the
/// emitted commands to its sink, strip, and row.
@MainActor
public final class KeyboardControllerView: UIView {
    /// Where typed text goes. Strongly held — the controller owns its sink (the
    /// host creates it inline, so a weak ref would deallocate it immediately).
    public var sink: TextSink?

    private let engine = KeyboardEngine()
    private var session: CompositionSession!
    private var suggestionStrip: SuggestionStripView!
    private var compressedRow: CompressedRowView!

    /// Secure/password fields: taps insert the nearest letter verbatim — no
    /// decoding, no rewriting, no suggestions, and nothing is learned.
    public var isSecureField = false {
        didSet { session.configuration.isSecureField = isSecureField }
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

    private let stripHeight: CGFloat = 40
    private let rowHeight: CGFloat = 76
    /// Total keyboard height the extension should size its input view to
    /// (strip + gap + row + gap). Without this the row stretches to fill iOS's
    /// default keyboard height.
    public static let preferredHeight: CGFloat = 40 + 6 + 76 + 6

    private let settings = SettingsStore.shared
    private var settingsToken: AnyObject?
    private var theme: Theme = .dark
    private var bonusPanel: BonusPanelView?

    public init() {
        super.init(frame: .zero)
        buildViews()
        applyTheme()
        updateStrip([])     // idle strip offers Paste right away if the clipboard has text
        session = CompositionSession(
            configuration: makeConfiguration(),
            decode: { [engine] taps, context, forced in
                engine.candidates(for: taps, context: context, forced: forced)
            },
            readTextBeforeCursor: { [weak self] in self?.sink?.textBeforeCursor },
            emit: { [weak self] in self?.apply($0) })
        // Dictionaries load off-thread; when they land, any word typed in the
        // meantime is re-decoded against the real vocabulary.
        engine.onModelReady = { [weak self] in
            guard let self, self.session.isComposing else { return }
            self.session.refreshCandidates()
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
        session.configuration = makeConfiguration()
        compressedRow.setKeys(engine.keys)
        compressedRow.glyphScale = settings.textScale
        compressedRow.glyphWidth = settings.textWidth
        applyTheme()
    }

    private func makeConfiguration() -> CompositionConfiguration {
        CompositionConfiguration(autoCapitalize: settings.autoCapitalize,
                                 smartSpacing: settings.smartSpacing,
                                 isSecureField: isSecureField,
                                 language: engine.language)
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

    // MARK: Session wiring

    /// Apply one session command to the real sink/strip/row/engine.
    private func apply(_ command: CompositionCommand) {
        switch command {
        case .insertText(let text):
            sink?.insertText(text)
        case .deleteBackward(let count):
            for _ in 0..<count { sink?.deleteBackward() }
        case .moveCursor(let offset):
            sink?.moveCursor(by: offset)
        case .setStrip(let candidates):
            updateStrip(candidates)
        case .setShift(let shift):
            switch shift {
            case .off:  compressedRow.shiftDisplay = .off
            case .once: compressedRow.shiftDisplay = .once
            case .lock: compressedRow.shiftDisplay = .lock
            }
        case .learn(let word, let taps, let edits):
            engine.learn(word: word, taps: taps, edits: edits)
        case .unlearn(let word):
            engine.forget(word: word)
        }
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

    /// Called by the host whenever the document text or selection changes. If the
    /// change wasn't ours (the text before the caret no longer ends with the
    /// provisional word), the session abandons the composition in place —
    /// rewriting it would delete unrelated text — and rebuilds its context.
    public func hostTextDidChange() {
        session.hostTextDidChange()
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
        session.commitComposition()
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
    func compressedRow(_ view: CompressedRowView, didTapAtNormalizedX x: Double) {
        if isSecureField {
            if let letter = engine.nearestLetters(for: [x]).first { session.secureTap(letter) }
            return
        }
        session.tap(at: x)
    }

    func compressedRow(_ view: CompressedRowView, didPickLetter letter: Character, atNormalizedX x: Double) {
        if isSecureField {
            session.secureTap(letter)
            return
        }
        session.pickLetter(letter, at: x)
    }

    func compressedRow(_ view: CompressedRowView, didTapLetter letter: Character) {
        session.insertPrecise(String(letter))
    }

    func compressedRowInsertSpace(_ view: CompressedRowView) { session.insertSpace() }
    func compressedRowInsertReturn(_ view: CompressedRowView) { session.insertReturn() }
    func compressedRowBackspace(_ view: CompressedRowView) { session.backspace() }
    func compressedRowDeleteWord(_ view: CompressedRowView) { session.deleteWord() }
    func compressedRowToggleShift(_ view: CompressedRowView) { session.toggleShift() }
}

// MARK: - SuggestionStripViewDelegate

extension KeyboardControllerView: SuggestionStripViewDelegate {
    func suggestionStrip(_ view: SuggestionStripView, didSelect word: String) {
        session.selectCandidate(word)
    }

    // Long-press a candidate to remove it from the learned dictionary.
    func suggestionStrip(_ view: SuggestionStripView, didLongPress word: String) {
        guard engine.forget(word: word) else { return }   // only learned words are removable
        session.refreshCandidates()
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
        session.insertPrecise(text)
    }
    func panelMoveCursor(by offset: Int) {
        session.moveCursor(by: offset)
    }
    func panelBackspace() { session.backspace() }
    func panelPaste() { pasteFromClipboard() }
    func panelClose() { closePanel() }
}

extension KeyboardControllerView {
    /// The one place pasteboard *content* is read — user-initiated, so the
    /// system's paste banner/alert here is expected.
    private func pasteFromClipboard() {
        session.commitComposition()
        if let s = UIPasteboard.general.string, !s.isEmpty { session.insertVerbatim(s) }
    }
}
