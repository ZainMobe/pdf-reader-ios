import SwiftUI
import PDFKit

/// SwiftUI wrapper for PDFKit's `PDFView`.
///
/// Owns the imperative bridge between SwiftUI state (page mode, direction)
/// and PDFKit's view. Optionally attaches the underlying `PDFView` to a
/// `ReaderController` so other UI (toolbar actions) can mutate it.
struct PDFKitView: UIViewRepresentable {
    let url: URL
    @Binding var displayMode: PDFDisplayMode
    @Binding var displayDirection: PDFDisplayDirection
    var controller: ReaderController? = nil

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.backgroundColor = .clear
        view.document = PDFDocument(url: url)
        view.displayMode = displayMode
        view.displayDirection = displayDirection
        controller?.attach(pdfView: view, documentURL: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
        if view.displayMode != displayMode {
            view.displayMode = displayMode
        }
        if view.displayDirection != displayDirection {
            view.displayDirection = displayDirection
        }
        controller?.attach(pdfView: view, documentURL: url)
    }
}
