import SwiftUI

struct LiquidGlassCard: ViewModifier {
    var cornerRadius: CGFloat = 14
    var strokeOpacity: Double = 0.18

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(strokeOpacity), lineWidth: 1)
            )
    }
}

extension View {
    func liquidGlassCard(cornerRadius: CGFloat = 14, strokeOpacity: Double = 0.18) -> some View {
        modifier(LiquidGlassCard(cornerRadius: cornerRadius, strokeOpacity: strokeOpacity))
    }
}
