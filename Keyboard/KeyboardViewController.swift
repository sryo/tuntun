import UIKit
import FilaKit

/// The keyboard extension's principal class. A thin host: it embeds the shared
/// ``KeyboardControllerView`` and wires it to the document proxy, the system
/// input-mode switcher, and document/selection change notifications. All
/// composition logic lives in `FilaKit`, shared with the container-app playground.
final class KeyboardViewController: UIInputViewController {
    private var keyboard: KeyboardControllerView!

    override func viewDidLoad() {
        super.viewDidLoad()
        // The Info.plist PrimaryLanguage is a static en-US; report the language
        // the user actually configured so the system keyboard switcher shows it.
        primaryLanguage = SettingsStore.shared.primaryLanguage.rawValue
        keyboard = KeyboardControllerView()
        keyboard.sink = ProxyTextSink(proxy: textDocumentProxy)
        applyFieldTraits()
        keyboard.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyboard)

        // Size the input view explicitly — otherwise iOS gives the extension its
        // default (tall) keyboard height and the fixed-height row stretches to fill.
        let height = view.heightAnchor.constraint(equalToConstant: KeyboardControllerView.preferredHeight)
        height.priority = .required - 1   // avoid conflicting with the system's layout height
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            height,
            keyboard.topAnchor.constraint(equalTo: view.topAnchor),
            keyboard.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            keyboard.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            keyboard.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
        ])
    }

    // Fired for host-side edits too (caret moves, autocorrect, field switches) —
    // the controller re-syncs so a stale provisional never deletes unrelated text.
    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        applyFieldTraits()
        keyboard.hostTextDidChange()
    }

    /// Adapt to the focused field: verbatim entry for secure fields, and the
    /// numbers panel auto-opens for digit-only keyboards.
    private func applyFieldTraits() {
        keyboard.isSecureField = textDocumentProxy.isSecureTextEntry ?? false
        let kind = textDocumentProxy.keyboardType
        keyboard.isNumericField = kind == .numberPad || kind == .phonePad
            || kind == .decimalPad || kind == .asciiCapableNumberPad
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        keyboard.hostTextDidChange()
    }
}
