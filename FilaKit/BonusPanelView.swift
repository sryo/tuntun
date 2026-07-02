import UIKit
import FilaCore

@MainActor
protocol BonusPanelDelegate: AnyObject {
    func panelInsert(_ text: String)
    func panelMoveCursor(by offset: Int)
    func panelBackspace()
    func panelPaste()
    func panelClose()
}

/// A bonus panel that overlays the compressed row (opened from the suggestion
/// strip's 123/☺ buttons). Three kinds — precise numbers & symbols, an emoji
/// picker, and cursor/clipboard controls — an extras row,
/// adapted to what iOS lets a keyboard extension do.
final class BonusPanelView: UIView {
    enum Kind { case numbers, emoji, cursor }

    weak var delegate: BonusPanelDelegate?
    let kind: Kind
    var theme: Theme { didSet { applyTheme() } }

    private let scroll = ButtonRowScrollView()
    private let content = UIStackView()
    private let closeButton = UIButton(type: .system)

    init(kind: Kind, theme: Theme) {
        self.kind = kind
        self.theme = theme
        super.init(frame: .zero)
        build()
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private static let emojis = Array("😀😃😄😁😆😅😂🤣😊🙂🙃😉😌😍🥰😘😗😙😚🤗🤔🤨😐😑😶🙄😏😣😥😮😯😴😛😜😝🤤😒😓😔😕🙁☹️😖😞😟😢😭😤😠😡🤬🤯😳🥵🥶😱😨😰😥🤢🤮🥳😎🤓🧐👍👎👌✌️🤞🙏👏🙌💪🎉🔥✨⭐️❤️🧡💛💚💙💜🖤🤍💔❤️‍🔥💯✅❌")

    private func build() {
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.axis = .horizontal
        content.alignment = .center
        content.spacing = kind == .cursor ? 8 : 4
        content.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setTitle("✕", for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        closeButton.layer.cornerRadius = 9
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addAction(UIAction { [weak self] _ in self?.delegate?.panelClose() }, for: .touchUpInside)
        addSubview(closeButton)
        addSubview(scroll)
        scroll.addSubview(content)

        switch kind {
        case .numbers:
            // Digits first, then symbols — the precise glyphs the one-row keyboard
            // doesn't decode (the old numbers/symbols planes, as tappable chips).
            let glyphs = (KeyboardLayout.numbers1D.keys + KeyboardLayout.symbols1D.keys).map { String($0.letter) }
            for g in glyphs {
                let button = chip(g, size: 22) { [weak self] in self?.delegate?.panelInsert(g) }
                button.widthAnchor.constraint(equalToConstant: 44).isActive = true
                content.addArrangedSubview(button)
            }
        case .emoji:
            for e in Self.emojis {
                let button = chip(String(e), size: 28) { [weak self] in self?.delegate?.panelInsert(String(e)) }
                button.widthAnchor.constraint(equalToConstant: 44).isActive = true  // fixed width → never overlap
                content.addArrangedSubview(button)
            }
        case .cursor:
            content.addArrangedSubview(chip("⤒", size: 20) { [weak self] in self?.delegate?.panelMoveCursor(by: -1000) })
            content.addArrangedSubview(chip("◀", size: 20) { [weak self] in self?.delegate?.panelMoveCursor(by: -1) })
            content.addArrangedSubview(chip("▶", size: 20) { [weak self] in self?.delegate?.panelMoveCursor(by: 1) })
            content.addArrangedSubview(chip("⤓", size: 20) { [weak self] in self?.delegate?.panelMoveCursor(by: 1000) })
            content.addArrangedSubview(chip("⌫", size: 20) { [weak self] in self?.delegate?.panelBackspace() })
            content.addArrangedSubview(chip("Paste", size: 16) { [weak self] in self?.delegate?.panelPaste() })
        }

        NSLayoutConstraint.activate([
            // Always-visible close pinned to the leading edge — it never scrolls away.
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 46),
            closeButton.heightAnchor.constraint(equalToConstant: 38),

            scroll.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
    }

    private var chips: [UIButton] = []
    private func chip(_ title: String, size: CGFloat, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.plain()
        var container = AttributeContainer()
        container.font = .systemFont(ofSize: size)
        config.attributedTitle = AttributedString(title, attributes: container)
        config.contentInsets = .init(top: 6, leading: 8, bottom: 6, trailing: 8)
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        chips.append(button)
        return button
    }

    private func applyTheme() {
        // Transparent — the controller hides the row underneath instead.
        backgroundColor = .clear
        for chip in chips { chip.configuration?.baseForegroundColor = theme.glyph }
        closeButton.backgroundColor = theme.accent.withAlphaComponent(0.22)
        closeButton.setTitleColor(theme.glyph, for: .normal)
    }
}
