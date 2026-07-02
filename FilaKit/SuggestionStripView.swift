import UIKit
import FilaCore

@MainActor
protocol SuggestionStripViewDelegate: AnyObject {
    func suggestionStrip(_ view: SuggestionStripView, didSelect word: String)
    /// Long-press on a candidate — remove it from the learned dictionary.
    func suggestionStrip(_ view: SuggestionStripView, didLongPress word: String)
    /// The always-visible ☺ button — opens/cycles the bonus panels (emoji, cursor).
    func suggestionStripDidTogglePanels(_ view: SuggestionStripView)
    /// The always-visible 123 button — toggles the numbers & symbols panel.
    func suggestionStripDidToggleNumbers(_ view: SuggestionStripView)
    /// The clipboard chip shown while the strip is idle — inserts the pasteboard.
    func suggestionStripDidPaste(_ view: SuggestionStripView)
}

/// A scroll view whose drags win over the UIButtons filling it — by default
/// `touchesShouldCancel(in:)` refuses to cancel UIControl tracking, so a swipe
/// that starts on a candidate/chip would never scroll. Shared by the suggestion
/// strip and the bonus panels, both of which are walls of buttons.
final class ButtonRowScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}

/// The QuickType-style candidate bar. Third-party keyboards can't inject into the
/// system suggestion bar, so we draw our own. Populated from the decoder's ranked
/// candidates; tapping a cell commits that word, long-pressing one forgets it.
final class SuggestionStripView: UIView {
    weak var delegate: SuggestionStripViewDelegate?

    private let stack = UIStackView()
    private let scroll = ButtonRowScrollView()
    private let panelButton = UIButton(type: .system)
    private let numbersButton = UIButton(type: .system)
    var theme: Theme = .dark {
        didSet {
            panelButton.tintColor = theme.glyph.withAlphaComponent(0.6)
            numbersButton.setTitleColor(theme.glyph.withAlphaComponent(0.6), for: .normal)
            update(with: currentCandidates, showPaste: showsPaste)
        }
    }
    private var showsPaste = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Transparent — the keyboard's single background shows through.
        backgroundColor = .clear
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        panelButton.setImage(UIImage(systemName: "face.smiling"), for: .normal)
        panelButton.tintColor = theme.glyph.withAlphaComponent(0.6)
        panelButton.translatesAutoresizingMaskIntoConstraints = false
        panelButton.addTarget(self, action: #selector(panelTapped), for: .touchUpInside)
        numbersButton.setTitle("123", for: .normal)
        numbersButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        numbersButton.setTitleColor(theme.glyph.withAlphaComponent(0.6), for: .normal)
        numbersButton.translatesAutoresizingMaskIntoConstraints = false
        numbersButton.addTarget(self, action: #selector(numbersTapped), for: .touchUpInside)
        addSubview(scroll)
        addSubview(panelButton)
        addSubview(numbersButton)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            numbersButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            numbersButton.topAnchor.constraint(equalTo: topAnchor),
            numbersButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            numbersButton.widthAnchor.constraint(equalToConstant: 44),

            panelButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            panelButton.topAnchor.constraint(equalTo: topAnchor),
            panelButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            panelButton.widthAnchor.constraint(equalToConstant: 44),

            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: numbersButton.trailingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: panelButton.leadingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func update(with candidates: [DecodeCandidate], showPaste: Bool = false) {
        showsPaste = showPaste
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if candidates.isEmpty, showPaste {
            var config = UIButton.Configuration.plain()
            config.image = UIImage(systemName: "doc.on.clipboard")
            config.imagePadding = 6
            config.preferredSymbolConfigurationForImage = .init(pointSize: 13, weight: .medium)
            var container = AttributeContainer()
            container.font = .systemFont(ofSize: 15, weight: .medium)
            config.attributedTitle = AttributedString("Paste", attributes: container)
            config.baseForegroundColor = theme.glyph.withAlphaComponent(0.6)
            let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                self.delegate?.suggestionStripDidPaste(self)
            })
            stack.addArrangedSubview(button)
            currentCandidates = []
            return
        }
        for (index, candidate) in candidates.prefix(12).enumerated() {
            let button = UIButton(type: .system)
            button.setTitle(candidate.word, for: .normal)
            // The top candidate (the one that will auto-commit) is emphasized.
            button.setTitleColor(index == 0 ? theme.accent : theme.glyph, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 16, weight: index == 0 ? .semibold : .regular)
            button.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)
            button.tag = index
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
            button.addGestureRecognizer(hold)
            if index > 0 {
                let sep = UIView()
                sep.backgroundColor = theme.glyph.withAlphaComponent(0.15)
                sep.translatesAutoresizingMaskIntoConstraints = false
                button.addSubview(sep)
                NSLayoutConstraint.activate([
                    sep.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                    sep.topAnchor.constraint(equalTo: button.topAnchor, constant: 8),
                    sep.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -8),
                    sep.widthAnchor.constraint(equalToConstant: 1),
                ])
            }
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 76).isActive = true
            button.contentEdgeInsets = .init(top: 0, left: 10, bottom: 0, right: 10)
            stack.addArrangedSubview(button)
        }
        currentCandidates = Array(candidates.prefix(12))
    }

    private var currentCandidates: [DecodeCandidate] = []

    @objc private func tapped(_ sender: UIButton) {
        guard sender.tag < currentCandidates.count else { return }
        delegate?.suggestionStrip(self, didSelect: currentCandidates[sender.tag].word)
    }

    @objc private func held(_ gr: UILongPressGestureRecognizer) {
        guard gr.state == .began, let button = gr.view as? UIButton,
              button.tag < currentCandidates.count else { return }
        delegate?.suggestionStrip(self, didLongPress: currentCandidates[button.tag].word)
    }

    @objc private func panelTapped() {
        delegate?.suggestionStripDidTogglePanels(self)
    }

    @objc private func numbersTapped() {
        delegate?.suggestionStripDidToggleNumbers(self)
    }
}
