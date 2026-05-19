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

    private static let textBudget = 6_000

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
        let truncated = String(text.prefix(Self.textBudget))

        task = Task { [weak self] in
            guard let self else { return }
            let instructions = Instructions("""
                Extract structured data from the provided document. Only include items \
                explicitly mentioned. Use empty arrays for fields where nothing applies. \
                Do not infer or invent.
                """)
            let session = LanguageModelSession(instructions: instructions)
            let prompt = Prompt("Document title: \(title)\n\nContent:\n\n\(truncated)")

            do {
                let response = try await session.respond(
                    to: prompt,
                    generating: ExtractedData.self
                )
                self.state = .done(response.content)
            } catch is CancellationError {
                return
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
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
