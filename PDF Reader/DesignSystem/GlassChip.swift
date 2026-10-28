import SwiftUI

/// A capsule-shaped Liquid Glass chip for tags, filter pills, and toggle states.
struct GlassChip: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color? = nil
    var isInteractive: Bool = true

    var body: some View {
        Label {
            Text(title)
        } icon: {
            if let systemImage {
                Image(systemName: systemImage)
            }
        }
        .labelStyle(.titleAndIcon)
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, DesignSystem.Spacing.m)
        .padding(.vertical, DesignSystem.Spacing.s)
        .compatGlass(.capsule, tint: tint, interactive: isInteractive)
    }
}

#Preview {
    HStack(spacing: DesignSystem.Spacing.s) {
        GlassChip(title: "Recent", systemImage: "clock")
        GlassChip(title: "Favorites", systemImage: "star.fill", tint: .yellow)
        GlassChip(title: "Signed", systemImage: "signature", tint: .green)
    }
    .padding()
}
