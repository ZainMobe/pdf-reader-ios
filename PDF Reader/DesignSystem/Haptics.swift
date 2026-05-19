import UIKit

/// Centralised tactile feedback. Modern declarative views should prefer
/// SwiftUI's `.sensoryFeedback(_:trigger:)` modifier; this helper exists
/// for the imperative paths (button closures, async result handlers, etc.)
/// where there's no clean state value to bind a trigger to.
@MainActor
enum Haptics {
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
