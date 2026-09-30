import Foundation

/// Parses user-typed page ranges like "1-3, 5, 8-" against a page count.
/// Pages are 1-based in the input and 0-based in the result.
enum PageRange {
    enum ParseError: LocalizedError {
        case empty
        case invalid(String)
        case outOfRange(Int, Int)

        var errorDescription: String? {
            switch self {
            case .empty: "Enter at least one page."
            case .invalid(let token): "\"\(token)\" isn't a valid page or range."
            case .outOfRange(let page, let max): "Page \(page) doesn't exist. This document has \(max) pages."
            }
        }
    }

    /// Returns sorted, de-duplicated zero-based page indices.
    static func parse(_ text: String, pageCount: Int) throws -> [Int] {
        let cleaned = text.replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty else { throw ParseError.empty }
        var result = Set<Int>()
        for token in cleaned.split(separator: ",").map(String.init) where !token.isEmpty {
            let parts = token.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            switch parts.count {
            case 1:
                guard let p = Int(parts[0]) else { throw ParseError.invalid(token) }
                try check(p, pageCount)
                result.insert(p - 1)
            case 2:
                let startText = parts[0], endText = parts[1]
                let start = startText.isEmpty ? 1 : Int(startText)
                let end = endText.isEmpty ? pageCount : Int(endText)
                guard let s = start, let e = end, s <= e else { throw ParseError.invalid(token) }
                try check(s, pageCount)
                try check(e, pageCount)
                for p in s...e { result.insert(p - 1) }
            default:
                throw ParseError.invalid(token)
            }
        }
        guard !result.isEmpty else { throw ParseError.empty }
        return result.sorted()
    }

    private static func check(_ page: Int, _ count: Int) throws {
        guard page >= 1, page <= count else { throw ParseError.outOfRange(page, count) }
    }

    /// Human summary for a selection, e.g. "Pages 1-3, 5".
    static func describe(_ indices: [Int]) -> String {
        guard !indices.isEmpty else { return "No pages" }
        var parts: [String] = []
        var start = indices[0], prev = indices[0]
        for i in indices.dropFirst() {
            if i == prev + 1 { prev = i; continue }
            parts.append(start == prev ? "\(start + 1)" : "\(start + 1)-\(prev + 1)")
            start = i; prev = i
        }
        parts.append(start == prev ? "\(start + 1)" : "\(start + 1)-\(prev + 1)")
        return (indices.count == 1 ? "Page " : "Pages ") + parts.joined(separator: ", ")
    }
}
