import Foundation
import PDFKit
import UIKit

/// Imperative bridge between the SwiftUI Reader chrome and the underlying
/// `PDFView`. Lets the toolbar add highlights, sticky notes, ink, free text,
/// redactions, and signatures without the view having to know about PDFKit
/// directly.
///
/// Saves are debounced — annotation changes accumulate for a second before
/// the document is written back to disk.
@MainActor
@Observable
final class ReaderController {
    private(set) weak var pdfView: PDFView?
    private(set) var documentURL: URL?
    private var saveTask: Task<Void, Never>?

    func attach(pdfView: PDFView, documentURL: URL) {
        self.pdfView = pdfView
        self.documentURL = documentURL
    }

    /// Page index of the currently displayed page, or `nil` if nothing's loaded.
    var currentPageIndex: Int? {
        guard
            let pdfView,
            let page = pdfView.currentPage,
            let pdf = pdfView.document
        else { return nil }
        let index = pdf.index(for: page)
        return index >= 0 ? index : nil
    }

    /// Whether the user currently has text selected. Drives enable state for
    /// selection-based actions like highlight and redact.
    var hasTextSelection: Bool {
        guard let selection = pdfView?.currentSelection else { return false }
        return !selection.selectionsByLine().isEmpty
    }

    /// Navigates the underlying view to the page at the given index.
    func goToPage(_ index: Int) {
        guard
            let pdfView,
            let page = pdfView.document?.page(at: index)
        else { return }
        pdfView.go(to: page)
    }

    /// Navigates the underlying view to an arbitrary PDF destination
    /// (typically from a `PDFOutline` entry).
    func go(to destination: PDFDestination) {
        pdfView?.go(to: destination)
    }

    /// Navigates the underlying view to a PDF selection (typically a search
    /// result) and highlights the matched range.
    func navigate(to selection: PDFSelection) {
        pdfView?.go(to: selection)
        pdfView?.setCurrentSelection(selection, animate: true)
    }

    /// Navigates the underlying view to a PDF annotation by building a
    /// destination at the annotation's bounds.
    func navigate(to annotation: PDFAnnotation) {
        guard let page = annotation.page else { return }
        let destination = PDFDestination(page: page, at: annotation.bounds.origin)
        pdfView?.go(to: destination)
    }

    // MARK: - Markup (free)

    /// Adds a yellow highlight over the current text selection, one annotation
    /// per visual line so wrapped text renders cleanly.
    func highlightSelection() {
        guard
            let pdfView,
            let selection = pdfView.currentSelection
        else { return }

        let colorChoice = HighlightColor(
            rawValue: UserDefaults.standard.string(forKey: AppSettings.highlightColor) ?? ""
        ) ?? .yellow
        let highlightColor = colorChoice.uiColor.withAlphaComponent(0.4)

        for lineSelection in selection.selectionsByLine() {
            guard let page = lineSelection.pages.first else { continue }
            let bounds = lineSelection.bounds(for: page)
            let annotation = PDFAnnotation(
                bounds: bounds,
                forType: .highlight,
                withProperties: nil
            )
            annotation.color = highlightColor
            annotation.contents = lineSelection.string
            page.addAnnotation(annotation)
        }
        pdfView.clearSelection()
        scheduleSave()
    }

    /// Drops a sticky-note icon at the center of the currently visible page.
    func addStickyNote() {
        guard
            let pdfView,
            let page = pdfView.currentPage
        else { return }

        let pageBounds = page.bounds(for: pdfView.displayBox)
        let noteSize = CGSize(width: 24, height: 24)
        let origin = CGPoint(
            x: pageBounds.midX - noteSize.width / 2,
            y: pageBounds.midY - noteSize.height / 2
        )
        let annotation = PDFAnnotation(
            bounds: CGRect(origin: origin, size: noteSize),
            forType: .text,
            withProperties: nil
        )
        annotation.contents = "Note"
        annotation.color = .systemYellow
        page.addAnnotation(annotation)
        scheduleSave()
    }

    /// Stamps a rasterized ink drawing across the entire page at `pageIndex`.
    func stampInk(_ image: UIImage, onPageAt pageIndex: Int) {
        guard
            let pdfView,
            let page = pdfView.document?.page(at: pageIndex)
        else { return }
        let bounds = page.bounds(for: pdfView.displayBox)
        let annotation = ImageStampAnnotation(image: image, bounds: bounds)
        page.addAnnotation(annotation)
        scheduleSave()
    }

    // MARK: - Edit (Pro)

    /// Adds a free-text annotation at the center of the current page with the
    /// given content. The annotation is editable in PDFKit's standard markup UI.
    func addText(_ content: String) {
        guard
            let pdfView,
            let page = pdfView.currentPage,
            !content.trimmingCharacters(in: .whitespaces).isEmpty
        else { return }

        let pageBounds = page.bounds(for: pdfView.displayBox)
        let textSize = CGSize(width: min(pageBounds.width * 0.6, 320), height: 80)
        let origin = CGPoint(
            x: pageBounds.midX - textSize.width / 2,
            y: pageBounds.midY - textSize.height / 2
        )
        let annotation = PDFAnnotation(
            bounds: CGRect(origin: origin, size: textSize),
            forType: .freeText,
            withProperties: nil
        )
        annotation.contents = content
        annotation.font = .systemFont(ofSize: 14)
        annotation.fontColor = .label
        annotation.color = .clear
        page.addAnnotation(annotation)
        scheduleSave()
    }

    /// Lays a black rectangle over each line of the current text selection.
    /// Note: v1 visual redaction only — the original glyphs remain in the
    /// content stream. True content-stream redaction is a v1.1 effort.
    func redactSelection() {
        guard
            let pdfView,
            let selection = pdfView.currentSelection
        else { return }

        for lineSelection in selection.selectionsByLine() {
            guard let page = lineSelection.pages.first else { continue }
            let bounds = lineSelection.bounds(for: page)
            let annotation = PDFAnnotation(
                bounds: bounds,
                forType: .square,
                withProperties: nil
            )
            annotation.color = .black
            annotation.interiorColor = .black
            page.addAnnotation(annotation)
        }
        pdfView.clearSelection()
        scheduleSave()
    }

    // MARK: - Signing (Pro)

    /// Places a signature image at the bottom-right of the visible page,
    /// sized to roughly 1/3 of the page width while preserving aspect ratio.
    func placeSignature(_ image: UIImage) {
        guard
            let pdfView,
            let page = pdfView.currentPage
        else { return }

        let pageBounds = page.bounds(for: pdfView.displayBox)
        let targetWidth = pageBounds.width / 3
        let aspect = image.size.height / max(image.size.width, 1)
        let targetHeight = targetWidth * aspect

        let padding: CGFloat = 24
        let bounds = CGRect(
            x: pageBounds.maxX - targetWidth - padding,
            y: pageBounds.minY + padding,
            width: targetWidth,
            height: targetHeight
        )

        let annotation = ImageStampAnnotation(image: image, bounds: bounds)
        page.addAnnotation(annotation)
        scheduleSave()
    }

    // MARK: - Save

    /// Forces an immediate save, cancelling any pending debounced save.
    func flushSave() {
        saveTask?.cancel()
        saveTask = nil
        saveNow()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        guard
            let pdfView,
            let document = pdfView.document,
            let url = documentURL
        else { return }
        document.write(to: url)
    }
}
