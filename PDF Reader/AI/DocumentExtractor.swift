import Foundation
import FoundationModels
import PDFKit

/// Structured data the on-device model extracts from a document. Each field
/// uses `@Guide` to steer the model's interpretation.
@Generable
struct ExtractedData: Equatable {
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
}

/// One-shot structured extraction using Foundation Models' guided generation.
/// Unlike streaming summarization, this returns a typed `ExtractedData`
/// instance via `session.respond(to:generating:)`.
@MainActor
@Observable
final class DocumentExtractor {
    enum State {
        case idle
        case loading
        case done(ExtractedData)
        case failed(String)
    }

    /// Structured generation pays a sizeable token cost for the JSON schema
    /// itself, plus the model's output array fields. The system model's
    /// 4,096-token context window leaves room for roughly 3.5k characters
    /// of document content once the schema, instructions, and reply are
    /// accounted for. The retry path drops this further on overflow.
    private static let primaryTextBudget = 3_500
    private static let fallbackTextBudget = 1_800

    private(set) var state: State = .idle
    private var task: Task<Void, Never>?

    func extract(_ document: Document) {
        task?.cancel()
        state = .loading
        let title = document.title
        let text = Self.extractText(document)

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .failed("This document doesn't have extractable text.")
            return
        }

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await Self.runExtraction(
                    title: title,
                    text: text,
                    budget: Self.primaryTextBudget
                )
                if Task.isCancelled { return }
                self.state = .done(data)
            } catch is CancellationError {
                return
            } catch let error as LanguageModelSession.GenerationError {
                if Task.isCancelled { return }
                // Context-window overflow is recoverable: retry with a
                // smaller text budget in a fresh session.
                if case .exceededContextWindowSize = error {
                    do {
                        let data = try await Self.runExtraction(
                            title: title,
                            text: text,
                            budget: Self.fallbackTextBudget
                        )
                        if Task.isCancelled { return }
                        self.state = .done(data)
                        return
                    } catch {
                        if Task.isCancelled { return }
                        self.state = .failed(Self.message(for: error))
                        return
                    }
                }
                self.state = .failed(Self.message(for: error))
            } catch {
                if Task.isCancelled { return }
                self.state = .failed(Self.message(for: error))
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }

    private static func runExtraction(
        title: String,
        text: String,
        budget: Int
    ) async throws -> ExtractedData {
        let truncated = String(text.prefix(budget))
        // Short, imperative instructions per Apple's token-saving guidance.
        let instructions = Instructions("""
            Extract structured data from the document. Only include items \
            explicitly mentioned. Use empty arrays when nothing applies.
            """)
        let session = LanguageModelSession(instructions: instructions)
        let prompt = Prompt("""
            Title: \(title)

            Content:
            \(truncated)
            """)
        let response = try await session.respond(
            to: prompt,
            generating: ExtractedData.self
        )
        return response.content
    }

    private static func message(for error: Error) -> String {
        if let gen = error as? LanguageModelSession.GenerationError {
            switch gen {
            case .exceededContextWindowSize:
                return "This document is too long for on-device extraction. Try a shorter PDF."
            case .decodingFailure:
                return "The model couldn't produce structured results for this document."
            case .guardrailViolation:
                return "This document's content was blocked by on-device safety filters."
            case .unsupportedLanguageOrLocale:
                return "The on-device model doesn't support the language used in this document."
            case .assetsUnavailable:
                return "Apple Intelligence assets aren't ready yet. Try again in a few minutes."
            case .rateLimited:
                return "Too many AI requests right now. Please try again shortly."
            case .concurrentRequests:
                return "Another AI request is in progress. Try again in a moment."
            case .unsupportedGuide:
                return "Extraction isn't supported in this configuration."
            case .refusal:
                return "The model declined to extract data from this document."
            @unknown default:
                return gen.localizedDescription
            }
        }
        return error.localizedDescription
    }

    private static func extractText(_ document: Document) -> String {
        if let pdf = PDFDocument(url: document.fileURL),
           let body = pdf.string,
           !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return body
        }
        return document.ocrText ?? ""
    }
}
