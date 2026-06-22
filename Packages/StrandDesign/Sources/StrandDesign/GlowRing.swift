import SwiftUI

// MARK: - GlowRing — crisp WHOOP-style score ring
//
// Quality here is CRISPNESS, not blur. A clean solid arc with rounded caps over a clearly-visible
// full-circle track (so the ring reads as "X% of a circle"), a bold centred number that counts up, and
// only a TIGHT, low-opacity glow hugging the arc (additive on dark, hidden on light) — never a wide
// fuzzy bloom. The arc springs in from 12 o'clock and re-animates when the value changes (day nav).
// Theme-aware (number + track follow light/dark). Motion gated on Reduce Motion; macOS-13 / iOS-17 safe.

public struct GlowRing: View {

    /// Target fill, 0...1.
    public var fraction: Double
    /// The number shown in the centre — rolls up to this.
    public var value: Double
    /// Formats the (animated) value into the centre string.
    public var format: (Double) -> String
    /// The arc colour (solid, saturated — the domain accent).
    public var color: Color
    public var diameter: CGFloat
    public var lineWidth: CGFloat

    public init(fraction: Double, value: Double, format: @escaping (Double) -> String,
                color: Color, diameter: CGFloat, lineWidth: CGFloat) {
        self.fraction = fraction
        self.value = value
        self.format = format
        self.color = color
        self.diameter = diameter
        self.lineWidth = lineWidth
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var clamped: CGFloat { CGFloat(min(max(fraction, 0), 1)) }
    private var filled: CGFloat { appeared ? clamped : 0 }
    private var shown: Double { appeared ? value : 0 }
    private var drawSpring: Animation { .spring(response: 0.9, dampingFraction: 0.86) }

    public var body: some View {
        ZStack {
            // Clearly-visible full-circle track, so the arc reads as a fraction of a circle (like WHOOP).
            Circle()
                .stroke(StrandPalette.textPrimary.opacity(0.10),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            // A TIGHT glow hugging the arc — subtle, additive on dark, hidden on light. Kept narrow so
            // the ring stays crisp; the sharp arc below carries the read.
            arc.stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .blur(radius: lineWidth * 0.3)
                .opacity(0.22)
                .additiveBloom()

            // The crisp, solid arc.
            arc.stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            // Centred rolling number.
            Text(format(shown))
                .font(StrandFont.rounded(diameter * 0.36, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
                .padding(.horizontal, lineWidth + 4)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.85), value: shown)
        }
        .frame(width: diameter, height: diameter)
        .animation(reduceMotion ? nil : drawSpring, value: filled)
        .onAppear { appeared = true }
    }

    /// The trimmed arc, drawn from 12 o'clock clockwise.
    private var arc: some Shape {
        Circle().trim(from: 0, to: max(0.0001, filled)).rotation(.degrees(-90))
    }
}
