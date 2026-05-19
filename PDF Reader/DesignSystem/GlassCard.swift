import SwiftUI

/// A rounded-rect Liquid Glass surface used for grouped content blocks —
/// library thumbnails, AI message bubbles, signature picker rows, etc.
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = DesignSystem.Radius.medium
    var tint: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(DesignSystem.Spacing.l)
            .glassEffect(
                tint.map { Glass.regular.tint($0) } ?? .regular,
                in: .rect(cornerRadius: cornerRadius)
            )
    }
}

#Preview {
    GlassCard {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.s) {
            Text("Quarterly Report.pdf")
                .font(.headline)
            Text("12 pages · Modified yesterday")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
    .padding()
}
