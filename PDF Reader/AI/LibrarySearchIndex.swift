import Foundation
import NaturalLanguage

/// Passage-level retrieval across every document in the Library.
///
/// Documents already carry their full text in `Document.ocrText` (embedded
/// text for imports, OCR for scans). This index splits that text into
/// overlapping passages, scores them with BM25 for a query, and optionally
/// re-ranks the top candidates with on-device sentence embeddings. It is
/// what lets "Ask your Library" answer with citations instead of guessing.
///
/// Everything is in memory and rebuilt lazily: a document's passages are
/// cached by (id, text length, text hash) and only re-chunked when its text
/// changes. Building runs off the main thread on plain value snapshots so
/// SwiftData models are never touched from a background task.
actor LibrarySearchIndex {
    static let shared = LibrarySearchIndex()

    struct Snapshot: Sendable {
        let id: UUID
        let title: String
        let text: String
    }

    struct Passage: Sendable {
        let documentID: UUID
        let documentTitle: String
        /// Ordinal within the document, for stable citation ids.
        let ordinal: Int
        let text: String
        let tokens: [String]
        let termFrequency: [String: Int]
    }

    struct Hit: Sendable, Identifiable {
        var id: String { "\(documentID.uuidString)-\(ordinal)" }
        let documentID: UUID
        let documentTitle: String
        let ordinal: Int
        let text: String
        var score: Double
    }

    private struct CachedDocument {
        let key: Int
        let passages: [Passage]
    }

    private var cache: [UUID: CachedDocument] = [:]

    // Tunables
    private let passageWords = 110
    private let overlapWords = 30
    private let k1 = 1.4
    private let b = 0.75

    // MARK: - Public

    /// Ensures passages exist for every snapshot; drops documents no longer
    /// present. Cheap when nothing changed.
    func update(with snapshots: [Snapshot]) {
        let live = Set(snapshots.map(\.id))
        for id in cache.keys where !live.contains(id) { cache[id] = nil }
        for snap in snapshots {
            // The title is baked into every passage, so a rename must
            // invalidate the cached chunks too.
            var hasher = Hasher()
            hasher.combine(snap.text.count)
            hasher.combine(snap.text)
            hasher.combine(snap.title)
            let key = hasher.finalize()
            if let cached = cache[snap.id], cached.key == key { continue }
            cache[snap.id] = CachedDocument(key: key, passages: Self.chunk(snap))
        }
    }

    var passageCount: Int { cache.values.reduce(0) { $0 + $1.passages.count } }

    /// Top passages for `query`. BM25 first, then a light embedding re-rank
    /// of the leading candidates when the language model is available.
    func search(_ query: String, limit: Int = 8) -> [Hit] {
        let queryTokens = Self.tokenize(query)
        guard !queryTokens.isEmpty else { return [] }

        let all = cache.values.flatMap(\.passages)
        guard !all.isEmpty else { return [] }

        // Document frequencies over passages.
        var df: [String: Int] = [:]
        let unique = Set(queryTokens)
        for passage in all {
            for term in unique where passage.termFrequency[term] != nil {
                df[term, default: 0] += 1
            }
        }
        let n = Double(all.count)
        let avgLength = Double(all.reduce(0) { $0 + $1.tokens.count }) / n

        var scored: [Hit] = []
        scored.reserveCapacity(all.count)
        for passage in all {
            var score = 0.0
            let length = Double(passage.tokens.count)
            for term in unique {
                guard let tf = passage.termFrequency[term] else { continue }
                let idf = log(1 + (n - Double(df[term] ?? 0) + 0.5) / (Double(df[term] ?? 0) + 0.5))
                let tfNorm = (Double(tf) * (k1 + 1)) / (Double(tf) + k1 * (1 - b + b * length / avgLength))
                score += idf * tfNorm
            }
            // Small bonus when the whole phrase appears verbatim.
            if unique.count > 1, passage.text.range(of: query.trimmingCharacters(in: .whitespaces), options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                score *= 1.35
            }
            if score > 0 {
                scored.append(Hit(documentID: passage.documentID, documentTitle: passage.documentTitle,
                                  ordinal: passage.ordinal, text: passage.text, score: score))
            }
        }
        scored.sort { $0.score > $1.score }

        var top = Array(scored.prefix(max(limit * 4, 24)))
        Self.rerankWithEmbeddings(query: query, hits: &top)

        // Diversify: at most 3 passages per document in the final list so one
        // long document can't crowd out the rest of the library.
        var perDocument: [UUID: Int] = [:]
        var result: [Hit] = []
        for hit in top {
            let count = perDocument[hit.documentID, default: 0]
            guard count < 3 else { continue }
            perDocument[hit.documentID] = count + 1
            result.append(hit)
            if result.count == limit { break }
        }
        return result
    }

    // MARK: - Chunking

    private static func chunk(_ snap: Snapshot) -> [Passage] {
        let normalized = snap.text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{0C}", with: "\n")
        let words = normalized.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        guard !words.isEmpty else { return [] }

        let size = 110, overlap = 30
        var passages: [Passage] = []
        var start = 0
        var ordinal = 0
        while start < words.count {
            let end = min(start + size, words.count)
            let slice = words[start..<end]
            let text = slice.joined(separator: " ")
            let tokens = tokenize(text)
            var tf: [String: Int] = [:]
            for t in tokens { tf[t, default: 0] += 1 }
            passages.append(Passage(documentID: snap.id, documentTitle: snap.title, ordinal: ordinal,
                                    text: text, tokens: tokens, termFrequency: tf))
            ordinal += 1
            if end == words.count { break }
            start += size - overlap
        }
        return passages
    }

    // MARK: - Tokenizing

    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "is", "are", "was", "were", "be",
        "it", "this", "that", "with", "as", "at", "by", "from", "which", "what", "who", "when", "where",
        "how", "does", "do", "did", "my", "me", "i", "you", "we", "our", "about", "any", "there", "into",
    ]

    nonisolated static func tokenize(_ text: String) -> [String] {
        let lowered = text.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
        var tokens: [String] = []
        var current = ""
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
            .filter { $0.count > 1 && !stopWords.contains($0) }
            .map { $0.count > 4 && $0.hasSuffix("s") && !$0.hasSuffix("ss") ? String($0.dropLast()) : $0 }
    }

    // MARK: - Embedding re-rank

    private static func rerankWithEmbeddings(query: String, hits: inout [Hit]) {
        guard hits.count > 1,
              let language = NLLanguageRecognizer.dominantLanguage(for: query),
              let embedding = NLEmbedding.sentenceEmbedding(for: language),
              let queryVector = embedding.vector(for: query)
        else { return }

        func cosine(_ a: [Double], _ b: [Double]) -> Double {
            var dot = 0.0, na = 0.0, nb = 0.0
            for i in 0..<min(a.count, b.count) { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
            return na > 0 && nb > 0 ? dot / (sqrt(na) * sqrt(nb)) : 0
        }

        let maxBM25 = hits.map(\.score).max() ?? 1
        for i in hits.indices {
            // Embed the first ~300 characters; sentence embeddings degrade on
            // long inputs and this is enough to capture the passage's topic.
            let bm25 = hits[i].score / maxBM25
            let head = String(hits[i].text.prefix(300))
            let semantic = embedding.vector(for: head).map { max(0, cosine(queryVector, $0)) } ?? 0
            hits[i].score = 0.65 * bm25 + 0.35 * semantic
        }
        hits.sort { $0.score > $1.score }
    }
}
