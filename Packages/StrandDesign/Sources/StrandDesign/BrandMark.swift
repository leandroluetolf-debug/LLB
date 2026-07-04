import SwiftUI

// MARK: - BrandMark — the LLB wordmark (matches the launcher icon)

/// Square dark tile with a bold **LLB** wordmark — same look as the home-screen icon.
/// Scales from a small list avatar up to an onboarding hero.
public struct BrandMark: View {

    /// Edge length of the square mark; everything scales from this.
    public var size: CGFloat

    public init(size: CGFloat = 120) {
        self.size = size
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                .fill(Color(hex: "#0E1116"))
            Text("LLB")
                .font(.system(size: size * 0.28, weight: .bold, design: .default))
                .foregroundStyle(Color(hex: "#E8E8E8"))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("LLB"))
        .accessibilityAddTraits(.isImage)
    }
}

#if DEBUG
#Preview("BrandMark — sizes") {
    VStack(spacing: 40) {
        BrandMark(size: 120)
        HStack(spacing: 28) {
            BrandMark(size: 72)
            BrandMark(size: 44)
            BrandMark(size: 28)
        }
    }
    .padding(48)
    .frame(width: 420, height: 460)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
