import Foundation
import FoundationModels
import PDFKit

/// Streams an on-device translation of a `Document` into a target language
/// using `LanguageModelSession`. Falls back to `Document.ocrText` when the
/// PDF has no embedded text.
@MainActor
@Observable
final class DocumentTranslator {
    enum State {
        case idle
        case loading
        case streaming(String)
        case done(String)
        case failed(String)
    }

    /// Smaller budget than summarize because translation output can expand 30%+
    /// from the source.
    private static let textBudget = 5_000

    private(set) var state: State = .idle
    private var task: Task<Void, Never>?

    func translate(_ document: Document, to language: TranslationLanguage) {
        task?.cancel()
        state = .loading
        let title = document.title
        let text = Self.extractText(document)

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .failed("This document doesn't have extractable text.")
            return
        }
        let truncated = String(text.prefix(Self.textBudget))
        let truncationNote = text.count > Self.textBudget ? "\n\n[Document truncated for length]" : ""

        task = Task { [weak self] in
            guard let self else { return }
            let instructions = Instructions("""
                You are a precise translator. Translate the provided text into \(language.displayName). \
                Preserve paragraph breaks and lists. Do not add commentary, footnotes, or explanations.
                """)
            let session = LanguageModelSession(instructions: instructions)
            let prompt = Prompt("Title: \(title)\n\nText to translate:\n\n\(truncated)\(truncationNote)")

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

    private static func extractText(_ document: Document) -> String {
        if let pdf = PDFDocument(url: document.fileURL),
           let body = pdf.string,
           !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return body
        }
        return document.ocrText ?? ""
    }
}

enum TranslationLanguage: String, CaseIterable, Identifiable {
    case spanish, french, german, italian, portuguese
    case chinese, japanese, korean
    case hindi, arabic, russian

    var id: Self { self }
    var displayName: String {
        switch self {
        case .spanish: "Spanish"
        case .french: "French"
        case .german: "German"
        case .italian: "Italian"
        case .portuguese: "Portuguese"
        case .chinese: "Chinese (Simplified)"
        case .japanese: "Japanese"
        case .korean: "Korean"
        case .hindi: "Hindi"
        case .arabic: "Arabic"
        case .russian: "Russian"
        }
    }
}
