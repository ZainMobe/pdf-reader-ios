import Foundation
import FoundationModels

/// Mirror of `SystemLanguageModel.Availability.UnavailableReason` that is safe to
/// name on the iOS 17 deployment target, plus `osTooOld` for pre-iOS 26 systems.
enum OnDeviceUnavailableReason: Equatable, Sendable {
    case osTooOld
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unknown
}

enum AIBackend: String, Sendable {
    case onDevice
    case cloud

    var displayName: String {
        switch self {
        case .onDevice: return "On-device"
        case .cloud: return "Cloud"
        }
    }
}

enum AIProcessingMode: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case onDeviceOnly
    case cloudOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .onDeviceOnly: return "On-device only"
        case .cloudOnly: return "Cloud"
        }
    }
}

enum AIError: Error, Equatable {
    case contextTooLong
    case blocked
    case unsupportedLanguage
    case assetsUnavailable
    case busy
    case refused
    case decodingFailed
    case notConfigured
    case consentRequired
    case offline
    case network(String)
    case server(status: Int, message: String)
    case other(String)

    var userMessage: String {
        switch self {
        case .contextTooLong:
            return "This content is too long for the AI model. Try a shorter document or a more specific question."
        case .blocked:
            return "This content was blocked by the model's safety filters."
        case .unsupportedLanguage:
            return "The on-device model doesn't support this language. Switch AI processing to Cloud in Settings to use it."
        case .assetsUnavailable:
            return "Apple Intelligence assets aren't ready yet. Try again in a few minutes."
        case .busy:
            return "The AI service is busy right now. Please try again shortly."
        case .refused:
            return "The model declined this request."
        case .decodingFailed:
            return "The model couldn't produce structured results for this document."
        case .notConfigured:
            return "AI features aren't available on this device."
        case .consentRequired:
            return "Allow cloud AI processing in Settings > AI to use this feature on this device."
        case .offline:
            return "You're offline. Cloud AI needs an internet connection."
        case .network(let detail):
            return "Couldn't reach the AI service: \(detail)"
        case .server(let status, let message):
            return status == 401 || status == 403
                ? "The AI service rejected this app's key. Please update the app."
                : "The AI service returned an error (\(status)): \(message)"
        case .other(let detail):
            return detail
        }
    }

    static func from(_ error: Error) -> AIError {
        if let ai = error as? AIError { return ai }
        if #available(iOS 26.0, *), let gen = error as? LanguageModelSession.GenerationError {
            switch gen {
            case .exceededContextWindowSize: return .contextTooLong
            case .guardrailViolation: return .blocked
            case .unsupportedLanguageOrLocale: return .unsupportedLanguage
            case .assetsUnavailable: return .assetsUnavailable
            case .rateLimited, .concurrentRequests: return .busy
            case .refusal: return .refused
            case .decodingFailure: return .decodingFailed
            case .unsupportedGuide: return .other("This request isn't supported in this configuration.")
            @unknown default: return .other(gen.localizedDescription)
            }
        }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return .offline
            default:
                return .network(url.localizedDescription)
            }
        }
        return .other(error.localizedDescription)
    }
}

/// Plain structured-output contract. Deliberately free of `Generable`, which is
/// iOS 26 only: the on-device path bridges to its own `@Generable` mirror types.
protocol AIStructured: Decodable, Sendable {
    static var jsonSchema: [String: Any] { get }
}

protocol AIGenerator: Sendable {
    var backend: AIBackend { get }
    func respond(instructions: String, prompt: String) async throws -> String
    func stream(instructions: String, prompt: String) -> AsyncThrowingStream<String, Error>
    func respond<T: AIStructured>(instructions: String, prompt: String, generating: T.Type) async throws -> T
    func makeChat(instructions: String) -> any AIChatSession
}

extension AIGenerator {
    func textBudget(onDevice: Int, cloud: Int) -> Int {
        backend == .cloud ? cloud : onDevice
    }
}

