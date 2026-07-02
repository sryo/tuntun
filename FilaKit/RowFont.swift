import UIKit
import CoreText

/// Continuous type on the SF variable font. `UIFont.systemFont(width:weight:)`
/// snaps to the nearest *named instance* (4 widths × a handful of weights), so
/// smooth axes must set the underlying `wdth`/`wght` variation values directly.
/// The trait → axis mapping is calibrated at runtime from the named instances,
/// so the default (-0.3, 0.23) reproduces CompressedMedium exactly on any OS.
public enum RowFont {
    private static let wdthAxis = 2003072104
    private static let wghtAxis = 2003265652

    private static let axisDefaults: [Int: CGFloat] = {
        guard let axes = CTFontCopyVariationAxes(UIFont.systemFont(ofSize: 20)) as? [[String: Any]] else { return [:] }
        var out: [Int: CGFloat] = [:]
        for axis in axes {
            if let id = axis[kCTFontVariationAxisIdentifierKey as String] as? NSNumber,
               let def = axis[kCTFontVariationAxisDefaultValueKey as String] as? NSNumber {
                out[id.intValue] = CGFloat(def.doubleValue)
            }
        }
        return out
    }()

    /// (trait, axisValue) anchors read from the OS's named instances.
    private static let calibration: (width: [(CGFloat, CGFloat)], weight: [(CGFloat, CGFloat)])? = {
        func axisValue(widthTrait: CGFloat, weightTrait: CGFloat, axis: Int) -> CGFloat? {
            let font = UIFont.systemFont(ofSize: 20,
                                         weight: .init(rawValue: weightTrait),
                                         width: .init(rawValue: widthTrait))
            let variation = CTFontCopyVariation(font) as? [NSNumber: NSNumber] ?? [:]
            if let value = variation[NSNumber(value: axis)] { return CGFloat(value.doubleValue) }
            return axisDefaults[axis]   // named instances omit axes at their default
        }
        var width: [(CGFloat, CGFloat)] = []
        for stop in [-0.5, -0.4, -0.3, -0.2, -0.1, 0.0, 0.1, 0.2, 0.3] as [CGFloat] {
            guard let v = axisValue(widthTrait: stop, weightTrait: 0.23, axis: wdthAxis) else { return nil }
            width.append((stop, v))
        }
        var weight: [(CGFloat, CGFloat)] = []
        for stop in [-0.8, -0.6, -0.4, 0.0, 0.23, 0.3, 0.4, 0.56, 0.62] as [CGFloat] {
            guard let v = axisValue(widthTrait: -0.3, weightTrait: stop, axis: wghtAxis) else { return nil }
            weight.append((stop, v))
        }
        return (width, weight)
    }()

    private static func interpolate(_ t: CGFloat, in table: [(CGFloat, CGFloat)]) -> CGFloat {
        let clamped = min(max(t, table.first!.0), table.last!.0)
        for i in 1..<table.count where clamped <= table[i].0 {
            let (t0, a0) = table[i - 1]
            let (t1, a1) = table[i]
            let f = t1 == t0 ? 0 : (clamped - t0) / (t1 - t0)
            return a0 + f * (a1 - a0)
        }
        return table.last!.1
    }

    /// Weight rides the width axis — one drag sweeps both: hairline when
    /// narrow, black when wide. Pinned to Medium at the default width so the
    /// out-of-box look (Minuum parity, CompressedMedium) is unchanged.
    private static let weightCurve: [(CGFloat, CGFloat)] = [
        (-0.5, -0.8),   // UltraCompressed → Ultralight
        (-0.3, 0.23),   // Compressed (default) → Medium
        (0.3, 0.62),    // ExtraExpanded → Black
    ]

    /// A system font at a continuous width trait value; weight follows
    /// `weightCurve`.
    public static func font(size: CGFloat, widthTrait: CGFloat) -> UIFont {
        let weightTrait = interpolate(widthTrait, in: weightCurve)
        guard let calibration else {
            // Quantized but never wrong-looking.
            return .systemFont(ofSize: size,
                               weight: .init(rawValue: weightTrait),
                               width: .init(rawValue: widthTrait))
        }
        let variation: [Int: CGFloat] = [
            wdthAxis: interpolate(widthTrait, in: calibration.width),
            wghtAxis: interpolate(weightTrait, in: calibration.weight),
        ]
        // The base must sit at the axis defaults: CoreText strips variation
        // entries equal to an axis's default (wdth 100 = standard), so a named
        // instance here would leak its own values through at those points.
        let base = UIFont.systemFont(ofSize: size)
        let descriptor = base.fontDescriptor.addingAttributes([
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): variation,
        ])
        return UIFont(descriptor: descriptor, size: size)
    }
}
