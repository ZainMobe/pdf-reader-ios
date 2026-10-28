import Foundation
import FoundationModels

@available(iOS 26.0, *)
struct OnDeviceAI: AIGenerator {
    let backend: AIBackend = .onDevice

    func respond(instructions: String, prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: Instructions(instructions))
        do {
            return try await session.respond(to: Prompt(prompt)).content
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AIError.from(error)
        }
    }

    func stream(instructions: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        let session = LanguageModelSession(instructions: Instructions(instructions))
        return Self.stream(session: session, prompt: prompt)
    }

    /// `AIStructured` cannot require `Generable` (iOS 26 only), so each supported
    /// result type is generated through its `@Generable` mirror and converted back.
    func respond<T: AIStructured>(instructions: String, prompt: String, generating: T.Type) async throws -> T {
        let session = LanguageModelSession(instructions: Instructions(instructions))
        do {
            if T.self == ExtractedData.self {
                let generated = try await session.respond(
                    to: Prompt(prompt),
                    generating: OnDeviceExtractedData.self
                ).content
                guard let result = generated.asExtractedData as? T else { throw AIError.decodingFailed }
                return result
            }
            if T.self == FormSuggestionSet.self {
                let generated = try await session.respond(
                    to: Prompt(prompt),
                    generating: OnDeviceFormSuggestionSet.self
                ).content
                guard let result = generated.asFormSuggestionSet as? T else { throw AIError.decodingFailed }
                return result
            }
            throw AIError.decodingFailed
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AIError.from(error)
        }
    }

    func makeChat(instructions: String) -> any AIChatSession {
        OnDeviceChatSession(instructions: instructions)
    }

    static func stream(session: LanguageModelSession, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await partial in session.streamResponse(to: Prompt(prompt)) {
                        try Task.checkCancellation()
                        continuation.yield(partial.content)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: AIError.from(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@available(iOS 26.0, *)
final class OnDeviceChatSession: AIChatSession, @unchecked Sendable {
    let backend: AIBackend = .onDevice
    private let instructions: Instructions
    private var session: LanguageModelSession

    init(instructions: String) {
        self.instructions = Instructions(instructions)
        self.session = LanguageModelSession(instructions: self.instructions)
    }

    func stream(_ prompt: String) -> AsyncThrowingStream<String, Error> {
        OnDeviceAI.stream(session: session, prompt: prompt)
    }

    func reset() {
        session = LanguageModelSession(instructions: instructions)
    }
}


// MARK: - Guided generation mirrors

/// `@Generable` twin of `ExtractedData`. Kept separate so `ExtractedData` itself
/// stays available on iOS 17.
@available(iOS 26.0, *)
@Generable
struct OnDeviceExtractedData {
    @Guide(description: "Best guess at the document's main subject or title")
    let subject: String

    @Guide(description: "Important dates explicitly mentioned (deadlines, events, signing dates)")
    let dates: [String]

    @Guide(description: "People or organizations mentioned by name")
    let entities: [String]

    @Guide(description: "Monetary amounts mentioned, with currency where stated")
    let amounts: [String]

    @Guide(description: "Action items, decisions, or key takeaways from the document")
    let keyPoints: [String]

    var asExtractedData: ExtractedData {
        ExtractedData(
            subject: subject,
            dates: dates,
            entities: entities,
            amounts: amounts,
            keyPoints: keyPoints
        )
    }
}

/// `@Generable` twin of `FormSuggestionSet`.
@available(iOS 26.0, *)
@Generable
struct OnDeviceFormSuggestionSet {
    @Guide(description: "Suggested values for each form field")
    let values: [OnDeviceFormFieldValue]

    var asFormSuggestionSet: FormSuggestionSet {
        FormSuggestionSet(values: values.map(\.asFormFieldValue))
    }
}

@available(iOS 26.0, *)
@Generable
struct OnDeviceFormFieldValue {
    @Guide(description: "Exact field name as provided in the prompt")
    let fieldName: String

    @Guide(description: "Suggested value, or empty string if not inferrable")
    let suggestedValue: String

    var asFormFieldValue: FormFieldValue {
        FormFieldValue(fieldName: fieldName, suggestedValue: suggestedValue)
    }
}
