import Foundation
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
    private static let onDeviceTextBudget = 6_000
    private static let cloudTextBudget = 150_000

    private(set) var state: State = .idle
    private var task: Task<Void, Never>?

    func summarize(_ document: Document) {
        task?.cancel()
        state = .loading
        let url = document.fileURL
        let title = document.title
        let ocrFallback = document.ocrText
        let pageCount = document.pageCount

        task = Task { [weak self] in
            guard let self else { return }
            // `PDFDocument.string` walks every page; keep it off the main thread.
            let text = await Task.detached(priority: .userInitiated) {
                Self.extractText(at: url, fallback: ocrFallback)
            }.value
            if Task.isCancelled { return }

            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                AIAnalyticsRun.unavailable(.summarize, reason: "no_text")
                self.state = .failed("This PDF doesn't contain extractable text. Try re-scanning the document.")
                return
            }

            let generator: any AIGenerator
            do {
                generator = try AIEngine.resolve()
            } catch {
                AIAnalyticsRun.unavailable(.summarize, error: error)
                self.state = .failed(AIError.from(error).userMessage)
                return
            }
            let budget = generator.textBudget(onDevice: Self.onDeviceTextBudget, cloud: Self.cloudTextBudget)
            let analytics = AIAnalyticsRun(.summarize, backend: generator.backend, [.pageBucket: AppAnalytics.pageBucket(pageCount)])

            do {
                try await self.run(generator: generator, title: title, text: text, budget: budget)
                self.report(analytics)
            } catch is CancellationError {
                analytics.cancelled()
                return
            } catch let error as AIError {
                if Task.isCancelled { analytics.cancelled(); return }
                // Dense scripts (CJK, Arabic) can blow the token budget at
                // 6k characters; retry once with half the text.
                if case .contextTooLong = error {
                    do {
                        try await self.run(generator: generator, title: title, text: text, budget: budget / 2)
                        self.report(analytics)
                        return
                    } catch {
                        if Task.isCancelled { analytics.cancelled(); return }
                        analytics.failed(error)
                        self.state = .failed(Self.message(for: error))
                        return
                    }
                }
                analytics.failed(error)
                self.state = .failed(Self.message(for: error))
            } catch {
                if Task.isCancelled { analytics.cancelled(); return }
                analytics.failed(error)
                self.state = .failed(Self.message(for: error))
            }
        }
    }

    private func run(generator: any AIGenerator, title: String, text: String, budget: Int) async throws {
        let truncated = String(text.prefix(budget))
        let truncationNote = text.count > budget ? "\n\n[Document truncated for length]" : ""

        let instructions = """
            You are a precise document summarizer. Produce a concise summary in 3 to 5 sentences, \
            followed by 4 bullet points covering the most important takeaways. Use plain prose. \
            Do not invent facts; only summarize what's in the document.
            """

        let prompt = "Title: \(title)\n\nDocument text:\n\n\(truncated)\(truncationNote)"

        var accumulated = ""
        for try await partial in generator.stream(instructions: instructions, prompt: prompt) {
            if Task.isCancelled { return }
            accumulated = partial
            state = .streaming(accumulated)
        }
        if Task.isCancelled { return }
        state = .done(accumulated)
    }

    private func report(_ analytics: AIAnalyticsRun) {
        if case .done(let text) = state {
            analytics.succeeded(outputChars: text.count)
        } else {
            analytics.cancelled()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }

    private static func message(for error: Error) -> String {
        let ai = AIError.from(error)
        switch ai {
        case .contextTooLong:
            return "This document is too long to summarize. Try a shorter PDF."
        case .refused:
            return "The model declined to summarize this document."
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
