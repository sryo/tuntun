import SwiftUI
import UIKit
import FilaKit

/// The variable-type pad: drag in 2D to explore glyph style (X: width, with
/// weight riding along — hairline narrow → black wide) and size (Y) — every
/// tick renders live on the keyboard underneath. The knob's "Aa" specimen
/// previews the exact font the row will draw.
struct TypeTunerPanel: View {
    @Binding var scale: Double
    @Binding var width: Double

    static let defaultScale = 1.0
    static let defaultWidth = -0.3
    static let scaleRange = 0.6...1.5
    static let widthRange = -0.5...0.3

    /// Detent lattice: width columns at the named SF instances (matching
    /// RowFont's calibration anchors), size rows at landmark scales. The knob
    /// snaps to these so a tuning can be repeated exactly.
    static let widthStops: [Double] = [-0.5, -0.4, -0.3, -0.2, -0.1, 0.0, 0.1, 0.2, 0.3]
    static let scaleStops: [Double] = [0.6, 0.8, 1.0, 1.25, 1.5]

    @State private var resetCount = 0

    private var isDirty: Bool {
        abs(scale - Self.defaultScale) > 0.001
            || abs(width - Self.defaultWidth) > 0.001
    }

    var body: some View {
        TypePad(scale: $scale, width: $width)
            .frame(height: 128)
            .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .overlay(alignment: .topTrailing) {
            if isDirty {
                Button {
                    withAnimation(.spring(duration: 0.35)) {
                        scale = Self.defaultScale
                        width = Self.defaultWidth
                    }
                    resetCount += 1
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isDirty)
        .sensoryFeedback(.impact(weight: .medium), trigger: resetCount)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Type tuner")
    }
}

/// The 2D well: X = width with weight riding along (hairline-narrow → black-
/// wide), Y = size (small → big).
private struct TypePad: View {
    @Binding var scale: Double
    @Binding var width: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var grabOffset: CGSize?     // nil until a drag decides its mode
    @State private var overshoot: CGSize = .zero
    @State private var isDragging = false
    @State private var edgeHitCount = 0
    @State private var wasAtEdge = false
    @State private var snappedToDefault = false
    /// The lattice dot the knob is locked onto (widthIndex * 100 + scaleIndex),
    /// nil while free — ticks the haptic only when a *new* dot engages.
    @State private var snappedDotKey: Int?
    @State private var dotTickCount = 0

    private let knobRadius: CGFloat = 22

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let knob = knobPosition(in: size)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))

