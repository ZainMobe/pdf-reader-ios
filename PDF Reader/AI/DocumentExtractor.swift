import Foundation
import PDFKit

/// Structured data extracted from a document. Plain `Codable` so it compiles on
/// the iOS 17 deployment target; the on-device path generates
/// `OnDeviceExtractedData` and converts into this type.
nonisolated struct ExtractedData: Equatable, AIStructured {
    let subject: String

    let dates: [String]

    let entities: [String]

    let amounts: [String]

    let keyPoints: [String]

    static var jsonSchema: [String: Any] {
        func strings(_ description: String) -> [String: Any] {
            ["type": "array", "items": ["type": "string"], "description": description]
        }
        return [
            "type": "object",
            "properties": [
                "subject": ["type": "string", "description": "Best guess at the document's main subject or title"],
                "dates": strings("Important dates explicitly mentioned (deadlines, events, signing dates)"),
                "entities": strings("People or organizations mentioned by name"),
                "amounts": strings("Monetary amounts mentioned, with currency where stated"),
                "keyPoints": strings("Action items, decisions, or key takeaways from the document"),
            ],
            "required": ["subject", "dates", "entities", "amounts", "keyPoints"],
        ]
    }
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
    private static let cloudTextBudget = 120_000

    private(set) var state: State = .idle
    private var task: Task<Void, Never>?
    private var activeRun: AIAnalyticsRun?

    func extract(_ document: Document) {
        task?.cancel()
        activeRun?.cancelled()
        activeRun = nil
        state = .loading
        let pageCount = document.pageCount
        let title = document.title
        let url = document.fileURL
        let fallback = document.ocrText

        task = Task { [weak self] in
            guard let self else { return }
            // Full-document text extraction off the main thread.
            let text = await Task.detached(priority: .userInitiated) {
                Self.extractText(at: url, fallback: fallback)
            }.value
            if Task.isCancelled { return }

            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                AIAnalyticsRun.unavailable(.extract, reason: "no_text")
                self.state = .failed("This document doesn't have extractable text.")
                return
            }
            let generator: any AIGenerator
            do {
                generator = try AIEngine.resolve()
            } catch {
                AIAnalyticsRun.unavailable(.extract, error: error)
                self.state = .failed(AIError.from(error).userMessage)
                return
            }
            self.activeRun = AIAnalyticsRun(.extract, backend: generator.backend, [.pageBucket: AppAnalytics.pageBucket(pageCount)])
            let primaryBudget = generator.textBudget(onDevice: Self.primaryTextBudget, cloud: Self.cloudTextBudget)
            let fallbackBudget = generator.textBudget(onDevice: Self.fallbackTextBudget, cloud: Self.cloudTextBudget / 2)
            do {
                let data = try await Self.runExtraction(
                    generator: generator,
                    title: title,
                    text: text,
                    budget: primaryBudget
                )
                if Task.isCancelled { return }
                self.state = .done(data)
                self.completeRun(nil)
            } catch is CancellationError {
                return
            } catch let error as AIError {
                if Task.isCancelled { return }
                // Context-window overflow is recoverable: retry with a
                // smaller text budget in a fresh session.
                if case .contextTooLong = error {
                    do {
                        let data = try await Self.runExtraction(
                            generator: generator,
                            title: title,
                            text: text,
                            budget: fallbackBudget
                        )
                        if Task.isCancelled { return }
                        self.state = .done(data)
                        self.completeRun(nil)
                        return
                    } catch {
                        if Task.isCancelled { return }
                        self.completeRun(error)
                        self.state = .failed(Self.message(for: error))
                        return
                    }
                }
                self.completeRun(error)
                self.state = .failed(Self.message(for: error))
            } catch {
                if Task.isCancelled { return }
                self.completeRun(error)
                self.state = .failed(Self.message(for: error))
            }
        }
    }

    private func completeRun(_ error: Error?) {
        if let error {
            activeRun?.failed(error)
        } else {
            activeRun?.succeeded()
        }
        activeRun = nil
    }

    func cancel() {
        task?.cancel()
        task = nil
        activeRun?.cancelled()
        activeRun = nil
        state = .idle
    }

    private static func runExtraction(
        generator: any AIGenerator,
        title: String,
        text: String,
        budget: Int
    ) async throws -> ExtractedData {
        let truncated = String(text.prefix(budget))
        // Short, imperative instructions per Apple's token-saving guidance.
        let instructions = """
            Extract structured data from the document. Only include items \
            explicitly mentioned. Use empty arrays when nothing applies.
            """
        let prompt = """
            Title: \(title)

            Content:
            \(truncated)
            """
        return try await generator.respond(
            instructions: instructions,
            prompt: prompt,
            generating: ExtractedData.self
        )
    }

    private static func message(for error: Error) -> String {
        let ai = AIError.from(error)
        switch ai {
        case .contextTooLong:
            return "This document is too long for extraction. Try a shorter PDF."
        case .refused:
            return "The model declined to extract data from this document."
        default:
            return ai.userMessage
        }
    }

    nonisolated private static func extractText(at url: URL, fallback: String?) -> String {
        if let pdf = PDFDocument.opened(at: url),
           let body = pdf.string,
           !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return body
        }
        return fallback ?? ""
    }
}
