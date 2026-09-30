import Foundation

/// Which family of Pro functionality a gated action belongs to. Each has
/// its own small daily allowance for free users.
enum ProFeature: String, CaseIterable {
    case aiAction
    case tool
    case editing
    case signing

    var dailyAllowance: Int {
        switch self {
        case .aiAction: 3
        case .tool: 2
        case .editing: 3
        case .signing: 1
        }
    }

    var displayName: String {
        switch self {
        case .aiAction: "AI actions"
        case .tool: "Pro tools"
        case .editing: "editing actions"
        case .signing: "signatures"
        }
    }
}

/// Metered free tier: instead of hard-locking Pro features, free users get
/// a few uses per day. People who have felt the value convert at a higher
/// rate than people who only saw a lock icon. Counters live in
/// UserDefaults keyed by day, so they reset at local midnight.
///
/// Turn the whole mechanism off with `isEnabled = false` to go back to
/// strict gating without touching call sites.
@MainActor
enum FreeTier {
    static let isEnabled = true

    /// Set when an action was blocked, read by the paywall to explain why.
    static var lastBlocked: ProFeature?

    static func remaining(_ feature: ProFeature) -> Int {
        guard isEnabled else { return 0 }
        return max(0, feature.dailyAllowance - used(feature))
    }

    /// Consumes one use if any remain. Returns whether the action may run.
    @discardableResult
    static func consume(_ feature: ProFeature) -> Bool {
        guard isEnabled, remaining(feature) > 0 else { return false }
        UserDefaults.standard.set(used(feature) + 1, forKey: key(feature))
        return true
    }

    /// Text for the paywall after a block, e.g. "You've used today's 3 free AI actions."
    static var paywallMessage: String? {
        guard let feature = lastBlocked else { return nil }
        return "You've used today's \(feature.dailyAllowance) free \(feature.displayName). Pro removes the limits."
    }

    /// Label suffix for menu rows: "(2 free today)" or "(Pro)".
    static func suffix(for feature: ProFeature) -> String {
        let left = remaining(feature)
        return left > 0 ? "(\(left) free today)" : "(Pro)"
    }

    private static func used(_ feature: ProFeature) -> Int {
        UserDefaults.standard.integer(forKey: key(feature))
    }

    private static func key(_ feature: ProFeature) -> String {
        "freeTier.\(feature.rawValue).\(dayStamp)"
    }

    private static var dayStamp: String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }
}
