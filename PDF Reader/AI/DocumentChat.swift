import Foundation
import FoundationModels
import PDFKit

/// Multi-turn on-device chat session scoped to a single `Document`.
///
/// The session is seeded with instructions plus a truncated copy of the
/// document text (PDF body, falling back to `ocrText`). Each user message is
/// streamed via `streamResponse(to:)`; partial snapshots update the active
/// assistant message so the UI sees the response build up live.
@MainActor
@Observable
final class DocumentChat {
    enum Status: Equatable {
        case idle
        case sending
        case error(String)
    }

    struct Message: Identifiable, Equatable {
        let id = UUID()
        let role: Role
        var text: String
        var isStreaming: Bool = false

        enum Role: Equatable { case user, assistant }
    }

    private(set) var messages: [Message] = []
    private(set) var status: Status = .idle
    private let session: LanguageModelSession
    private var task: Task<Void, Never>?

    private static let documentBudget = 6_000

    init?(document: Document) {
        let documentText = Self.extractText(document)
        guard !documentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let truncated = String(documentText.prefix(Self.documentBudget))
        let suffix = documentText.count > Self.documentBudget ? "\n\n[Truncated]" : ""

        let instructions = Instructions("""
            You are a precise assistant answering questions about a PDF document.
            Use ONLY the document content below. If something isn't answerable from \
            the document, say so plainly — don't invent facts. Keep answers concise \
            unless the user asks for detail.

            Document title: \(document.title)

            Document content:
            \(truncated)\(suffix)
            """)

        self.session = LanguageModelSession(instructions: instructions)
    }

    /// Sends a user message and streams the assistant's response.
    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        messages.append(Message(role: .user, text: trimmed))
        let assistant = Message(role: .assistant, text: "", isStreaming: true)
        messages.append(assistant)
        let assistantID = assistant.id

        status = .sending
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                var accumulated = ""
                for try await partial in self.session.streamResponse(to: Prompt(trimmed)) {
                    if Task.isCancelled { return }
                    accumulated = partial.content
                    self.updateMessage(id: assistantID) { $0.text = accumulated }
                }
                self.updateMessage(id: assistantID) { $0.isStreaming = false }
                self.status = .idle
            } catch is CancellationError {
                return
            } catch {
                self.removeMessage(id: assistantID)
                self.status = .error(error.localizedDescription)
            }
        }
    }

    func clearError() {
        if case .error = status { status = .idle }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func updateMessage(id: UUID, transform: (inout Message) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        transform(&messages[index])
    }

    private func removeMessage(id: UUID) {
        messages.removeAll { $0.id == id }
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
