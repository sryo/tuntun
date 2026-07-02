import UIKit
import CoreText
import FilaCore

/// Continuous type on the SF variable font. `UIFont.systemFont(width:weight:)`
/// snaps to the nearest *named instance* (4 widths × a handful of weights), so
/// smooth axes must set the underlying `wdth`/`wght` variation values directly.
/// The trait → axis mapping is calibrated at runtime from the named instances,
/// so the default (-0.3, 0.23) reproduces CompressedMedium exactly on any OS.
public enum RowFont {
    private static let wdthAxis = 2003072104
    private static let wghtAxis = 2003265652

    private static let axisDefaults: [Int: CGFloat] = {
        guard let axes = CTFontCopyVariationAxes(UIFont.systemFont(ofSize: 20)) as? [[String: Any]] else { return [:] }
        var out: [Int: CGFloat] = [:]
        for axis in axes {
            if let id = axis[kCTFontVariationAxisIdentifierKey as String] as? NSNumber,
               let def = axis[kCTFontVariationAxisDefaultValueKey as String] as? NSNumber {
                out[id.intValue] = CGFloat(def.doubleValue)
            }
        }
        return out
    }()

    /// (trait, axisValue) anchors read from the OS's named instances.
    private static let calibration: (width: [(CGFloat, CGFloat)], weight: [(CGFloat, CGFloat)])? = {
        func axisValue(widthTrait: CGFloat, weightTrait: CGFloat, axis: Int) -> CGFloat? {
            let font = UIFont.systemFont(ofSize: 20,
                                         weight: .init(rawValue: weightTrait),
                                         width: .init(rawValue: widthTrait))
            let variation = CTFontCopyVariation(font) as? [NSNumber: NSNumber] ?? [:]
            if let value = variation[NSNumber(value: axis)] { return CGFloat(value.doubleValue) }
            return axisDefaults[axis]   // named instances omit axes at their default
        }
        var width: [(CGFloat, CGFloat)] = []
        for stop in [-0.5, -0.4, -0.3, -0.2, -0.1, 0.0, 0.1, 0.2, 0.3] as [CGFloat] {
            guard let v = axisValue(widthTrait: stop, weightTrait: 0.23, axis: wdthAxis) else { return nil }
            width.append((stop, v))
        }
        var weight: [(CGFloat, CGFloat)] = []
        for stop in [-0.8, -0.6, -0.4, 0.0, 0.23, 0.3, 0.4, 0.56, 0.62] as [CGFloat] {
            guard let v = axisValue(widthTrait: -0.3, weightTrait: stop, axis: wghtAxis) else { return nil }
            weight.append((stop, v))
        }
        return (width, weight)
    }()

    private static func interpolate(_ t: CGFloat, in table: [(CGFloat, CGFloat)]) -> CGFloat {
        let clamped = min(max(t, table.first!.0), table.last!.0)
        for i in 1..<table.count where clamped <= table[i].0 {
            let (t0, a0) = table[i - 1]
            let (t1, a1) = table[i]
            let f = t1 == t0 ? 0 : (clamped - t0) / (t1 - t0)
            return a0 + f * (a1 - a0)
        }
        return table.last!.1
    }

    /// Weight rides the width axis — one drag sweeps both: hairline when
    /// narrow, black when wide. Pinned to Medium at the default width so the
    /// out-of-box look (Minuum parity, CompressedMedium) is unchanged.
    private static let weightCurve: [(CGFloat, CGFloat)] = [
        (-0.5, -0.8),   // UltraCompressed → Ultralight
        (-0.3, 0.23),   // Compressed (default) → Medium
        (0.3, 0.62),    // ExtraExpanded → Black
    ]

    /// A system font at a continuous width trait value; weight follows
    /// `weightCurve`.
    public static func font(size: CGFloat, widthTrait: CGFloat) -> UIFont {
        let weightTrait = interpolate(widthTrait, in: weightCurve)
        guard let calibration else {
            // Quantized but never wrong-looking.
            return .systemFont(ofSize: size,
                               weight: .init(rawValue: weightTrait),
                               width: .init(rawValue: widthTrait))
        }
        let variation: [Int: CGFloat] = [
            wdthAxis: interpolate(widthTrait, in: calibration.width),
            wghtAxis: interpolate(weightTrait, in: calibration.weight),
        ]
        // The base must sit at the axis defaults: CoreText strips variation
        // entries equal to an axis's default (wdth 100 = standard), so a named
        // instance here would leak its own values through at those points.
        let base = UIFont.systemFont(ofSize: size)
        let descriptor = base.fontDescriptor.addingAttributes([
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): variation,
        ])
        return UIFont(descriptor: descriptor, size: size)
    }
}

