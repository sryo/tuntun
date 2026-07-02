import UIKit

/// Abstracts the destination the keyboard writes into, so the exact same
/// composition logic drives both the real extension (`UITextDocumentProxy`) and
/// the in-app playground (a `UITextView`). Everything the controller needs from
/// the document is expressed here.
@MainActor
public protocol TextSink: AnyObject {
    func insertText(_ text: String)
    func deleteBackward()
    /// Move the insertion point by `offset` characters (negative = left).
    func moveCursor(by offset: Int)
    var textBeforeCursor: String? { get }
}

/// `TextSink` backed by a keyboard extension's document proxy.
public final class ProxyTextSink: TextSink {
    private let proxy: UITextDocumentProxy
    public init(proxy: UITextDocumentProxy) { self.proxy = proxy }

    public func insertText(_ text: String) { proxy.insertText(text) }
    public func deleteBackward() { proxy.deleteBackward() }
    public func moveCursor(by offset: Int) { proxy.adjustTextPosition(byCharacterOffset: offset) }
    public var textBeforeCursor: String? { proxy.documentContextBeforeInput }
}

/// `TextSink` backed by a `UITextView`, for the container-app playground.
public final class TextViewSink: TextSink {
    private weak var textView: UITextView?
    public init(textView: UITextView) { self.textView = textView }

    // Edit the text storage directly (append/trim at the end) so typing shows
    // reliably regardless of first-responder/marked-text state in the playground.
    public func insertText(_ text: String) {
        guard let tv = textView else { return }
        tv.text = (tv.text ?? "") + text
        moveCaretToEnd(tv)
    }
    public func deleteBackward() {
        guard let tv = textView, let s = tv.text, !s.isEmpty else { return }
        tv.text = String(s.dropLast())
        moveCaretToEnd(tv)
    }
    public func moveCursor(by offset: Int) {
        guard let tv = textView, let sel = tv.selectedTextRange,
              let pos = tv.position(from: sel.start, offset: offset) else { return }
        tv.selectedTextRange = tv.textRange(from: pos, to: pos)
    }
    public var textBeforeCursor: String? { textView?.text }

    private func moveCaretToEnd(_ tv: UITextView) {
        let end = tv.endOfDocument
        tv.selectedTextRange = tv.textRange(from: end, to: end)
    }
}
