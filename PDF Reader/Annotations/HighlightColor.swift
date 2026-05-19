import SwiftUI
import UIKit

/// Color choices for the Highlight markup tool. Stored in `UserDefaults`
/// under `AppSettings.highlightColor` so it persists across launches.
enum HighlightColor: String, CaseIterable, Identifiable {
    case yellow, green, pink, blue, orange

    var id: Self { self }

    var displayName: String {
        switch self {
        case .yellow: "Yellow"
        case .green: "Green"
        case .pink: "Pink"
        case .blue: "Blue"
        case .orange: "Orange"
        }
    }

    var color: Color {
        switch self {
        case .yellow: .yellow
        case .green: .green
        case .pink: .pink
        case .blue: .blue
        case .orange: .orange
        }
    }

    var uiColor: UIColor {
        switch self {
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .pink: .systemPink
        case .blue: .systemBlue
        case .orange: .systemOrange
        }
    }
}

/// Shared `UserDefaults` keys for app-wide preferences.
enum AppSettings {
    static let defaultDisplayMode = "settings.defaultDisplayMode"
    static let defaultDisplayDirection = "settings.defaultDisplayDirection"
    static let highlightColor = "settings.highlightColor"
}
