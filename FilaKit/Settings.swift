import Foundation
import FilaCore

/// Shared config constant, usable from both the app and the extension.
public enum FilaConfig {
    public static let appGroupID = "group.com.sryo.fila"
}

/// User settings, shared between the container app (writes) and the keyboard
/// extension (reads) via the App Group. A Darwin notification lets the extension
/// repaint/reconfigure live when the app changes a setting.
@MainActor
public final class SettingsStore {
    public static let shared = SettingsStore()
    private let defaults = UserDefaults(suiteName: FilaConfig.appGroupID)
    private static let darwinName = "com.sryo.fila.settings-changed" as CFString

    public init() {}

    public var languageWeight: Double {
        get { defaults?.object(forKey: "languageWeight") as? Double ?? 1.0 }
        set { defaults?.set(newValue, forKey: "languageWeight") }
    }

    /// Multiplier on the row's glyph size (0.6–1.5; 1.0 = default).
    public var textScale: Double {
        get { defaults?.object(forKey: "textScale") as? Double ?? 1.0 }
        set { defaults?.set(newValue, forKey: "textScale") }
    }

    /// Glyph width on the row, in UIFont.Width trait units
    /// (-0.5 = ultra-compressed … 0.3 = extra-expanded; -0.3 compressed = default, today's look).
    public var textWidth: Double {
        get { defaults?.object(forKey: "textWidth") as? Double ?? -0.3 }
        set { defaults?.set(newValue, forKey: "textWidth") }
    }

    /// The default language — sets the physical layout (and is always an enabled
    /// dictionary). No in-keyboard language switching.
    public var primaryLanguage: KeyboardLanguage {
        get { defaults?.string(forKey: "primaryLanguage").flatMap(KeyboardLanguage.init(rawValue:)) ?? .english }
        set { defaults?.set(newValue.rawValue, forKey: "primaryLanguage") }
    }

    /// Dictionaries used together for prediction. Only those sharing the primary
    /// layout's script are actually consulted. Always includes the primary.
    public var enabledDictionaries: Set<KeyboardLanguage> {
        get {
            let langs = Set((defaults?.stringArray(forKey: "enabledDictionaries") ?? [])
                .compactMap(KeyboardLanguage.init(rawValue:)))
            return langs.isEmpty ? [primaryLanguage] : langs.union([primaryLanguage])
        }
        set { defaults?.set(newValue.union([primaryLanguage]).map(\.rawValue), forKey: "enabledDictionaries") }
    }

    public var autoCapitalize: Bool { bool("autoCapitalize", default: true) }
    public var smartSpacing: Bool { bool("smartSpacing", default: true) }      // double-space→period + smart punctuation

    private func bool(_ key: String, default def: Bool) -> Bool {
        defaults?.object(forKey: key) == nil ? def : (defaults?.bool(forKey: key) ?? def)
    }

    /// Broadcast that settings changed (call from the container app after writes).
    public func notifyChanged() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(Self.darwinName), nil, nil, true)
    }

    /// Observe settings changes (call from the extension). The handler runs on the
    /// main thread. Returns an opaque token kept alive by the caller.
    public static func observe(_ handler: @escaping @MainActor () -> Void) -> AnyObject {
        let token = DarwinObserver(handler: handler)
        let ptr = Unmanaged.passUnretained(token).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), ptr,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let obs = Unmanaged<DarwinObserver>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in obs.handler() }
            },
            darwinName, nil, .deliverImmediately)
        return token
    }

    private final class DarwinObserver {
        let handler: @MainActor () -> Void
        init(handler: @escaping @MainActor () -> Void) { self.handler = handler }
    }
}
