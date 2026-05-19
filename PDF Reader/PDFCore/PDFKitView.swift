import SwiftUI
import PDFKit

/// SwiftUI wrapper for PDFKit's `PDFView`.
///
/// Owns the imperative bridge between SwiftUI state (page mode, direction)
/// and PDFKit's view. Optionally attaches the underlying `PDFView` to a
/// `ReaderController` so other UI (toolbar actions) can mutate it.
///
/// Single-page mode wraps the view in a `UIPageViewController` (via
/// `usePageViewController`) so swiping moves between pages — otherwise
/// `.singlePage` mode looks frozen because it shows one page with no
/// navigation gesture.
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
        applyPageViewController(to: view)
        controller?.attach(pdfView: view, documentURL: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
        let modeChanged = view.displayMode != displayMode
        let directionChanged = view.displayDirection != displayDirection
        if modeChanged {
            view.displayMode = displayMode
        }
        if directionChanged {
            view.displayDirection = displayDirection
        }
        if modeChanged || directionChanged {
            applyPageViewController(to: view)
        }
        controller?.attach(pdfView: view, documentURL: url)
    }

    /// Enables `usePageViewController` only for `.singlePage`. Other display
    /// modes scroll naturally; turning on the page view controller for them
    /// breaks two-up layouts.
    private func applyPageViewController(to view: PDFView) {
        let shouldUsePVC = (displayMode == .singlePage)
        view.usePageViewController(shouldUsePVC, withViewOptions: nil)
    }
}
