import Foundation
import PDFKit

/// Builds a Markdown export of a document's annotations and writes it to a
/// temporary file. Returns the file URL so the caller can present a share
/// sheet over it.
enum AnnotationExporter {
    static func export(_ document: Document) -> URL? {
        guard let pdf = PDFDocument(url: document.fileURL) else { return nil }

        var markdown = "# \(document.title)\n\n"
        markdown += "_Annotations exported on \(Date.now.formatted(date: .long, time: .shortened))._\n\n"

        var hasContent = false
        for pageIndex in 0..<pdf.pageCount {
            guard let page = pdf.page(at: pageIndex) else { continue }
            let listable = page.annotations.filter { isListable($0) }
            guard !listable.isEmpty else { continue }

            hasContent = true
            markdown += "## Page \(pageIndex + 1)\n\n"
            for annotation in listable {
                let label = annotationLabel(for: annotation.type ?? "")
                let content = (annotation.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if content.isEmpty {
                    markdown += "- \(label)\n"
                } else {
                    markdown += "- \(label) \(content)\n"
                }
            }
            markdown += "\n"
        }

        if !hasContent {
            markdown += "_This document doesn't have any annotations yet._\n"
        }

        let safeTitle = document.title.replacingOccurrences(of: "/", with: "-")
        let filename = "\(safeTitle) — Annotations.md"
        let url = FileManager.default.temporaryDirectory.appending(path: filename)

        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private static func isListable(_ annotation: PDFAnnotation) -> Bool {
        guard let type = annotation.type else { return false }
        return ["Highlight", "Underline", "StrikeOut", "FreeText", "Text"].contains(type)
    }

    private static func annotationLabel(for type: String) -> String {
        switch type {
        case "Highlight": "**Highlight:**"
        case "Underline": "**Underline:**"
        case "StrikeOut": "**Strikethrough:**"
        case "FreeText": "**Text:**"
        case "Text": "**Note:**"
        default: "**Annotation:**"
        }
    }
}

/// Convenience wrapper that makes a `URL` `Identifiable` so it can drive a
/// `.sheet(item:)` presentation cleanly.
struct ExportedFile: Identifiable {
    let id = UUID()
    let url: URL
}
