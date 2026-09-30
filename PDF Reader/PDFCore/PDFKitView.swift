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
    let documentID: UUID
    @Binding var displayMode: PDFDisplayMode
    @Binding var displayDirection: PDFDisplayDirection
    var controller: ReaderController? = nil
    /// Passed explicitly (rather than read off the controller) so SwiftUI
    /// re-runs `updateUIView` when area-redaction mode toggles.
    var isRedactingArea: Bool = false

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.backgroundColor = .clear
        view.document = PDFDocument.opened(at: url)
        view.displayMode = displayMode
        view.displayDirection = displayDirection
        applyPageViewController(to: view)
        controller?.attach(pdfView: view, documentURL: url, documentID: documentID)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument.opened(at: url)
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
        controller?.attach(pdfView: view, documentURL: url, documentID: documentID)
        syncRedactionOverlay(on: view)
    }

    /// Adds or removes the drag-to-redact overlay to match the controller.
    private func syncRedactionOverlay(on view: PDFView) {
        let existing = view.subviews.compactMap { $0 as? RedactionDragOverlay }.first
        let wanted = isRedactingArea
        if wanted, existing == nil, let controller {
            let overlay = RedactionDragOverlay(frame: view.bounds)
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.onRectangle = { rect in controller.redactArea(inViewRect: rect) }
            view.addSubview(overlay)
        } else if !wanted, let existing {
            existing.removeFromSuperview()
        }
    }

    /// Enables `usePageViewController` only for `.singlePage`. Other display
    /// modes scroll naturally; turning on the page view controller for them
    /// breaks two-up layouts.
    private func applyPageViewController(to view: PDFView) {
        let shouldUsePVC = (displayMode == .singlePage)
        view.usePageViewController(shouldUsePVC, withViewOptions: nil)
    }
}

/// Transparent view laid over the `PDFView` while area redaction is active.
/// Drag draws a red-outlined rectangle; on release the rect is handed to
/// the controller in `PDFView` coordinates. Taps and pinches still reach
/// the PDF because only pan gestures are consumed.
final class RedactionDragOverlay: UIView {
    var onRectangle: ((CGRect) -> Void)?

    private var start: CGPoint?
    private let shape = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        shape.fillColor = UIColor.black.withAlphaComponent(0.35).cgColor
        shape.strokeColor = UIColor.systemRed.cgColor
        shape.lineWidth = 1.5
        shape.lineDashPattern = [6, 4]
        layer.addSublayer(shape)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        accessibilityLabel = "Drag to mark an area for redaction"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Single-finger pans are ours; everything else falls through so the
        // user can still pinch-zoom and two-finger scroll while marking.
        guard let touches = event?.allTouches, touches.count > 1 else { return super.hitTest(point, with: event) }
        return nil
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            start = point
            shape.path = nil
        case .changed:
            guard let start else { return }
            shape.path = UIBezierPath(rect: rect(from: start, to: point)).cgPath
        case .ended:
            guard let start else { return }
            let r = rect(from: start, to: point)
            shape.path = nil
            self.start = nil
            if r.width > 4, r.height > 4 { onRectangle?(r) }
        default:
            shape.path = nil
            start = nil
        }
    }

    private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
