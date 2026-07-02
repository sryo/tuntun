import SwiftUI
import FilaKit

@main
struct FilaApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            OnboardingView()
        }
        .onChange(of: scenePhase) { _, phase in
            // Copy Settings.app preferences into the App Group for the keyboard.
            if phase == .active { SettingsSync.run() }
        }
    }
}
