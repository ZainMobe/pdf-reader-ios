import SwiftUI

/// Shape used by the glass compatibility modifiers.
/// Kept free of any iOS 26 type so it compiles on the iOS 17 deployment target.
enum GlassCompatShape {
    case capsule
    case rect(CGFloat)

    var anyShape: AnyShape {
        switch self {
        case .capsule:
            return AnyShape(Capsule())
        case .rect(let radius):
            return AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}

extension View {
    /// Liquid Glass on iOS 26 and newer, a material surface below it.
    ///
    /// Replaces direct `glassEffect(_:in:)` calls, which are iOS 26 only and so
    /// cannot appear unguarded now that the app deploys to iOS 17.
    @ViewBuilder
    func compatGlass(
        _ shape: GlassCompatShape = .rect(DesignSystem.Radius.medium),
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(Glass.compat(tint: tint, interactive: interactive), in: shape.anyShape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape.anyShape)
                .overlay {
                    if let tint {
                        shape.anyShape.fill(tint.opacity(0.18))
                    }
                }
                .overlay {
                    shape.anyShape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
                .clipShape(shape.anyShape)
        }
    }

    /// Glass button styling on iOS 26 and newer, bordered styles below it.
    @ViewBuilder
    func compatGlassButtonStyle(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            if prominent {
                self.buttonStyle(.borderedProminent)
            } else {
                self.buttonStyle(.bordered)
            }
        }
    }
}

@available(iOS 26.0, *)
extension Glass {
    /// Builds a `Glass` from the compat modifier's plain parameters.
    static func compat(tint: Color?, interactive: Bool) -> Glass {
        var glass: Glass = .regular
        if let tint {
            glass = glass.tint(tint)
        }
        if interactive {
            glass = glass.interactive()
        }
        return glass
    }
}
