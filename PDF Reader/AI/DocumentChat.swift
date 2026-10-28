import Foundation
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
    private var session: (any AIChatSession)?
    private var unavailable: AIError?
    private var task: Task<Void, Never>?
    private var activeRun: AIAnalyticsRun?

    private static let onDeviceDocumentBudget = 6_000
    private static let cloudDocumentBudget = 120_000

    var backend: AIBackend? { session?.backend }

    /// Builds the chat from already-extracted text. Returns nil when the
    /// document has no usable text. Use `extractText(_:)` off the main
    /// thread to obtain `documentText`.
    init?(document: Document, documentText: String) {
        guard !documentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let generator: (any AIGenerator)?
        do {
            generator = try AIEngine.resolve()
        } catch {
            generator = nil
            unavailable = AIError.from(error)
            AIAnalyticsRun.unavailable(.chat, error: error)
        }
        let budget = generator?.textBudget(onDevice: Self.onDeviceDocumentBudget, cloud: Self.cloudDocumentBudget)
            ?? Self.onDeviceDocumentBudget
        let truncated = String(documentText.prefix(budget))
        let suffix = documentText.count > budget ? "\n\n[Truncated]" : ""

        let instructions = """
            You are a precise assistant answering questions about a PDF document.
            Use ONLY the document content below. If something isn't answerable from \
            the document, say so plainly — don't invent facts. Keep answers concise \
            unless the user asks for detail.

            Document title: \(document.title)

            Document content:
            \(truncated)\(suffix)
            """

        self.session = generator?.makeChat(instructions: instructions)
    }

    /// Sends a user message and streams the assistant's response.
    func send(_ text: String, suggested: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if session == nil {
            status = .error((unavailable ?? .notConfigured).userMessage)
            return
        }
        activeRun?.cancelled()
        let userTurns = messages.filter { $0.role == .user }.count + 1
        activeRun = AIAnalyticsRun(.chat, backend: session?.backend, [
            .messageIndex: userTurns,
            .suggested: suggested,
            .queryLength: AppAnalytics.countBucket(trimmed.count),
        ])
        messages.append(Message(role: .user, text: trimmed))
        let assistant = Message(role: .assistant, text: "", isStreaming: true)
        messages.append(assistant)
        let assistantID = assistant.id

        status = .sending
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            await self.stream(prompt: trimmed, into: assistantID, allowRetry: true)
        }
    }

    private func stream(prompt: String, into assistantID: UUID, allowRetry: Bool) async {
        guard let session else { return }
        do {
            var accumulated = ""
            for try await partial in session.stream(prompt) {
                if Task.isCancelled { return }
                accumulated = partial
                updateMessage(id: assistantID) { $0.text = accumulated }
            }
            if Task.isCancelled { return }
            updateMessage(id: assistantID) { $0.isStreaming = false }
            status = .idle
            activeRun?.succeeded(outputChars: accumulated.count)
            activeRun = nil
        } catch is CancellationError {
            return
        } catch let error as AIError {
            if Task.isCancelled { return }
            if case .contextTooLong = error, allowRetry {
                // The transcript outgrew the context window. Start a fresh
                // session seeded with the document again (older turns are
                // dropped) and retry once, so a long chat doesn't die for good.
                session.reset()
                await stream(prompt: prompt, into: assistantID, allowRetry: false)
                return
            }
            removeMessage(id: assistantID)
            status = .error(Self.message(for: error))
            activeRun?.failed(error)
            activeRun = nil
        } catch {
            if Task.isCancelled { return }
            removeMessage(id: assistantID)
            status = .error(error.localizedDescription)
            activeRun?.failed(error)
            activeRun = nil
        }
    }

    func clearError() {
        if case .error = status { status = .idle }
    }

    /// Stops the in-flight reply. Leaves whatever streamed so far in place
    /// (or removes the empty bubble) and returns the composer to idle;
    /// otherwise the Stop button, disabled composer and blinking cursor
    /// stayed stuck until "New Conversation".
    func cancel() {
        task?.cancel()
        task = nil
        activeRun?.cancelled()
        activeRun = nil
        if let index = messages.lastIndex(where: { $0.isStreaming }) {
            if messages[index].text.isEmpty {
                messages.remove(at: index)
            } else {
                messages[index].isStreaming = false
            }
        }
        if status == .sending { status = .idle }
    }

    private func updateMessage(id: UUID, transform: (inout Message) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        transform(&messages[index])
    }

    private func removeMessage(id: UUID) {
        messages.removeAll { $0.id == id }
    }

    private static func message(for error: AIError) -> String {
        switch error {
        case .contextTooLong:
            return "This conversation is too long for the AI model. Start a new conversation to continue."
        case .refused:
            return "The model declined to answer that question."
        default:
            return error.userMessage
        }
    }

    /// Full-document text extraction. Call off the main thread; `PDFDocument.string`
    /// walks every page and takes seconds on long PDFs.
    nonisolated static func extractText(at url: URL, fallback: String?) -> String {
        if let pdf = PDFDocument.opened(at: url),
           let body = pdf.string,
           !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return body
        }
        return fallback ?? ""
    }
}
