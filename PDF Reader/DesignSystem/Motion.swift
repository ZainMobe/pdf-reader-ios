import SwiftUI

extension DesignSystem {
    /// Animation tokens shared across feature modules.
    /// Pair with `GlassEffectTransition.matchedGeometry` when morphing glass surfaces.
    enum Motion {
        static let snappy: Animation = .smooth(duration: 0.25)
        static let bouncy: Animation = .bouncy(duration: 0.4)
        static let gentle: Animation = .easeInOut(duration: 0.3)
    }
}
