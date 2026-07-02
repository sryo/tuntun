import UIKit

/// The keyboard's glyph palette. The surface itself is always transparent — the
/// system keyboard material behind it provides the background.
public struct Theme: Sendable {
    public var glyph: UIColor          // letters, numbers, strip text
    public var bubble: UIColor         // magnifier callout fill
    public var accent: UIColor         // emphasized (top) suggestion, bubble border

    public static let dark = Theme(
        glyph: UIColor(white: 0.92, alpha: 1),
        bubble: UIColor(white: 0.28, alpha: 1),
        accent: .systemBlue)

    public static let light = Theme(
        glyph: UIColor(white: 0.07, alpha: 1),   // near-black text
        bubble: UIColor(white: 0.99, alpha: 1),  // white callout card
        accent: .systemBlue)

    /// The palette for the current appearance. The keyboard surface itself is
    /// always transparent (the system keyboard material shows through), so the
    /// palette just follows the host's light/dark style.
    public static func forTraits(_ traits: UITraitCollection) -> Theme {
        traits.userInterfaceStyle == .light ? .light : .dark
    }
}
