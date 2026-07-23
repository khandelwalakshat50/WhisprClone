import SwiftUI

/// Single dark capsule — grey edge, no color tint layers.
struct CrystalGlassSurface: View {
    let accent: Color
    let secondary: Color
    let cornerRadius: CGFloat

    var body: some View {
        Capsule(style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(white: 0.12),
                        Color(white: 0.07)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.40),
                                Color.white.opacity(0.14),
                                Color.white.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            }
    }
}