@MainActor
protocol CompressedRowViewDelegate: AnyObject {
    /// A tap on the row — ambiguous x, resolved by the decoder.
    func compressedRow(_ view: CompressedRowView, didTapAtNormalizedX x: Double)
    /// A precision pick — pin this exact letter at this position.
    func compressedRow(_ view: CompressedRowView, didPickLetter letter: Character, atNormalizedX x: Double)
    /// A magnifier pick from the hint layer — inserted verbatim.
    func compressedRow(_ view: CompressedRowView, didTapLetter letter: Character)
    func compressedRowInsertSpace(_ view: CompressedRowView)       // swipe →
    func compressedRowInsertReturn(_ view: CompressedRowView)      // swipe ↓
    func compressedRowBackspace(_ view: CompressedRowView)         // swipe ← and hold (repeats)
    func compressedRowDeleteWord(_ view: CompressedRowView)        // swipe ← (flick)
    func compressedRowToggleShift(_ view: CompressedRowView)       // swipe ↑ (⇧/⇪)
}

/// How the row should render the armed shift state (mirrors the controller's
/// off → once → lock cycle).
enum ShiftDisplay {
    case off, once, lock
}

/// The signature Fila control — a fully gesture-driven, single-line keyboard (no
/// bottom key row, no alternate planes). It draws the 1D column-major glyph line
/// with the faint hint layer above, and reports raw tap x's. All editing is
/// gestural: →space ·
/// ←delete word (flick) · ← hold = backspace repeat · ↑shift (row renders
/// capitals; lock tints them) · ↓return · long-press = precision (magnify + pick
/// the exact letter; slide up for its number/symbol). Keyboard switching lives
/// on the system's own globe bar. The ↖/↗ diagonals are reserved and fall
/// through to a press.
final class CompressedRowView: UIView {
    weak var delegate: CompressedRowViewDelegate?

    /// Armed shift, rendered on the row: `.once` draws capitals, `.lock` draws
    /// accent-tinted capitals.
    var shiftDisplay: ShiftDisplay = .off {
        didSet { guard shiftDisplay != oldValue else { return }; setNeedsDisplay() }
    }

    /// User-tunable multiplier on the glyph sizes (the "Text size" setting).
    var glyphScale: CGFloat = 1 {
        didSet { guard glyphScale != oldValue else { return }; setNeedsDisplay() }
    }

    /// UIFont.Width trait units (-0.5 ultra-compressed … 0.3 extra-expanded).
    var glyphWidth: CGFloat = -0.3 {
        didSet { guard glyphWidth != oldValue else { return }; fontCache.removeAll(); setNeedsDisplay() }
    }

    /// Descriptor resolution is too slow for the draw hot path; keyed on
    /// size|standardWidth, flushed when an axis changes.
    private var fontCache: [String: UIFont] = [:]

    var theme: Theme = .dark {
        didSet { setNeedsDisplay() }
    }

    private var keys: [KeyGeometry]
    /// The faint upper hint layer, dim near the top — it hints each key's
    /// number/punctuation.
    private var secondaryKeys: [KeyGeometry] { KeyboardLayout.lettersHint1D.keys }

    // Gesture state
    private var panHandled = false
    /// True once the pan recognizer actually began (moved past its ~10 pt
    /// threshold), which cancels `touchesEnded`. Lets a drifted tap be recovered.
    private var panRecognized = false
    /// Where the current touch started — used for the ambiguous press a drift
    /// falls back to, and to anchor the leftward-delete decision.
    private var panStart: CGPoint = .zero
    /// A leftward drag crossed the threshold: released quickly = delete word,
    /// still held after a beat = char-by-char backspace repeat.
    private var leftArmed = false
    private var leftHoldTask: Task<Void, Never>?
    private var backspaceTask: Task<Void, Never>?

    // Precision preview ("magnifier") state.
    private var previewX: CGFloat?              // live column while the magnifier shows; nil = hidden
    private var previewUsesSecondary = false    // magnify the hint layer vs the primary keys
    private var lastPreviewIndex: Int?          // for firing the haptic only on change
    /// True while a deliberate long-press drives precision picking; suppresses the
    /// normal tap/flick handling for that touch. Reset at the next touch-down.
    private var precisionActive = false
    private let selectionFeedback = UIImpactFeedbackGenerator(style: .light)  // needs Full Access