protocol AIChatSession: AnyObject, Sendable {
    var backend: AIBackend { get }
    func stream(_ prompt: String) -> AsyncThrowingStream<String, Error>
    func reset()
}

enum AIEngine {
    enum Availability: Equatable {
        case ready(AIBackend)
        case needsCloudConsent
        case onDeviceUnavailable(OnDeviceUnavailableReason)
        case unavailable

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }

        var backend: AIBackend? {
            if case .ready(let backend) = self { return backend }
            return nil
        }
    }

    static var mode: AIProcessingMode {
        get {
            let raw = UserDefaults.standard.string(forKey: AppSettings.aiProcessingMode) ?? ""
            return AIProcessingMode(rawValue: raw) ?? .automatic
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: AppSettings.aiProcessingMode) }
    }

    static var hasCloudConsent: Bool {
        get { UserDefaults.standard.bool(forKey: AppSettings.cloudAIConsent) }
        set { UserDefaults.standard.set(newValue, forKey: AppSettings.cloudAIConsent) }
    }

    static var cloudAPIKey: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "ANTHROPIC_API_KEY") as? String else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.hasPrefix("$(") else { return nil }
        return key
    }

    static var isCloudConfigured: Bool { cloudAPIKey != nil }

    /// Why the on-device model cannot run, in terms that compile below iOS 26.
    static var onDeviceUnavailableReason: OnDeviceUnavailableReason? {
        guard #available(iOS 26.0, *) else { return .osTooOld }
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady):
            return .modelNotReady
        case .unavailable:
            return .unknown
        }
    }

    static var isOnDeviceAvailable: Bool {
        onDeviceUnavailableReason == nil
    }

    static func availability() -> Availability {
        let onDevice = isOnDeviceAvailable
        let cloud = isCloudConfigured

        func cloudOrConsent() -> Availability {
            hasCloudConsent ? .ready(.cloud) : .needsCloudConsent
        }

        switch mode {
        case .onDeviceOnly:
            if onDevice { return .ready(.onDevice) }
            return onDeviceFailure()
        case .cloudOnly:
            if cloud { return cloudOrConsent() }
            if onDevice { return .ready(.onDevice) }
            return onDeviceFailure()
        case .automatic:
            if onDevice { return .ready(.onDevice) }
            if cloud { return cloudOrConsent() }
            return onDeviceFailure()
        }
    }

    private static func onDeviceFailure() -> Availability {
        if let reason = onDeviceUnavailableReason {
            return .onDeviceUnavailable(reason)
        }
        return .unavailable
    }

    static func resolve() throws -> any AIGenerator {
        switch availability() {
        case .ready(.onDevice):
            guard #available(iOS 26.0, *) else { throw AIError.notConfigured }
            return OnDeviceAI()
        case .ready(.cloud):
            guard let key = cloudAPIKey else { throw AIError.notConfigured }
            return ClaudeAI(apiKey: key)
        case .needsCloudConsent:
            throw AIError.consentRequired
        case .onDeviceUnavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled:
                throw AIError.other("Turn on Apple Intelligence in Settings to use AI features.")
            case .modelNotReady:
                throw AIError.assetsUnavailable
            default:
                throw AIError.notConfigured
            }
        case .unavailable:
            throw AIError.notConfigured
        }
    }

    static var statusLine: String {
        switch availability() {
        case .ready(.onDevice):
            return "Powered by Apple Intelligence. Nothing leaves your iPhone."
        case .ready(.cloud):
            return "Powered by Claude. Document text is sent securely to Anthropic to generate results and isn't used for training."
        case .needsCloudConsent:
            return "Cloud AI is available on this device once you allow it."
        case .onDeviceUnavailable(.deviceNotEligible), .onDeviceUnavailable(.osTooOld), .unavailable:
            return "AI features aren't available on this device."
        case .onDeviceUnavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in Settings to use AI features."
        case .onDeviceUnavailable(.modelNotReady):
            return "The on-device model is downloading. Try again in a few minutes."
        case .onDeviceUnavailable:
            return "AI features are currently unavailable."
        }
    }
}