                Canvas { ctx, canvasSize in
                    // Detent lattice — a dot per width stop × scale stop.
                    var dots = Path()
                    for w in TypeTunerPanel.widthStops {
                        for s in TypeTunerPanel.scaleStops {
                            let p = position(scale: s, width: w, in: canvasSize)
                            dots.addEllipse(in: CGRect(x: p.x - 1.3, y: p.y - 1.3, width: 2.6, height: 2.6))
                        }
                    }
                    ctx.fill(dots, with: .color(.primary.opacity(0.12)))
                    // Default-position ring.
                    let def = position(scale: TypeTunerPanel.defaultScale,
                                       width: TypeTunerPanel.defaultWidth, in: canvasSize)
                    ctx.stroke(Path(ellipseIn: CGRect(x: def.x - 2.5, y: def.y - 2.5, width: 5, height: 5)),
                               with: .color(.secondary.opacity(0.45)), lineWidth: 1)
                    // Crosshair through the knob.
                    var cross = Path()
                    cross.move(to: CGPoint(x: knob.x, y: 0))
                    cross.addLine(to: CGPoint(x: knob.x, y: canvasSize.height))
                    cross.move(to: CGPoint(x: 0, y: knob.y))
                    cross.addLine(to: CGPoint(x: canvasSize.width, y: knob.y))
                    ctx.stroke(cross, with: .color(.primary.opacity(0.15)), lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Text("WIDTH")
                    .font(.system(size: 9, weight: .medium)).tracking(1.5)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .position(x: size.width / 2, y: size.height - 8)
                Text("SIZE")
                    .font(.system(size: 9, weight: .medium)).tracking(1.5)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(-90))
                    .position(x: 10, y: size.height / 2)

                knobView
                    .position(x: knob.x + overshoot.width, y: knob.y + overshoot.height)

                if isDragging {
                    badge
                        .position(x: knob.x, y: max(18, knob.y - 34))
                        .transition(.opacity)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .gesture(dragGesture(in: size))
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if reduceMotion {
                    width = TypeTunerPanel.defaultWidth
                    scale = TypeTunerPanel.defaultScale
                } else {
                    withAnimation(.spring(duration: 0.35)) {
                        width = TypeTunerPanel.defaultWidth
                        scale = TypeTunerPanel.defaultScale
                    }
                }
            })
        }
        .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: edgeHitCount)
        .sensoryFeedback(.selection, trigger: snappedToDefault) { !$0 && $1 }
        .sensoryFeedback(.selection, trigger: dotTickCount)
        .accessibilityElement()
        .accessibilityLabel("Size and width")
        .accessibilityValue("\(String(format: "%.2f", scale)) times, width \(String(format: "%.2f", width))")
        .accessibilityAdjustableAction { direction in
            let step = 0.05
            scale = (direction == .increment ? scale + step : scale - step)
                .clamped(to: TypeTunerPanel.scaleRange)
        }
    }

    private var knobView: some View {
        ZStack {
            Circle()
                .fill(.thinMaterial)
                .overlay(Circle().strokeBorder(
                    isDragging ? AnyShapeStyle(.tint.opacity(0.6)) : AnyShapeStyle(.primary.opacity(0.15)),
                    lineWidth: isDragging ? 1.5 : 0.75))
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            Text("Aa")
                .font(Font(RowFont.font(size: 17 * scale, widthTrait: width)))
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(width: knobRadius * 2, height: knobRadius * 2)
        .scaleEffect(isDragging && !reduceMotion ? 1.08 : 1)
        .animation(.spring(duration: 0.25), value: isDragging)
    }

    private var badge: some View {
        Text("\(String(format: "%.2f", scale))×  ·  \(String(format: "%+.2f", width))")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
    }

    // MARK: Geometry ↔ values

    private func position(scale: Double, width: Double, in size: CGSize) -> CGPoint {
        let xNorm = CGFloat((width - TypeTunerPanel.widthRange.lowerBound)
            / (TypeTunerPanel.widthRange.upperBound - TypeTunerPanel.widthRange.lowerBound))
        let yNorm = CGFloat((scale - TypeTunerPanel.scaleRange.lowerBound)
            / (TypeTunerPanel.scaleRange.upperBound - TypeTunerPanel.scaleRange.lowerBound))
        return CGPoint(x: knobRadius + xNorm * (size.width - knobRadius * 2),
                       y: (size.height - knobRadius) - yNorm * (size.height - knobRadius * 2))
    }

    private func knobPosition(in size: CGSize) -> CGPoint {
        position(scale: scale, width: width, in: size)
    }

    private func values(at point: CGPoint, in size: CGSize) -> (scale: Double, width: Double) {
        let xNorm = ((point.x - knobRadius) / max(1, size.width - knobRadius * 2)).clamped(to: 0...1)
        let yNorm = (((size.height - knobRadius) - point.y) / max(1, size.height - knobRadius * 2)).clamped(to: 0...1)
        let w = TypeTunerPanel.widthRange.lowerBound
            + Double(xNorm) * (TypeTunerPanel.widthRange.upperBound - TypeTunerPanel.widthRange.lowerBound)
        let s = TypeTunerPanel.scaleRange.lowerBound
            + Double(yNorm) * (TypeTunerPanel.scaleRange.upperBound - TypeTunerPanel.scaleRange.lowerBound)
        return (s, w)
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { drag in
                let knob = knobPosition(in: size)
                if grabOffset == nil {
                    let d = hypot(drag.location.x - knob.x, drag.location.y - knob.y)
                    // Grab-relative near the knob (no jump); absolute elsewhere.
                    grabOffset = d < 30
                        ? CGSize(width: knob.x - drag.location.x, height: knob.y - drag.location.y)
                        : .zero
                    isDragging = true
                }
                let target = CGPoint(x: drag.location.x + (grabOffset?.width ?? 0),
                                     y: drag.location.y + (grabOffset?.height ?? 0))
                var (s, w) = values(at: target, in: size)

                // Magnetic detents: each axis independently locks to its
                // nearest stop within 5pt, so a tuning is exactly repeatable.
                let free = position(scale: s, width: w, in: size)
                var dotW: Int?, dotS: Int?
                let stopXs = TypeTunerPanel.widthStops.map { position(scale: s, width: $0, in: size).x }
                if let i = stopXs.indices.min(by: { abs(stopXs[$0] - free.x) < abs(stopXs[$1] - free.x) }),
                   abs(stopXs[i] - free.x) < 5 {
                    w = TypeTunerPanel.widthStops[i]
                    dotW = i
                }
                let stopYs = TypeTunerPanel.scaleStops.map { position(scale: $0, width: w, in: size).y }
                if let j = stopYs.indices.min(by: { abs(stopYs[$0] - free.y) < abs(stopYs[$1] - free.y) }),
                   abs(stopYs[j] - free.y) < 5 {
                    s = TypeTunerPanel.scaleStops[j]
                    dotS = j
                }
                let dotKey: Int? = (dotW != nil && dotS != nil) ? dotW! * 100 + dotS! : nil
                if let dotKey, dotKey != snappedDotKey { dotTickCount += 1 }
                snappedDotKey = dotKey

                // Soft snap to the default marker.
                let defPos = position(scale: TypeTunerPanel.defaultScale,
                                      width: TypeTunerPanel.defaultWidth, in: size)
                let candidate = position(scale: s, width: w, in: size)
                let nearDefault = hypot(candidate.x - defPos.x, candidate.y - defPos.y) < 5
                if nearDefault {
                    s = TypeTunerPanel.defaultScale
                    w = TypeTunerPanel.defaultWidth
                }
                snappedToDefault = nearDefault

                scale = s
                width = w

                // Rubber-band: visual-only overshoot past the clamped position.
                let clampedPos = position(scale: s, width: w, in: size)
                let rawOver = CGSize(width: target.x - clampedPos.x, height: target.y - clampedPos.y)
                overshoot = CGSize(width: (rawOver.width * 0.25).clamped(to: -6...6),
                                   height: (rawOver.height * 0.25).clamped(to: -6...6))
                let atEdge = abs(overshoot.width) > 0.5 || abs(overshoot.height) > 0.5
                if atEdge, !wasAtEdge { edgeHitCount += 1 }
                wasAtEdge = atEdge
            }
            .onEnded { _ in
                grabOffset = nil
                wasAtEdge = false
                withAnimation(reduceMotion ? nil : .spring(duration: 0.3)) { overshoot = .zero }
                withAnimation(.easeOut(duration: 0.25).delay(0.5)) { isDragging = false }
            }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