    func setKeys(_ newKeys: [KeyGeometry]) {
        keys = newKeys
        setNeedsDisplay()
    }

    init(keys: [KeyGeometry]) {
        self.keys = keys
        super.init(frame: .zero)
        // Transparent — the keyboard's single background shows through.
        backgroundColor = .clear
        isOpaque = false
        // Redraw on bounds changes (rotation) — the default .scaleToFill would
        // stretch the cached render instead.
        contentMode = .redraw

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delaysTouchesBegan = false
        addGestureRecognizer(pan)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.45   // deliberate hold = precision picking
        addGestureRecognizer(longPress)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        drawSecondaryLine(rect)                 // faint hint layer (top)
        drawLine(rect)                          // tappable primary layer
        drawPreviewCallout(rect)                // live magnifier (on precision gestures)
    }

    /// The dim, flat, smaller hint line near the top (no stagger, single dim colour).
    private func drawSecondaryLine(_ rect: CGRect) {
        let keys = secondaryKeys
        guard !keys.isEmpty else { return }
        let slotWidth = rect.width / CGFloat(keys.count)
        let fontSize = min(slotWidth * 1.1 * glyphScale, rect.height * 0.30)
        let y = rect.height * 0.26
        let attrs = textAttributes(size: fontSize, alpha: 0.3)
        for key in keys {
            draw(String(key.letter),
                 centeredAt: CGPoint(x: CGFloat(key.normalizedX) * rect.width, y: y),
                 attrs: attrs)
        }
    }

    /// Draw the glyph line. `key.row` drives a ±7% vertical nudge, so the letters
    /// (row cycling 0,1,2) gently zig-zag.
    private func drawLine(_ rect: CGRect) {
        let slotWidth = rect.width / CGFloat(max(keys.count, 1))
        // Compressed-width glyphs at a much larger size than the column would
        // allow for standard type; the zigzag puts neighbors on different
        // baselines so they interleave instead of colliding.
        let fontSize = min(slotWidth * 1.7 * glyphScale, rect.height * 0.62)
        let amplitude = rect.height * 0.10
        // Sits low in the row — the composition fills the space above the system
        // bar instead of floating at the top of it.
        let center = rect.height * 0.66
        let rowAlpha: [CGFloat] = [0.7, 1.0, 0.7]
        // Armed shift renders the row in capitals; lock tints them.
        let showCaps = shiftDisplay != .off
        let glyphColor = shiftDisplay == .lock ? theme.accent : theme.glyph
        for key in keys {
            let x = CGFloat(key.normalizedX) * rect.width
            let y = center + amplitude * CGFloat(key.row - 1)
            let attrs = textAttributes(size: fontSize, alpha: rowAlpha[min(key.row, 2)],
                                       color: glyphColor)
            let glyph = showCaps ? String(key.letter).uppercased() : String(key.letter)
            draw(glyph, centeredAt: CGPoint(x: x, y: y), attrs: attrs)
        }
    }

    /// The magnifier bubble: an enlarged copy of the currently-selected glyph with
    /// its faded neighbors. Sits BESIDE the finger — on whichever side has more room —
    /// so the finger never covers it, and slide-to-correct stays visible.
    private func drawPreviewCallout(_ rect: CGRect) {
        guard let px = previewX else { return }
        let source = previewUsesSecondary ? secondaryKeys : keys
        guard let idx = nearestIndex(in: source, toX: px, width: rect.width) else { return }
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        let w: CGFloat = 84, h: CGFloat = 50, gap: CGFloat = 26
        // Offset to the side with more space (finger on the left half → bubble right).
        let onRight = px < rect.width / 2
        let cx = max(w / 2 + 2, min(rect.width - w / 2 - 2, onRight ? px + gap + w / 2 : px - gap - w / 2))
        let bubble = CGRect(x: cx - w / 2, y: (rect.height - h) / 2, width: w, height: h)
        let path = UIBezierPath(roundedRect: bubble, cornerRadius: 12)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 7, color: UIColor(white: 0, alpha: 0.45).cgColor)
        theme.bubble.setFill()
        path.fill()
        ctx.restoreGState()
        theme.accent.setStroke()          // accent border so the bubble pops off the row
        path.lineWidth = 2
        path.stroke()

