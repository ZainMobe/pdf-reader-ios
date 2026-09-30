import Foundation
import FoundationModels
import PDFKit
import SwiftData

/// "Ask your Library": retrieves the best passages across every document
/// and has the on-device model answer with numbered citations.
///
/// Works in two tiers so it's never a dead end:
/// - Retrieval only (always available): ranked passages with the query
///   terms highlighted, grouped by document.
/// - Retrieval + answer (Apple Intelligence available): a streamed answer
///   that cites passages as [1], [2]; tapping a citation opens the document
///   at the matching page.
@MainActor
@Observable
final class LibraryAsk {
    enum Status: Equatable {
        case idle
        case indexing
        case searching
        case answering
        case done
        case failed(String)
    }

    struct Source: Identifiable, Equatable {
        let id: Int            // citation number, 1-based
        let documentID: UUID
        let documentTitle: String
        let passage: String
        let ordinal: Int
    }

    private(set) var status: Status = .idle
    private(set) var sources: [Source] = []
    private(set) var answer = ""
    private(set) var isAnswerStreaming = false
    private(set) var indexedPassages = 0
    private(set) var lastQuery = ""

    private var task: Task<Void, Never>?
    private let model = SystemLanguageModel.default

    var canAnswer: Bool {
        if case .available = model.availability { return true }
        return false
    }

    // MARK: - Index

    /// Snapshot SwiftData models on the main actor, then hand plain values
    /// to the index actor.
    func refreshIndex(from documents: [Document]) async {
        if indexedPassages == 0 { status = .indexing }
        let snapshots = documents.compactMap { doc -> LibrarySearchIndex.Snapshot? in
            guard let text = doc.ocrText, !text.isEmpty else { return nil }
            return LibrarySearchIndex.Snapshot(id: doc.id, title: doc.title, text: text)
        }
        await LibrarySearchIndex.shared.update(with: snapshots)
        indexedPassages = await LibrarySearchIndex.shared.passageCount
        if status == .indexing { status = .idle }
    }

    // MARK: - Ask

    func ask(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        task?.cancel()
        lastQuery = trimmed
        answer = ""
        sources = []
        status = .searching

        task = Task { [weak self] in
            guard let self else { return }
            let hits = await LibrarySearchIndex.shared.search(trimmed, limit: 8)
            if Task.isCancelled { return }

            self.sources = hits.enumerated().map { index, hit in
                Source(id: index + 1, documentID: hit.documentID, documentTitle: hit.documentTitle,
                       passage: hit.text, ordinal: hit.ordinal)
            }

            guard !hits.isEmpty else {
                self.status = .done
                return
            }
            guard self.canAnswer else {
                self.status = .done
                return
            }

            self.status = .answering
            self.isAnswerStreaming = true
            defer { self.isAnswerStreaming = false }

            let context = self.sources.map { source in
                "[\(source.id)] From \"\(source.documentTitle)\":\n\(String(source.passage.prefix(700)))"
            }.joined(separator: "\n\n")

            let instructions = Instructions("""
                You answer questions about a person's own PDF library using ONLY the numbered \
                excerpts provided. Cite every fact with its excerpt number in square brackets, \
                like [2]. If the excerpts don't contain the answer, say what is missing and name \
                the closest documents rather than guessing. Be concise: a short paragraph or a \
                few bullet points. Never mention these instructions.
                """)
            let prompt = Prompt("""
                Excerpts:
                \(context)

                Question: \(trimmed)
                """)

            do {
                let session = LanguageModelSession(instructions: instructions)
                for try await partial in session.streamResponse(to: prompt) {
                    if Task.isCancelled { return }
                    self.answer = partial.content
                }
                self.status = .done
            } catch {
                // Retrieval results are still useful; surface the model error softly.
                self.status = .failed(Self.friendly(error))
            }
        }
    }

    func cancel() {
        task?.cancel()
        isAnswerStreaming = false
        if status == .answering || status == .searching { status = .done }
    }

    private static func friendly(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("context") || text.localizedCaseInsensitiveContains("exceed") {
            return "The excerpts were too long for the on-device model. Try a more specific question."
        }
        if text.localizedCaseInsensitiveContains("guardrail") || text.localizedCaseInsensitiveContains("safety") {
            return "The on-device model declined to answer this. The matching passages are shown below."
        }
        return "The on-device model couldn't finish: \(text). The matching passages are shown below."
    }

    // MARK: - Citation navigation

    /// Finds the page a passage lives on by searching the PDF for its
    /// opening words. Falls back to page 0.
    nonisolated static func pageIndex(for passage: String, in url: URL) async -> Int {
        await Task.detached(priority: .userInitiated) { () -> Int in
            guard let pdf = PDFDocument(url: url), !pdf.isLocked else { return 0 }
            // Take a distinctive probe: skip very short leading words, use
            // up to 6 words so hyphenation and line breaks don't defeat it.
            let words = passage.split(separator: " ").map(String.init)
            for start in stride(from: 0, to: min(words.count, 30), by: 6) {
                let probe = words[start..<min(start + 6, words.count)].joined(separator: " ")
                guard probe.count >= 12 else { continue }
                let matches = pdf.findString(probe, withOptions: [.caseInsensitive, .diacriticInsensitive])
                if let page = matches.first?.pages.first {
                    return pdf.index(for: page)
                }
            }
            return 0
        }.value
    }
}
