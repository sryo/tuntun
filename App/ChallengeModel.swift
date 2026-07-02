import UIKit

/// What the user just did in the playground, classified from one coalesced
/// text mutation (see ``ObservingSink``).
enum DemoAction {
    case typed(lastWord: String)
    case space
    case wordDeleted
    case newline
    case capsWord
    case exactCharacter
}

enum ChallengeDetector {
    /// Classify the net text change of one run-loop turn. Prefix-diffing is
    /// sound here because the playground sink only appends/trims at the end.
    static func classify(old: String, new: String) -> DemoAction? {
        guard old != new else { return nil }
        let oldChars = Array(old), newChars = Array(new)
        var p = 0
        while p < oldChars.count, p < newChars.count, oldChars[p] == newChars[p] { p += 1 }
        let deleted = oldChars.count - p
        let inserted = String(newChars[p...])

        if inserted.contains("\n") { return .newline }
        // Plain " " or smart ". "; a commit can rewrite the word in the same
        // turn, so any insertion ending in a space counts as the space gesture.
        if inserted.hasSuffix(" ") { return .space }
        if inserted.isEmpty, deleted >= 2 { return .wordDeleted }
        // Digits never come from tap decoding — only the magnifier or 123 panel.
        if inserted.count == 1, inserted.first!.isNumber { return .exactCharacter }
        let lastWord = new.split(whereSeparator: { $0 == " " || $0 == "\n" }).last.map(String.init) ?? ""
        if lastWord.count >= 2, lastWord == lastWord.uppercased(), lastWord != lastWord.lowercased() {
            return .capsWord
        }
        if !lastWord.isEmpty { return .typed(lastWord: lastWord) }
        return nil
    }
}

struct Challenge {
    let prompt: String
    let hint: String
    let done: String
    let matches: (DemoAction) -> Bool
}

/// Drives the six-step tour: feeds coalesced playground text through the
/// detector, advances on a match, and owns the replay/free-play state.
@MainActor
final class ChallengeModel: ObservableObject {
    @Published private(set) var index = 0
    @Published private(set) var finished = false
    /// True while the checkmark + done-line shows, before auto-advancing.
    @Published private(set) var celebrating = false
    /// The user chose "Keep playing" — collapse the card to a slim replay bar.
    @Published var freePlay = false

    weak var playground: PlaygroundController?
    private var lastText = ""

    static let challenges: [Challenge] = [
        Challenge(prompt: "Type hello — don't aim, just tap where the letters roughly are.",
                  hint: "Sloppy is fine. Close enough always counts.",
                  done: "That's it — you never have to hit the exact key.",
                  matches: { action in
                      guard case .typed(let word) = action else { return false }
                      return word.lowercased() == "hello"
                  }),
        Challenge(prompt: "Flick right anywhere on the row.",
                  hint: "That's space.",
                  done: "Space — and the word locks in.",
                  matches: { action in
                      guard case .space = action else { return false }
                      return true
                  }),
        Challenge(prompt: "Flick left.",
                  hint: "The whole word goes at once. Keep your finger down and it keeps deleting, faster and faster.",
                  done: "Gone. No tap-tap-tapping.",
                  matches: { action in
                      guard case .wordDeleted = action else { return false }
                      return true
                  }),
        Challenge(prompt: "Flick up twice — the row switches to CAPITALS — then type a word.",
                  hint: "One flick capitalizes just the next word's start.",
                  done: "Flick up a third time to turn caps off.",
                  matches: { action in
                      guard case .capsWord = action else { return false }
                      return true
                  }),
        Challenge(prompt: "Flick down.",
                  hint: "New line.",
                  done: "Return, without a return key.",
                  matches: { action in
                      guard case .newline = action else { return false }
                      return true
                  }),
        Challenge(prompt: "Hold a finger on the row — it zooms in. Slide up onto the faint row and let go on 5.",
                  hint: "For the rare times you need one exact character.",
                  done: "Precise when you want it, fast the rest of the time.",
                  matches: { action in
                      guard case .exactCharacter = action else { return false }
                      return true
                  }),
    ]

    var current: Challenge? { finished ? nil : Self.challenges[index] }

    /// One coalesced text snapshot from the playground sink.
    func observe(_ newText: String) {
        defer { lastText = newText }
        guard !finished, !celebrating,
              let action = ChallengeDetector.classify(old: lastText, new: newText),
              Self.challenges[index].matches(action) else { return }
        celebrating = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, self.celebrating else { return }   // a Skip may have advanced already
            self.advance()
        }
    }

    func skip() {
        celebrating = false
        advance()
    }

    func replay() {
        playground?.clearText()
        lastText = ""
        index = 0
        finished = false
        celebrating = false
        freePlay = false
    }

    private func advance() {
        celebrating = false
        if index + 1 < Self.challenges.count { index += 1 } else { finished = true }
    }
}
