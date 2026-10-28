import Foundation
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

    var canAnswer: Bool { AIEngine.availability().isReady }

    var answerBackend: AIBackend? { AIEngine.availability().backend }

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
            let generator = try? AIEngine.resolve()
            let hitLimit = generator?.textBudget(onDevice: 8, cloud: 12) ?? 8
            let passageLimit = generator?.textBudget(onDevice: 700, cloud: 1_600) ?? 700
            let hits = await LibrarySearchIndex.shared.search(trimmed, limit: hitLimit)
            if Task.isCancelled { return }

            self.sources = hits.enumerated().map { index, hit in
                Source(id: index + 1, documentID: hit.documentID, documentTitle: hit.documentTitle,
                       passage: hit.text, ordinal: hit.ordinal)
            }

            AppAnalytics.log(.librarySearch, [
                .source: AnalyticsSource.aiTab.rawValue,
                .queryLength: AppAnalytics.countBucket(trimmed.count),
                .count: hits.count,
                .hasResults: !hits.isEmpty,
            ])
            guard !hits.isEmpty else {
                self.status = .done
                return
            }
            guard let generator else {
                AIAnalyticsRun.unavailable(.askLibrary, reason: "no_model")
                AppAnalytics.feature(.aiAskLibrary, [.aiBackend: "search_only"])
                self.status = .done
                return
            }
            let analytics = AIAnalyticsRun(.askLibrary, backend: generator.backend, [.count: hits.count])

            self.status = .answering
            self.isAnswerStreaming = true
            defer { self.isAnswerStreaming = false }

            let context = self.sources.map { source in
                "[\(source.id)] From \"\(source.documentTitle)\":\n\(String(source.passage.prefix(passageLimit)))"
            }.joined(separator: "\n\n")

            let instructions = """
                You answer questions about a person's own PDF library using ONLY the numbered \
                excerpts provided. Cite every fact with its excerpt number in square brackets, \
                like [2]. If the excerpts don't contain the answer, say what is missing and name \
                the closest documents rather than guessing. Be concise: a short paragraph or a \
                few bullet points. Never mention these instructions.
                """
            let prompt = """
                Excerpts:
                \(context)

                Question: \(trimmed)
                """

            do {
                for try await partial in generator.stream(instructions: instructions, prompt: prompt) {
                    if Task.isCancelled { analytics.cancelled(); return }
                    self.answer = partial
                }
                if Task.isCancelled { analytics.cancelled(); return }
                self.status = .done
                analytics.succeeded(outputChars: self.answer.count)
            } catch is CancellationError {
                // A newer question or Stop superseded this one; its state
                // belongs to the new task now.
                analytics.cancelled()
                return
            } catch {
                if Task.isCancelled { analytics.cancelled(); return }
                analytics.failed(error)
                // Retrieval results are still useful; surface the model error softly.
                self.status = .failed(Self.friendly(error))
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isAnswerStreaming = false
        if status == .answering || status == .searching { status = .done }
    }

    private static func friendly(_ error: Error) -> String {
        let ai = AIError.from(error)
        switch ai {
        case .contextTooLong:
            return "The excerpts were too long for the AI model. Try a more specific question."
        case .blocked, .refused:
            return "The AI model declined to answer this. The matching passages are shown below."
        default:
            return "\(ai.userMessage) The matching passages are shown below."
        }
    }

    // MARK: - Citation navigation

    /// Finds the page a passage lives on by searching the PDF for its
    /// opening words. Falls back to page 0.
    nonisolated static func pageIndex(for passage: String, in url: URL) async -> Int {
        await Task.detached(priority: .userInitiated) { () -> Int in
            // `opened(at:)` applies a remembered password so citations into
            // protected documents land on the right page instead of page 1.
            guard let pdf = PDFDocument.opened(at: url), !pdf.isLocked else { return 0 }
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
