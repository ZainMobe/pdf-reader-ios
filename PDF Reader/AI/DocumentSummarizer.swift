import Foundation
import FoundationModels
import PDFKit

/// Streams an on-device summary of a `Document` using the Foundation Models framework.
///
/// Source-of-truth for the summary is the PDF's embedded text via PDFKit.
/// When that's empty (typical for image-only scans), falls back to the
/// `ocrText` we captured at scan time so AI features work end-to-end on
/// scanned documents.
@MainActor
@Observable
final class DocumentSummarizer {
    enum State {
        case idle
        case loading
        case streaming(String)
        case done(String)
        case failed(String)
    }

    /// Character cap before truncation. Chosen to stay well inside the on-device
    /// model's context window — revisit once we have multi-session chunking.
    private static let textBudget = 6_000

    private(set) var state: State = .idle
    private var task: Task<Void, Never>?

    func summarize(_ document: Document) {
        task?.cancel()
        state = .loading
        let url = document.fileURL
        let title = document.title
        let ocrFallback = document.ocrText

        task = Task { [weak self] in
            guard let self else { return }
            let text = Self.extractText(at: url, fallback: ocrFallback)

            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.state = .failed("This PDF doesn't contain extractable text. Try re-scanning the document.")
                return
            }

            let truncated = String(text.prefix(Self.textBudget))
            let truncationNote = text.count > Self.textBudget ? "\n\n[Document truncated for length]" : ""

            let instructions = Instructions("""
                You are a precise document summarizer. Produce a concise summary in 3–5 sentences, \
                followed by 4 bullet points covering the most important takeaways. Use plain prose. \
                Do not invent facts; only summarize what's in the document.
                """)

            let session = LanguageModelSession(instructions: instructions)
            let prompt = Prompt("Title: \(title)\n\nDocument text:\n\n\(truncated)\(truncationNote)")

            do {
                var accumulated = ""
                for try await partial in session.streamResponse(to: prompt) {
                    if Task.isCancelled { return }
                    accumulated = partial.content
                    self.state = .streaming(accumulated)
                }
                self.state = .done(accumulated)
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

    private static func extractText(at url: URL, fallback: String?) -> String {
        if let pdf = PDFDocument(url: url),
           let body = pdf.string,
           !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return body
        }
        return fallback ?? ""
    }
}