        let midY = bubble.midY
        let side = textAttributes(size: h * 0.30, alpha: 0.35, standardWidth: true)   // faint neighbors = slide-to-correct hint
        if idx > 0 {
            draw(String(source[idx - 1].letter), centeredAt: CGPoint(x: bubble.minX + w * 0.2, y: midY), attrs: side)
        }
        if idx < source.count - 1 {
            draw(String(source[idx + 1].letter), centeredAt: CGPoint(x: bubble.maxX - w * 0.2, y: midY), attrs: side)
        }
        draw(String(source[idx].letter), centeredAt: CGPoint(x: cx, y: midY),
             attrs: textAttributes(size: h * 0.6, standardWidth: true))
    }

    private func nearestIndex(in source: [KeyGeometry], toX x: CGFloat, width: CGFloat) -> Int? {
        guard width > 0, !source.isEmpty else { return nil }
        let nx = Double(max(0, min(width, x)) / width)
        return source.indices.min { abs(source[$0].normalizedX - nx) < abs(source[$1].normalizedX - nx) }
    }

    /// `standardWidth` pins the width axis to standard (the magnifier's zoomed
    /// glyphs); weight follows the width via RowFont's curve.
    private func textAttributes(size: CGFloat, alpha: CGFloat = 1, color: UIColor? = nil,
                                standardWidth: Bool = false) -> [NSAttributedString.Key: Any] {
        let key = "\(size)|\(standardWidth)"
        let font: UIFont
        if let cached = fontCache[key] {
            font = cached
        } else {
            font = RowFont.font(size: size, widthTrait: standardWidth ? 0 : glyphWidth)
            fontCache[key] = font
        }
        return [.font: font,
                .foregroundColor: (color ?? theme.glyph).withAlphaComponent(alpha)]
    }

    private func draw(_ text: String, centeredAt p: CGPoint, attrs: [NSAttributedString.Key: Any]) {
        let s = text as NSString
        let size = s.size(withAttributes: attrs)
        s.draw(at: CGPoint(x: p.x - size.width / 2, y: p.y - size.height / 2), withAttributes: attrs)
    }

    // MARK: Taps (typing)

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        precisionActive = false        // fresh touch; long-press may re-arm it
        panStart = t.location(in: self)
        selectionFeedback.prepare()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        defer { resetGesture(); setNeedsDisplay() }
        if precisionActive { return }        // long-press handled this touch
        guard let t = touches.first else { return }
        emitTap(at: t.location(in: self))
    }

    /// Route a touch-up at `p` to an ambiguous press. Shared with the pan handler:
    /// a small drag that latches the pan recognizer cancels `touchesEnded`, so the
    /// pan must emit the tap itself (otherwise a tap that drifts 10–45 pt is
    /// silently swallowed — below the flick threshold, past the pan threshold).
    private func emitTap(at p: CGPoint) {
        guard bounds.width > 0 else { return }
        let normalized = Double(max(0, min(bounds.width, p.x)) / bounds.width)
        delegate?.compressedRow(self, didTapAtNormalizedX: normalized)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        resetGesture()
        setNeedsDisplay()
    }

    // MARK: Gestures

    @objc private func handlePan(_ gr: UIPanGestureRecognizer) {
        let t = gr.translation(in: self)
        switch gr.state {
        case .began:
            panHandled = false
            panRecognized = true
            leftArmed = false
        case .changed:
            if precisionActive { return }        // long-press drives the magnifier
            guard !panHandled else { return }
            // Leftward drag past the threshold: the release decides — a flick
            // deletes the word; keeping the finger down turns
            // into char-by-char backspace repeat (Fila's stand-in for the delete key).
            if t.x < -45, abs(t.x) > abs(t.y) * 1.3 {
                panHandled = true
                armLeftDelete()
            }
        case .ended, .cancelled, .failed:
            leftHoldTask?.cancel()
            let repeating = backspaceTask != nil
            stopBackspaceRepeat()
            if precisionActive {                 // long-press committed; ignore pan
                leftArmed = false
                panHandled = false; panRecognized = false
                return
            }
            if leftArmed {
                // Released before the hold kicked in → it was a flick: delete word.
                if !repeating, gr.state == .ended { delegate?.compressedRowDeleteWord(self) }
            } else if !panHandled {
                // A quick directional flick that never entered the left path.
                var acted = false
                if abs(t.x) > abs(t.y) {
                    if t.x > 45 { delegate?.compressedRowInsertSpace(self); acted = true }
                } else if t.y < -35 {
                    // Straight up = shift. The diagonals are reserved — treat them
                    // as the press they started as (fall-through).
                    if abs(t.x) <= 30 { delegate?.compressedRowToggleShift(self) }
                    else { emitTap(at: panStart) }
                    acted = true
                } else if t.y > 35 {
                    delegate?.compressedRowInsertReturn(self); acted = true   // swipe ↓ = return
                }
                // Recognized pan below every flick threshold — a tap that drifted (or a
                // precise selection). `touchesEnded` was cancelled by the recognizer.
                if !acted, panRecognized, gr.state == .ended {
                    emitTap(at: gr.location(in: self))
                }
            }
            resetGesture()
            leftArmed = false
            panHandled = false
            panRecognized = false
        default:
            break
        }
    }

    /// Deliberate long-press = precision picking: show the magnifier, let the
    /// finger slide to the exact letter — or up into the faint hint layer for its
    /// number/symbol — and commit on release (letters are pinned so the decoder
    /// honors them). Quick taps never reach here, so autocorrect is intact.
    @objc private func handleLongPress(_ gr: UILongPressGestureRecognizer) {
        let p = gr.location(in: self)
        // Sliding above the midpoint between the two lines magnifies the hint layer.
        let secondary = p.y < bounds.height * 0.45 && !secondaryKeys.isEmpty
        switch gr.state {
        case .began:
            precisionActive = true
            leftHoldTask?.cancel()
            leftArmed = false
            stopBackspaceRepeat()
            setPreview(x: p.x, secondary: secondary)
        case .changed:
            setPreview(x: p.x, secondary: secondary)
        case .ended:
            if secondary {
                emitSecondary(atX: p.x)
            } else if let idx = nearestIndex(in: keys, toX: p.x, width: bounds.width) {
                delegate?.compressedRow(self, didPickLetter: keys[idx].letter, atNormalizedX: keys[idx].normalizedX)
            }
            hidePreview(); setNeedsDisplay()
        default:                                   // cancelled / failed
            hidePreview(); setNeedsDisplay()
        }
    }

    /// Insert the faint hint-layer glyph nearest to `x` (magnifier slide-up pick).
    private func emitSecondary(atX x: CGFloat) {
        guard bounds.width > 0, !secondaryKeys.isEmpty else { return }
        let nx = Double(max(0, min(bounds.width, x)) / bounds.width)
        if let key = secondaryKeys.min(by: { abs($0.normalizedX - nx) < abs($1.normalizedX - nx) }) {
            delegate?.compressedRow(self, didTapLetter: key.letter)
        }
    }

    // MARK: Precision preview (live magnifier)

    private func setPreview(x: CGFloat, secondary: Bool) {
        previewUsesSecondary = secondary
        previewX = x
        let source = secondary ? secondaryKeys : keys
        let idx = nearestIndex(in: source, toX: x, width: bounds.width)
        if idx != lastPreviewIndex { lastPreviewIndex = idx; selectionFeedback.impactOccurred() }
        setNeedsDisplay()
    }

    private func hidePreview() {
        guard previewX != nil else { return }
        previewX = nil
        lastPreviewIndex = nil
        setNeedsDisplay()
    }

    /// Clear the magnifier on any gesture terminus.
    private func resetGesture() {
        hidePreview()
    }

    // MARK: Leftward delete (flick = word, hold = accelerating char repeat)

    /// Wait a beat after the leftward threshold: if the finger is still down, the
    /// user wants char-by-char repeat rather than the word-delete flick.
    private func armLeftDelete() {
        leftArmed = true
        leftHoldTask?.cancel()
        leftHoldTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self, self.leftArmed else { return }
            self.startBackspaceRepeat()
        }
    }

    // Accelerating 500→200→100→50 ms delete curve, on single characters.
    private func startBackspaceRepeat() {
        backspaceTask?.cancel()
        backspaceTask = Task { @MainActor [weak self] in
            var count = 0
            while !Task.isCancelled {
                guard let self else { return }
                self.delegate?.compressedRowBackspace(self)
                count += 1
                let ms: UInt64 = count > 10 ? 50 : count > 5 ? 100 : count >= 2 ? 200 : 500
                try? await Task.sleep(nanoseconds: ms * 1_000_000)
            }
        }
    }

    private func stopBackspaceRepeat() {
        backspaceTask?.cancel()
        backspaceTask = nil
    }
}
