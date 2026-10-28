import Foundation
import FirebaseCore
import FirebaseAnalytics

enum AppAnalytics {
    private static let enabledKey = "settings.analyticsEnabled"
    private(set) static var isConfigured = false

    static func configure() {
        guard !isConfigured else { return }
        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else {
            #if DEBUG
            print("[Analytics] GoogleService-Info.plist not found. Firebase Analytics is disabled for this build.")
            #endif
            return
        }
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        Analytics.setConsent([
            .analyticsStorage: .granted,
            .adStorage: .denied,
            .adUserData: .denied,
            .adPersonalization: .denied,
        ])
        Analytics.setAnalyticsCollectionEnabled(isCollectionEnabled)
        isConfigured = true
    }

    static var isCollectionEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            guard isConfigured else { return }
            Analytics.setAnalyticsCollectionEnabled(newValue)
        }
    }

    static func log(_ event: AnalyticsEvent, _ params: [AnalyticsParam: Any?] = [:]) {
        guard isConfigured else { return }
        var clean: [String: Any] = [:]
        for (key, value) in params {
            guard let value else { continue }
            switch value {
            case let string as String:
                clean[key.rawValue] = String(string.prefix(100))
            case let bool as Bool:
                clean[key.rawValue] = bool ? 1 : 0
            case let int as Int:
                clean[key.rawValue] = int
            case let int64 as Int64:
                clean[key.rawValue] = int64
            case let double as Double:
                clean[key.rawValue] = (double * 100).rounded() / 100
            default:
                clean[key.rawValue] = String(String(describing: value).prefix(100))
            }
        }
        Analytics.logEvent(event.rawValue, parameters: clean.isEmpty ? nil : clean)
        #if DEBUG
        let summary = clean.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("[Analytics] \(event.rawValue) \(summary)")
        #endif
    }

    static func feature(_ feature: AnalyticsFeature, source: String? = nil, _ extra: [AnalyticsParam: Any?] = [:]) {
        var params = extra
        params[.feature] = feature.rawValue
        params[.category] = feature.category.rawValue
        if let source { params[.source] = source }
        log(.featureUsed, params)
    }

    static func screen(_ screen: AnalyticsScreen) {
        guard isConfigured else { return }
        Analytics.logEvent(AnalyticsEventScreenView, parameters: [
            AnalyticsParameterScreenName: screen.rawValue,
            AnalyticsParameterScreenClass: screen.screenClass,
        ])
        #if DEBUG
        print("[Analytics] screen_view \(screen.rawValue)")
        #endif
    }

    static func setUserProperty(_ property: AnalyticsUserProperty, _ value: String?) {
        guard isConfigured else { return }
        Analytics.setUserProperty(value.map { String($0.prefix(36)) }, forName: property.rawValue)
    }

    static func pageBucket(_ count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        switch count {
        case 1: return "1"
        case 2...5: return "2-5"
        case 6...20: return "6-20"
        case 21...50: return "21-50"
        case 51...200: return "51-200"
        default: return "200+"
        }
    }

    static func countBucket(_ count: Int) -> String {
        switch count {
        case ..<1: return "0"
        case 1: return "1"
        case 2...5: return "2-5"
        case 6...20: return "6-20"
        case 21...50: return "21-50"
        case 51...100: return "51-100"
        default: return "100+"
        }
    }

    static func sizeBucket(bytes: Int64?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        let mb = Double(bytes) / 1_048_576
        switch mb {
        case ..<1: return "<1MB"
        case ..<5: return "1-5MB"
        case ..<20: return "5-20MB"
        case ..<100: return "20-100MB"
        default: return "100MB+"
        }
    }

    static func milliseconds(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1000))
    }

    static func seconds(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start).rounded()))
    }

    static func errorLabel(_ error: Error) -> String {
        if let ai = error as? AIError { return "ai.\(ai.analyticsLabel)" }
        let ns = error as NSError
        let domain = ns.domain
            .replacingOccurrences(of: "NSCocoaErrorDomain", with: "cocoa")
            .replacingOccurrences(of: "NSURLErrorDomain", with: "url")
        return "\(domain).\(ns.code)"
    }
}

extension AppAnalytics {
    static func toolOpened(_ tool: AnalyticsTool, source: AnalyticsSource) {
        log(.toolOpened, [.tool: tool.rawValue, .source: source.rawValue])
    }

