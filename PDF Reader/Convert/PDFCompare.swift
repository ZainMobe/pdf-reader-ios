import Foundation
import PDFKit
import UIKit

/// Compares two PDFs page by page: word-level text differences plus page
/// images for side-by-side and overlay views.
enum PDFCompare {
    enum Segment: Hashable {
        case same(String)
        case added(String)
        case removed(String)
    }

    struct PageResult: Identifiable {
        let id: Int
        /// Word-level diff of the page text, in reading order.
        let segments: [Segment]
        let wordsAdded: Int
        let wordsRemoved: Int
        let existsInA: Bool
        let existsInB: Bool
        var hasChanges: Bool { wordsAdded > 0 || wordsRemoved > 0 || !existsInA || !existsInB }
    }

    struct Result {
        let pages: [PageResult]
        let pageCountA: Int
        let pageCountB: Int
        var changedPages: [Int] { pages.filter(\.hasChanges).map(\.id) }
        var totalAdded: Int { pages.reduce(0) { $0 + $1.wordsAdded } }
        var totalRemoved: Int { pages.reduce(0) { $0 + $1.wordsRemoved } }
        var identical: Bool { changedPages.isEmpty }
    }

    enum CompareError: LocalizedError {
        case unreadable
        case locked
        var errorDescription: String? {
            switch self {
            case .unreadable: "One of the documents couldn't be opened."
            case .locked: "One of the documents is password protected. Unlock it first."
            }
        }
    }

    /// Runs the text comparison. Safe off the main thread.
    nonisolated static func compare(_ urlA: URL, _ urlB: URL) throws -> Result {
        guard let a = PDFDocument.opened(at: urlA), let b = PDFDocument.opened(at: urlB) else { throw CompareError.unreadable }
        if a.isLocked || b.isLocked { throw CompareError.locked }

        let count = max(a.pageCount, b.pageCount)
        var pages: [PageResult] = []
        for i in 0..<count {
            let textA = i < a.pageCount ? (a.page(at: i)?.string ?? "") : ""
            let textB = i < b.pageCount ? (b.page(at: i)?.string ?? "") : ""
            let wordsA = words(textA)
            let wordsB = words(textB)
            let (segments, added, removed) = diff(wordsA, wordsB)
            pages.append(PageResult(
                id: i, segments: segments, wordsAdded: added, wordsRemoved: removed,
                existsInA: i < a.pageCount, existsInB: i < b.pageCount
            ))
        }
        return Result(pages: pages, pageCountA: a.pageCount, pageCountB: b.pageCount)
    }

    nonisolated static func words(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)
    }

    /// Word-level diff using Swift's LCS-based `difference(from:)`, merged
    /// back into a single ordered stream of same/added/removed runs.
    nonisolated static func diff(_ a: [String], _ b: [String]) -> ([Segment], Int, Int) {
        // Guard against pathological pages (tens of thousands of words) where
        // LCS becomes slow; compare as whole blocks instead.
        if a.count * b.count > 4_000_000 {
            if a == b { return ([.same(a.joined(separator: " "))], 0, 0) }
            return ([.removed(a.joined(separator: " ")), .added(b.joined(separator: " "))], b.count, a.count)
        }
        let difference = b.difference(from: a)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var raw: [Segment] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) {
                raw.append(.removed(a[i])); i += 1
            } else if j < b.count, inserted.contains(j) {
                raw.append(.added(b[j])); j += 1
            } else if i < a.count, j < b.count {
                raw.append(.same(a[i])); i += 1; j += 1
            } else if i < a.count {
                raw.append(.removed(a[i])); i += 1
            } else {
                raw.append(.added(b[j])); j += 1
            }
        }

        // Coalesce adjacent words of the same kind into runs.
        var merged: [Segment] = []
        for segment in raw {
            switch (merged.last, segment) {
            case (.same(let x)?, .same(let y)): merged[merged.count - 1] = .same(x + " " + y)
            case (.added(let x)?, .added(let y)): merged[merged.count - 1] = .added(x + " " + y)
            case (.removed(let x)?, .removed(let y)): merged[merged.count - 1] = .removed(x + " " + y)
            default: merged.append(segment)
            }
        }
        return (merged, inserted.count, removed.count)
    }

    /// Page image for the visual views. Returns nil past the end of a document.
    nonisolated static func image(of url: URL, page index: Int, maxEdge: CGFloat = 1400) -> UIImage? {
        guard let pdf = PDFDocument.opened(at: url), !pdf.isLocked, index < pdf.pageCount, let page = pdf.page(at: index) else { return nil }
        let bounds = page.bounds(for: .cropBox)
        let scale = min(maxEdge / max(bounds.width, bounds.height), 3)
        return page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .cropBox)
    }
}
