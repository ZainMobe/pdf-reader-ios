import Foundation
import PDFKit
import UIKit

/// Imperative bridge between the SwiftUI Reader chrome and the underlying
/// `PDFView`. Lets the toolbar add highlights, sticky notes, ink, free text,
/// redactions, and signatures without the view having to know about PDFKit
/// directly.
///
/// Saves are debounced — annotation changes accumulate for a second before
/// the document is written back to disk. All writes go through
/// `NSFileCoordinator`, and the controller registers an `NSFilePresenter`
/// so concurrent edits in other windows automatically refresh this view.
@MainActor
@Observable
final class ReaderController {
    private(set) weak var pdfView: PDFView?
    private(set) var documentURL: URL?
    private(set) var documentID: UUID?
    private var saveTask: Task<Void, Never>?
    private var presenter: PDFFilePresenter?

    /// Stack of recently-added annotation groups. Each user action (highlight,
    /// sticky note, ink, text, redaction, signature) appends one entry; undo
    /// pops the most recent and removes those annotations. Cleared when the
    /// document is reloaded from disk because the in-memory annotation
    /// references no longer match the new PDFDocument.
    private var undoStack: [[PDFAnnotation]] = []

    /// True when there's at least one annotation edit that can be reverted.
    /// Drives the visibility of the Reader's floating undo button.
    var canUndo: Bool { !undoStack.isEmpty }

    /// Page to restore when the view first attaches (reading position).
    /// A router `pageToOpen` (citation, widget link) takes precedence.
    var initialPageIndex: Int?

    /// Fires with the new page index whenever the visible page changes.
    var onPageChanged: ((Int) -> Void)?
    private var pageObserver: NSObjectProtocol?

    /// Last page the user was on in this session. Restored when the host
    /// rebuilds the `PDFView` (password unlock, form fill, page edits).
    private var lastKnownPageIndex: Int?

    /// Fires after a successful write so the host can refresh derived data
    /// (Library thumbnail, file size).
    var onSaved: (() -> Void)?

    /// Set when a write fails so the host can tell the user instead of
    /// silently losing edits on exit.
    var saveError: String?

    /// True once an annotation edit exists that hasn't been written to disk.
    /// Without it, every `flushSave` (scene inactive, view disappear) would
    /// rewrite the entire PDF even when nothing changed.
    private var isDirty = false

