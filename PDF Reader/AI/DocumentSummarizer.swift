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
            // `PDFDocument.string` walks every page; keep it off the main thread.
            let text = await Task.detached(priority: .userInitiated) {
                Self.extractText(at: url, fallback: ocrFallback)
            }.value
            if Task.isCancelled { return }

            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.state = .failed("This PDF doesn't contain extractable text. Try re-scanning the document.")
                return
            }

            do {
                try await self.run(title: title, text: text, budget: Self.textBudget)
            } catch is CancellationError {
                return
            } catch let error as LanguageModelSession.GenerationError {
                if Task.isCancelled { return }
                // Dense scripts (CJK, Arabic) can blow the token budget at
                // 6k characters; retry once with half the text.
                if case .exceededContextWindowSize = error {
                    do {
                        try await self.run(title: title, text: text, budget: Self.textBudget / 2)
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

    private func run(title: String, text: String, budget: Int) async throws {
        let truncated = String(text.prefix(budget))
        let truncationNote = text.count > budget ? "\n\n[Document truncated for length]" : ""

        let instructions = Instructions("""
            You are a precise document summarizer. Produce a concise summary in 3–5 sentences, \
            followed by 4 bullet points covering the most important takeaways. Use plain prose. \
            Do not invent facts; only summarize what's in the document.
            """)

        let session = LanguageModelSession(instructions: instructions)
        let prompt = Prompt("Title: \(title)\n\nDocument text:\n\n\(truncated)\(truncationNote)")

        var accumulated = ""
        for try await partial in session.streamResponse(to: prompt) {
            if Task.isCancelled { return }
            accumulated = partial.content
            state = .streaming(accumulated)
        }
        if Task.isCancelled { return }
        state = .done(accumulated)
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }

    private static func message(for error: Error) -> String {
        if let gen = error as? LanguageModelSession.GenerationError {
            switch gen {
            case .exceededContextWindowSize:
                return "This document is too long for on-device summarization. Try a shorter PDF."
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
            case .refusal:
                return "The model declined to summarize this document."
            default:
                return gen.localizedDescription
            }
        }
        return error.localizedDescription
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
