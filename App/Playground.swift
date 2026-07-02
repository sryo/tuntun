import SwiftUI
import UIKit
import FilaKit

/// The live keyboard demo embedded in the onboarding tour: the production
/// ``KeyboardControllerView`` over a text view whose system keyboard is
/// suppressed.
struct KeyboardPlayground: UIViewControllerRepresentable {
    var onTextMutation: ((String) -> Void)? = nil
    var configure: ((PlaygroundController) -> Void)? = nil

    func makeUIViewController(context: Context) -> PlaygroundController {
        let controller = PlaygroundController()
        controller.onTextMutation = onTextMutation
        configure?(controller)
        return controller
    }
    func updateUIViewController(_ controller: PlaygroundController, context: Context) {}
}

/// Wraps the playground's sink so the tour can observe the document — the
/// keyboard mutates the text view programmatically, which fires no UIKit
/// notifications. Mutations within one run-loop turn coalesce into a single
/// flush, so a provisional rewrite or a word delete reads as one net change.
@MainActor
private final class ObservingSink: TextSink {
    private let base: TextViewSink
    private weak var textView: UITextView?
    var onMutation: ((String) -> Void)?
    private var flushScheduled = false

    init(textView: UITextView) {
        base = TextViewSink(textView: textView)
        self.textView = textView
    }

    func insertText(_ text: String) { base.insertText(text); scheduleFlush() }
    func deleteBackward() { base.deleteBackward(); scheduleFlush() }
    func moveCursor(by offset: Int) { base.moveCursor(by: offset) }
    var textBeforeCursor: String? { base.textBeforeCursor }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            self.onMutation?(self.textView?.text ?? "")
        }
    }
}

final class PlaygroundController: UIViewController {
    private let textView = UITextView()
    private var keyboard: KeyboardControllerView!
    /// One coalesced snapshot of the text per run-loop turn that mutated it.
    var onTextMutation: ((String) -> Void)?

    /// Reset the document (tour replay). Must re-sync the keyboard's
    /// composition state, or its provisional word would desync and the next
    /// render would delete phantom characters.
    func clearText() {
        textView.text = ""
        keyboard.hostTextDidChange()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        textView.font = .systemFont(ofSize: 22)
        textView.backgroundColor = .secondarySystemBackground
        textView.layer.cornerRadius = 14
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        // Suppress the system keyboard so only Tuntun drives this field.
        textView.inputView = UIView()
        textView.autocorrectionType = .no
        textView.translatesAutoresizingMaskIntoConstraints = false

        keyboard = KeyboardControllerView()
        let sink = ObservingSink(textView: textView)
        sink.onMutation = { [weak self] text in self?.onTextMutation?(text) }
        keyboard.sink = sink
        keyboard.translatesAutoresizingMaskIntoConstraints = false

        // The extension gets the system keyboard material from its UIInputView;
        // the playground fakes it so the transparent keyboard previews faithfully.
        let backdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        backdrop.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(textView)
        view.addSubview(backdrop)
        view.addSubview(keyboard)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: keyboard.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            // 16pt sides — aligned with the challenge card and tuner panel above.
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            textView.bottomAnchor.constraint(equalTo: keyboard.topAnchor, constant: -12),

            keyboard.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboard.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboard.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            keyboard.heightAnchor.constraint(equalToConstant: KeyboardControllerView.preferredHeight),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.becomeFirstResponder()
    }
}