    func attach(pdfView: PDFView, documentURL: URL, documentID: UUID) {
        let isNewView = self.pdfView !== pdfView
        let isSameDocument = self.documentURL == documentURL
        self.pdfView = pdfView
        self.documentID = documentID

        // Only navigate once the document is actually readable. A locked
        // PDF (password still pending) must not consume the saved reading
        // position, or the unlock reload lands on page 1.
        let isReadable = pdfView.document != nil && pdfView.document?.isLocked == false

        if isNewView, isSameDocument {
            // The host rebuilt the view: the undo stack references pages of
            // the old PDFDocument and would dangle.
            undoStack.removeAll()
        }

        // A citation or banner asked for a specific page of this document.
        let router = IncomingFileRouter.shared
        if let page = router.pageToOpen, router.documentToOpen == nil, isReadable {
            router.pageToOpen = nil
            initialPageIndex = nil
            DispatchQueue.main.async { [weak self] in
                self?.goToPage(page)
            }
        } else if let page = initialPageIndex, isReadable {
            initialPageIndex = nil
            if page > 0 {
                DispatchQueue.main.async { [weak self] in
                    self?.goToPage(page)
                }
            }
        } else if isNewView, isSameDocument, isReadable, let page = lastKnownPageIndex, page > 0 {
            DispatchQueue.main.async { [weak self] in
                self?.goToPage(page)
            }
        }

        // The observer is bound to a specific PDFView instance, so it has to
        // be re-registered whenever the host hands us a new one.
        if isNewView || pageObserver == nil {
            if let pageObserver {
                NotificationCenter.default.removeObserver(pageObserver)
            }
            pageObserver = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged, object: pdfView, queue: .main
            ) { [weak self] _ in
                guard let controller = self else { return }
                Task { @MainActor in
                    guard let index = controller.currentPageIndex else { return }
                    controller.lastKnownPageIndex = index
                    controller.onPageChanged?(index)
                }
            }
        }
        if !isSameDocument {
            disconnect()
            self.documentURL = documentURL
            let presenter = PDFFilePresenter(url: documentURL) { [weak self] in
                let owner = self
                Task { @MainActor in
                    owner?.reloadFromExternalChange()
                }
            }
            self.presenter = presenter
            NSFileCoordinator.addFilePresenter(presenter)
            refreshPendingRedactionCount()
        }
    }

    /// Releases the registered file presenter. Call from `onDisappear`.
    func disconnect() {
        if let presenter {
            NSFileCoordinator.removeFilePresenter(presenter)
        }
        presenter = nil
        if let pageObserver {
            NotificationCenter.default.removeObserver(pageObserver)
        }
        pageObserver = nil
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

    /// Navigates to a point on a page, both given in PDF page space.
    ///
    /// Sheets (search, outline, notes) open their own `PDFDocument` to do
    /// their work, so the `PDFPage`/`PDFSelection` objects they produce
    /// belong to a different document instance than the one on screen.
    /// `PDFView.go(to:)` silently ignores foreign pages, so navigation is
    /// expressed as index + geometry and resolved against our document.
    func go(toPageIndex index: Int, point: CGPoint? = nil) {
        guard
            let pdfView,
            let page = pdfView.document?.page(at: index)
        else { return }
        if let point {
            pdfView.go(to: PDFDestination(page: page, at: point))
        } else {
            pdfView.go(to: page)
        }
    }

    /// Scrolls to a rectangle on a page (page space) and highlights the
    /// text inside it. Used for search results.
    func navigate(toPageIndex index: Int, bounds: CGRect) {
        guard
            let pdfView,
            let page = pdfView.document?.page(at: index)
        else { return }
        // PDFDestination's point lands at the top-left of the viewport, and
        // PDF space is bottom-up, so aim at the rect's top edge.
        pdfView.go(to: PDFDestination(page: page, at: CGPoint(x: bounds.minX, y: bounds.maxY)))
        if let selection = page.selection(for: bounds), !selection.selectionsByLine().isEmpty {
            pdfView.setCurrentSelection(selection, animate: true)
        }
    }

    /// Navigates to an annotation's location by page index + bounds.
    func navigate(toAnnotationAtPageIndex index: Int, bounds: CGRect) {
        go(toPageIndex: index, point: CGPoint(x: bounds.minX, y: bounds.maxY))
    }

    // MARK: - Markup (free)

    /// Adds a highlight over the current text selection using the user's
    /// configured `HighlightColor`, one annotation per visual line.
    func highlightSelection() {
        guard
            let pdfView,
            let selection = pdfView.currentSelection
        else {
            Haptics.warning()
            return
        }
        Haptics.impact(.light)

        let colorChoice = HighlightColor(
            rawValue: UserDefaults.standard.string(forKey: AppSettings.highlightColor) ?? ""
        ) ?? .yellow
        let highlightColor = colorChoice.uiColor.withAlphaComponent(0.4)

        var added: [PDFAnnotation] = []
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
            added.append(annotation)
        }
        pdfView.clearSelection()
        recordEdit(added)
        scheduleSave()
    }

    /// Drops a sticky-note icon at the center of the currently visible page.
    /// The note's body text is `contents`; tapping the icon in PDFView shows
    /// the popup with that text.
    func addStickyNote(text: String) {
        guard
            let pdfView,
            let page = pdfView.currentPage
        else { return }
        Haptics.impact(.light)

        let pageBounds = page.bounds(for: pdfView.displayBox)
        let noteSize = CGSize(width: 32, height: 32)
        let origin = CGPoint(
            x: pageBounds.midX - noteSize.width / 2,
            y: pageBounds.midY - noteSize.height / 2
        )
        let annotation = PDFAnnotation(
            bounds: CGRect(origin: origin, size: noteSize),
            forType: .text,
            withProperties: nil
        )
        annotation.contents = text.isEmpty ? "Note" : text
        annotation.color = .systemYellow
        annotation.iconType = .note
        page.addAnnotation(annotation)
        recordEdit([annotation])
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
        recordEdit([annotation])
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
        recordEdit([annotation])
        scheduleSave()
    }

    // MARK: - Redaction (Pro)

    /// Number of pending (not yet applied) redaction marks in the document.
    /// Drives the "Apply Redactions (N)" menu item.
    private(set) var pendingRedactionCount = 0

    /// When true, `PDFKitView` shows a drag overlay that turns a rectangle
    /// into a redaction mark.
    var isRedactingArea = false

    func refreshPendingRedactionCount() {
        guard let document = pdfView?.document else { pendingRedactionCount = 0; return }
        pendingRedactionCount = PDFRedactor.pendingCount(in: document)
    }

    /// Marks the current text selection for redaction. Nothing is removed
    /// until `applyRedactions` runs; marks can be undone like other edits.
    func redactSelection() {
        guard let pdfView, let selection = pdfView.currentSelection else { return }
        let added = PDFRedactor.mark(selection: selection)
        pdfView.clearSelection()
        guard !added.isEmpty else { return }
        Haptics.impact(.light)
        recordEdit(added)
        refreshPendingRedactionCount()
        scheduleSave()
    }

    /// Marks a rectangle given in `PDFView` coordinates (from the drag overlay).
    func redactArea(inViewRect rect: CGRect) {
        guard let pdfView else { return }
        // Use the rect's centre to pick the page; clamp to that page's bounds
        // so a drag that leaves the page edge doesn't produce a giant mark.
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        guard let page = pdfView.page(for: centre, nearest: true) else { return }
        let pageRect = pdfView.convert(rect, to: page)
        let clamped = pageRect.intersection(page.bounds(for: pdfView.displayBox))
        guard clamped.width > 2, clamped.height > 2 else { return }
        let mark = PDFRedactor.mark(clamped, on: page)
        Haptics.impact(.light)
        recordEdit([mark])
        refreshPendingRedactionCount()
        scheduleSave()
    }

    /// Marks every occurrence of `text`. Returns (marks, pages).
    @discardableResult
    func redactOccurrences(of text: String) -> (marks: Int, pages: Int) {
        guard let pdfView, let document = pdfView.document else { return (0, 0) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return (0, 0) }
        let result = PDFRedactor.markOccurrences(of: trimmed, in: document)
        guard !result.marks.isEmpty else { return (0, 0) }
        Haptics.impact(.light)
        recordEdit(result.marks)
        refreshPendingRedactionCount()
        // Force PDFView to repaint pages that gained marks.
        let current = pdfView.currentPage
        pdfView.document = document
        if let current { pdfView.go(to: current) }
        scheduleSave()
        return (result.marks.count, result.pages)
    }

    func clearRedactionMarks() {
        guard let pdfView, let document = pdfView.document else { return }
        PDFRedactor.removeAllMarks(in: document)
        undoStack.removeAll()
        refreshPendingRedactionCount()
        let current = pdfView.currentPage
        pdfView.document = document
        if let current { pdfView.go(to: current) }
        scheduleSave()
    }

    /// Permanently removes the content under every pending mark.
    ///
    /// Works on a fresh `PDFDocument` loaded from disk (after flushing any
    /// pending annotation save) so rasterising can run off the main thread
    /// without racing the on-screen `PDFView`. The result is written back
    /// through the file coordinator with the document's password intact,
    /// then the view reloads.
    func applyRedactions() async throws -> PDFRedactor.Result {
        guard let url = documentURL else { throw PDFRedactor.RedactionError.nothingToApply }
        flushSave()
        let password = DocumentPasswordStore.password(for: url)
        let currentIndex = currentPageIndex

        let (result, data) = try await Task.detached(priority: .userInitiated) { () throws -> (PDFRedactor.Result, Data) in
            guard let pdf = PDFDocument(url: url) else { throw PDFRedactor.RedactionError.nothingToApply }
            if pdf.isLocked {
                guard let password, pdf.unlock(withPassword: password) else { throw PDFRedactor.RedactionError.locked }
            }
            let result = try PDFRedactor.apply(to: pdf)
            var options: [PDFDocumentWriteOption: Any] = [:]
            if let password {
                options[.userPasswordOption] = password
                options[.ownerPasswordOption] = password
            }
            guard let data = options.isEmpty ? pdf.dataRepresentation() : pdf.dataRepresentation(options: options) else {
                throw PDFRedactor.RedactionError.renderFailed(0)
            }
            return (result, data)
        }.value

        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordinationError: NSError?
        var writeError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do { try data.write(to: coordinatedURL, options: [.atomic]) } catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }

        // Old annotation references are gone with the replaced pages, and the
        // on-screen document is about to be replaced by the file we just wrote.
        undoStack.removeAll()
        isDirty = false
        isRedactingArea = false
        if let pdfView {
            let reloaded = PDFDocument.opened(at: url)
            reloaded?.delegate = ThemedDocumentDelegate.shared
            pdfView.document = reloaded
            if let currentIndex, let page = pdfView.document?.page(at: min(currentIndex, (pdfView.document?.pageCount ?? 1) - 1)) {
                pdfView.go(to: page)
            }
        }
        refreshPendingRedactionCount()
        if let documentID { ThumbnailCache.shared.invalidate(documentID) }
        Haptics.success()
        return result
    }

    // MARK: - Signing (Pro)

    /// Places a signature image on a specific page using the supplied bounds
    /// in PDF page coordinates. The caller (typically `SignaturePlacementSheet`)
    /// computes the bounds based on the user's drag/resize gesture.
    func placeSignature(
        _ image: UIImage,
        bounds: CGRect,
        rotationDegrees: CGFloat,
        onPageAt pageIndex: Int
    ) {
        guard
            let pdfView,
            let page = pdfView.document?.page(at: pageIndex)
        else { return }
        Haptics.impact(.medium)
        let annotation = ImageStampAnnotation(
            image: image,
            bounds: bounds,
            rotationDegrees: rotationDegrees
        )
        page.addAnnotation(annotation)
        recordEdit([annotation])
        scheduleSave()

        // Snap the reader to the page that just got a signature so the
        // user sees the result immediately.
        pdfView.go(to: page)
    }

    // MARK: - Undo

    /// Reverts the most recent annotation edit. The Reader's floating undo
    /// button calls this and observes `canUndo` to know when to show itself.
    func undoLastEdit() {
        guard let last = undoStack.popLast() else { return }
        Haptics.impact(.light)

        for annotation in last {
            annotation.page?.removeAnnotation(annotation)
        }

        // PDFView caches each page as a rendered image. In-place
        // `removeAnnotation` doesn't reliably invalidate that cache, so
        // the deleted mark stays visible even though it's gone from the
        // model. Reassigning the same document instance forces a
        // re-render; restoring the current page keeps the user where
        // they were. Earlier undo-stack entries still reference valid
        // page instances because the document instance is unchanged.
        if let pdfView, let document = pdfView.document {
            let currentPage = pdfView.currentPage
            pdfView.document = document
            if let currentPage {
                pdfView.go(to: currentPage)
            }
        }

        // The undone edit may have been a redaction mark.
        refreshPendingRedactionCount()
        scheduleSave()
    }

    private func recordEdit(_ annotations: [PDFAnnotation]) {
        guard !annotations.isEmpty else { return }
        undoStack.append(annotations)
    }

    // MARK: - Save

    /// Forces an immediate save, cancelling any pending debounced save.
    func flushSave() {
        saveTask?.cancel()
        saveTask = nil
        saveNow()
    }

    private func scheduleSave() {
        isDirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes the document via `NSFileCoordinator` so concurrent saves from
    /// other windows on the same file are serialized. The presenter we own
    /// is passed in so we don't fire `presentedItemDidChange` on ourselves.
    private func saveNow() {
        guard
            isDirty,
            let pdfView,
            let document = pdfView.document,
            let url = documentURL
        else { return }

        // PDFKit writes an unencrypted file by default, so saving an annotation
        // onto a protected PDF would silently strip its password. Re-apply the
        // password we hold for it; removing protection stays an explicit choice
        // in Tools -> Remove Password.
        var writeOptions: [PDFDocumentWriteOption: Any] = [:]
        if let password = DocumentPasswordStore.password(for: url) {
            writeOptions[.userPasswordOption] = password
            writeOptions[.ownerPasswordOption] = password
        }

        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordinationError: NSError?
        var didWrite = false
        coordinator.coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            if writeOptions.isEmpty {
                didWrite = document.write(to: coordinatedURL)
            } else {
                didWrite = document.write(to: coordinatedURL, withOptions: writeOptions)
            }
        }

        guard didWrite, coordinationError == nil else {
            // Keep the edits marked dirty so the next flush retries, and let
            // the host surface the problem.
            saveError = coordinationError?.localizedDescription
                ?? "Your latest edits couldn't be saved to this PDF. Check available storage and try again."
            return
        }
        isDirty = false

        // The first page may now look different (signature, ink, highlight,
        // redaction, etc.), so drop the cached library thumbnail and let the
        // host refresh the persisted one.
        if let documentID {
            ThumbnailCache.shared.invalidate(documentID)
        }
        onSaved?()
    }

    /// Called by our `PDFFilePresenter` when another writer modifies the file.
    /// Reloads the underlying `PDFView` so the user sees the latest version.
    private func reloadFromExternalChange() {
        guard let pdfView, let url = documentURL else { return }
        // Annotation references in the undo stack belong to the soon-to-be
        // replaced PDFDocument, so they'd dangle after the reload. Unsaved
        // in-memory edits are superseded by the external write.
        undoStack.removeAll()
        isDirty = false
        let reloaded = PDFDocument.opened(at: url)
        reloaded?.delegate = ThemedDocumentDelegate.shared
        pdfView.document = reloaded
    }
}

/// Lightweight `NSFilePresenter` that just forwards `presentedItemDidChange`
/// to a closure. Lets `ReaderController` stay `@MainActor` while still being
/// a participant in file coordination.
final class PDFFilePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    var presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue = .main
    private let onChange: @Sendable () -> Void

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.presentedItemURL = url
        self.onChange = onChange
        super.init()
    }

    func presentedItemDidChange() {
        onChange()
    }
}
