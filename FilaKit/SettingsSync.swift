import Foundation
import FilaCore

/// `Settings.bundle` preferences are written to the app's *standard* defaults,
/// but the keyboard extension can only read the App Group. The container app runs
/// this on every activation to copy them across and notify the running keyboard.
/// (So changes made in Settings.app take effect after Fila is next opened.)
@MainActor
public enum SettingsSync {
    public static func run() {
        let std = UserDefaults.standard
        // Seed defaults that match Settings.bundle, so values are correct even
        // before the user ever opens the Settings page.
        std.register(defaults: [
            "primaryLanguage": "en", "languageWeight": 1.0,
            "textScale": 1.0, "textWidth": -0.3,
            "autoCapitalize": true, "smartSpacing": true,
            "dict_en": true,
        ])
        guard let group = UserDefaults(suiteName: FilaConfig.appGroupID) else { return }

        for key in ["primaryLanguage", "languageWeight",
                    "textScale", "textWidth",
                    "autoCapitalize", "smartSpacing"] {
            if let value = std.object(forKey: key) { group.set(value, forKey: key) }
        }
        var enabled = KeyboardLanguage.allCases.filter { std.bool(forKey: "dict_\($0.rawValue)") }.map(\.rawValue)
        if enabled.isEmpty { enabled = ["en"] }
        group.set(enabled, forKey: "enabledDictionaries")

        SettingsStore().notifyChanged()
    }
}