    static func toolCompleted(
        _ tool: AnalyticsTool,
        startedAt: Date? = nil,
        pageCount: Int? = nil,
        fileCount: Int? = nil,
        _ extra: [AnalyticsParam: Any?] = [:]
    ) {
        var params = extra
        params[.tool] = tool.rawValue
        params[.pageBucket] = pageBucket(pageCount)
        params[.fileCount] = fileCount
        if let startedAt { params[.durationMs] = milliseconds(since: startedAt) }
        log(.toolCompleted, params)
        feature(tool.feature)
    }

    static func toolFailed(_ tool: AnalyticsTool, error: Error) {
        log(.toolFailed, [.tool: tool.rawValue, .errorType: errorLabel(error)])
    }

    static func annotation(_ type: AnalyticsAnnotation, source: AnalyticsSource = .reader, _ extra: [AnalyticsParam: Any?] = [:]) {
        var params = extra
        params[.annotationType] = type.rawValue
        params[.source] = source.rawValue
        log(.annotationAdded, params)
        feature(type.feature, source: source.rawValue)
    }

    static func readerAction(_ action: AnalyticsFeature, _ extra: [AnalyticsParam: Any?] = [:]) {
        var params = extra
        params[.action] = action.rawValue
        log(.readerAction, params)
        feature(action, source: AnalyticsSource.reader.rawValue)
    }

    static func libraryAction(_ action: AnalyticsFeature, _ extra: [AnalyticsParam: Any?] = [:]) {
        var params = extra
        params[.action] = action.rawValue
        log(.libraryAction, params)
        feature(action, source: AnalyticsSource.library.rawValue)
    }

    static func settingChanged(_ setting: String, _ value: String) {
        log(.settingChanged, [.setting: setting, .value: value])
    }
}

struct AIAnalyticsRun {
    let action: AnalyticsAIAction
    let backend: AIBackend?
    let start = Date()

    init(_ action: AnalyticsAIAction, backend: AIBackend?, _ extra: [AnalyticsParam: Any?] = [:]) {
        self.action = action
        self.backend = backend
        var params = extra
        params[.aiAction] = action.rawValue
        params[.aiBackend] = backend?.rawValue ?? "none"
        AppAnalytics.log(.aiStarted, params)
    }

    func succeeded(outputChars: Int? = nil, _ extra: [AnalyticsParam: Any?] = [:]) {
        var params = extra
        params[.aiAction] = action.rawValue
        params[.aiBackend] = backend?.rawValue ?? "none"
        params[.durationMs] = AppAnalytics.milliseconds(since: start)
        if let outputChars { params[.outputSize] = AppAnalytics.countBucket(outputChars / 100) }
        AppAnalytics.log(.aiCompleted, params)
        AppAnalytics.feature(action.feature, [.aiBackend: backend?.rawValue ?? "none"])
    }

    func failed(_ error: Error) {
        AppAnalytics.log(.aiFailed, [
            .aiAction: action.rawValue,
            .aiBackend: backend?.rawValue ?? "none",
            .errorType: AppAnalytics.errorLabel(error),
            .durationMs: AppAnalytics.milliseconds(since: start),
        ])
    }

    func cancelled() {
        AppAnalytics.log(.aiCancelled, [
            .aiAction: action.rawValue,
            .aiBackend: backend?.rawValue ?? "none",
            .durationMs: AppAnalytics.milliseconds(since: start),
        ])
    }

    static func unavailable(_ action: AnalyticsAIAction, error: Error) {
        AppAnalytics.log(.aiUnavailable, [.aiAction: action.rawValue, .errorType: AppAnalytics.errorLabel(error)])
    }

    static func unavailable(_ action: AnalyticsAIAction, reason: String) {
        AppAnalytics.log(.aiUnavailable, [.aiAction: action.rawValue, .errorType: reason])
    }
}

extension AIError {
    var analyticsLabel: String {
        switch self {
        case .contextTooLong: "context_too_long"
        case .blocked: "blocked"
        case .unsupportedLanguage: "unsupported_language"
        case .assetsUnavailable: "assets_unavailable"
        case .busy: "busy"
        case .refused: "refused"
        case .decodingFailed: "decoding_failed"
        case .notConfigured: "not_configured"
        case .consentRequired: "consent_required"
        case .offline: "offline"
        case .network: "network"
        case .server(let status, _): "server_\(status)"
        case .other: "other"
        }
    }
}
