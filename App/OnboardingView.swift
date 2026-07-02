import SwiftUI
import UIKit
import FilaKit

/// The app's first screen — the real keyboard, live, with a six-step tour.
/// Reading about gestures can't prove "tap roughly and it works"; thirty
/// seconds of doing them can. Enable steps live one push away.
struct OnboardingView: View {
    @StateObject private var model = ChallengeModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showTypeTuner = false
    @State private var textScale = 1.0
    @State private var textWidth = -0.3

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showTypeTuner {
                    TypeTunerPanel(scale: $textScale, width: $textWidth)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        .transition(reduceMotion ? .opacity
                                    : .move(edge: .top).combined(with: .opacity))
                }
                ChallengeCard(model: model)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                KeyboardPlayground(onTextMutation: { model.observe($0) },
                                   configure: { model.playground = $0 })
            }
            .animation(.spring(duration: 0.35), value: showTypeTuner)
            .navigationTitle("Tuntun")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Aa") { showTypeTuner.toggle() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink("Turn it on") { EnableView() }
                }
            }
            .onAppear {
                textScale = SettingsStore.shared.textScale
                textWidth = SettingsStore.shared.textWidth
            }
            .onChange(of: textScale) { _, value in write(value, key: "textScale") { $0.textScale = value } }
            .onChange(of: textWidth) { _, value in write(value, key: "textWidth") { $0.textWidth = value } }
        }
    }

    /// Persist a type axis and nudge the live keyboard: App Group (the keyboard
    /// reads it), standard defaults (so the Settings.app slider agrees and the
    /// activation sync doesn't undo it), then the Darwin change notification.
    private func write(_ value: Double, key: String, apply: (SettingsStore) -> Void) {
        apply(SettingsStore.shared)
        UserDefaults.standard.set(value, forKey: key)
        SettingsStore.shared.notifyChanged()
    }

}

/// The tour card: prompt + hint while a step is active, a green done-line
/// while celebrating, the ready card at the end, and a slim replay bar in
/// free play. Fixed minimum height so the keyboard below never jumps.
private struct ChallengeCard: View {
    @ObservedObject var model: ChallengeModel

    var body: some View {
        Group {
            if model.freePlay {
                replayBar
            } else if model.finished {
                closing
            } else if let challenge = model.current {
                step(challenge)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .animation(.spring(duration: 0.35), value: model.celebrating)
        .animation(.default, value: model.index)
        .animation(.default, value: model.finished)
    }

    private func step(_ challenge: Challenge) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                dots
                Spacer()
                Button("Skip") { model.skip() }
                    .font(.footnote)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            if model.celebrating {
                Label(challenge.done, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Text(challenge.prompt).font(.subheadline.weight(.semibold))
                Text(challenge.hint).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 84, alignment: .topLeading)
    }

    private var dots: some View {
        HStack(spacing: 5) {
            ForEach(0..<ChallengeModel.challenges.count, id: \.self) { i in
                Circle()
                    .fill(dotDone(i) ? Color.green : Color(.systemFill))
                    .frame(width: 6, height: 6)
            }
        }
    }

    private func dotDone(_ i: Int) -> Bool {
        i < model.index || model.finished || (i == model.index && model.celebrating)
    }

    private var closing: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("You're ready.").font(.headline)
            Text("Tuntun keeps learning as you type — your names, your slang, your words start showing up on their own.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                NavigationLink { EnableView() } label: {
                    Text("Turn on Tuntun").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                Button("Keep playing") { model.freePlay = true }
                    .font(.footnote)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var replayBar: some View {
        HStack {
            Text("Free play").font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Button("Replay the tour") { model.replay() }
                .font(.footnote)
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
        }
    }
}

/// How to enable the keyboard system-wide, plus the gesture cheat sheet.
struct EnableView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                StepRow(number: 1, text: "Open **Settings → General → Keyboard → Keyboards → Add New Keyboard** and pick **Tuntun**.")
                StepRow(number: 2, text: "Next time you type, touch and hold 🌐 on the keyboard and choose **Tuntun**.")

                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Open Settings", systemImage: "gearshape")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.tint, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }

                DisclosureGroup("Cheat sheet") {
                    VStack(alignment: .leading, spacing: 12) {
                        GestureRow(glyph: "•", action: "Tap the row", detail: "Type. Roughly where the letters are is enough.")
                        GestureRow(glyph: "→", action: "Flick right", detail: "Space.")
                        GestureRow(glyph: "←", action: "Flick left", detail: "Deletes the whole word. Keep pressing to keep deleting, faster and faster.")
                        GestureRow(glyph: "↑", action: "Flick up", detail: "Capitals. Once for one, twice to stay on.")
                        GestureRow(glyph: "↓", action: "Flick down", detail: "New line.")
                        GestureRow(glyph: "⊙", action: "Hold + slide", detail: "Zoom in to pick an exact letter; slide up for its number or symbol.")
                    }
                    .padding(.top, 8)
                }

                Label("Tuntun's options live in the Settings app, under Tuntun.", systemImage: "gearshape")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle("Turn on Tuntun")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct GestureRow: View {
    let glyph: String
    let action: String
    let detail: String

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(glyph)
                .font(.title3.bold())
                .frame(width: 40, height: 40)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(action).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct StepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text("\(number)")
                .font(.subheadline.bold())
                .frame(width: 28, height: 28)
                .background(.tint, in: Circle())
                .foregroundStyle(.white)
            Text(.init(text)).font(.subheadline)
            Spacer(minLength: 0)
        }
    }
}

#Preview {
    OnboardingView()
}
