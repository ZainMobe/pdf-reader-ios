import SwiftUI
import PDFKit
import FoundationModels

/// ReaderView — the full reading surface for a single `Document`.
///
/// Toolbar layout:
///   - Browse (free): page thumbnails, outline, bookmarks
///   - Markup menu (free): highlight, sticky note, ink
///   - Edit menu (Pro): add text, redact selection, edit pages
///   - Sign (Pro), AI menu (Pro): summarize, chat
///   - View options (free): page modes, scroll direction
struct ReaderView: View {
    @Bindable var document: Document
    @State private var displayMode: PDFDisplayMode = .singlePageContinuous
    @State private var displayDirection: PDFDisplayDirection = .vertical
    @AppStorage(AppSettings.defaultDisplayMode) private var defaultDisplayModeRaw: Int = PDFDisplayMode.singlePageContinuous.rawValue
    @AppStorage(AppSettings.defaultDisplayDirection) private var defaultDisplayDirectionRaw: Int = PDFDisplayDirection.vertical.rawValue
    @State private var didApplyDefaults = false
    @State private var showingSummary = false
    @State private var showingChat = false
    @State private var showingTranslate = false
    @State private var showingExtract = false
    @State private var showingFormFill = false
    @State private var showingSearch = false
    @State private var showingInfo = false
    @State private var exportedAnnotations: ExportedFile?
    @State private var isLocked = false
    @State private var showingPasswordSheet = false
    @State private var passwordError: String?
    @State private var showingSignatureSheet = false
    /// Intermediate buffer: SignatureSheet's onSelect stores into this; when
    /// the signature sheet finishes dismissing (onDismiss) we hand it to
    /// `placementTrigger` to present the placement sheet. Two states are
    /// needed because SwiftUI can't present a sheet while another is still
    /// dismissing.
    @State private var capturedSignature: PlacementTrigger?
    @State private var placementTrigger: PlacementTrigger?
    @State private var showingPageEditor = false
    @State private var showingInkSheet = false
    @State private var inkPageIndex: Int = 0
    @State private var showingSidebar = false
    @State private var sidebarSnapshotPageIndex: Int = 0
    @State private var showingPaywall = false
    @State private var showingAddText = false
    @State private var newTextContent = ""
    @State private var showingNotePrompt = false
    @State private var noteText = ""
    @State private var showingWatermarkSheet = false
    @State private var pdfReloadToken = UUID()
    @State private var controller = ReaderController()
    @State private var readAloud = ReadAloud()

    private let model = SystemLanguageModel.default
    private let entitlements = EntitlementStore.shared

    @Environment(\.openWindow) private var openWindow
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if isLocked {
                lockedPlaceholder
            } else {
                PDFKitView(
                    url: document.fileURL,
                    documentID: document.id,
                    displayMode: $displayMode,
                    displayDirection: $displayDirection,
                    controller: controller
                )
                .id(pdfReloadToken)
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .overlay(alignment: .bottom) {
            if readAloud.state != .idle {
                ReadAloudControls(aloud: readAloud)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(DesignSystem.Motion.snappy, value: readAloud.state)
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: document.fileURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingSearch = true
                } label: {
                    Label("Find", systemImage: "magnifyingglass")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    sidebarSnapshotPageIndex = controller.currentPageIndex ?? 0
                    showingSidebar = true
                } label: {
                    Label("Browse", systemImage: "list.bullet.below.rectangle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    toggleReadAloud()
                } label: {
                    Label(
                        readAloud.state == .idle ? "Listen" : "Stop",
                        systemImage: readAloud.state == .idle ? "speaker.wave.2" : "speaker.slash"
                    )
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                markupMenu
            }
            ToolbarItem(placement: .topBarTrailing) {
                editMenu
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    gated { showingSignatureSheet = true }
                } label: {
                    proLabel("Sign", systemImage: "signature")
                }
            }
            if case .available = model.availability {
                ToolbarItem(placement: .topBarTrailing) {
                    aiMenu
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                viewMenu
            }
        }
        .sheet(isPresented: $showingSummary) {
            SummarySheet(document: document)
        }
        .sheet(isPresented: $showingChat) {
            ChatSheet(document: document)
        }
        .sheet(isPresented: $showingTranslate) {
            TranslateSheet(document: document)
        }
        .sheet(isPresented: $showingExtract) {
            ExtractSheet(document: document)
        }
        .sheet(isPresented: $showingFormFill) {
            FormFillSheet(document: document) {
                pdfReloadToken = UUID()
            }
        }
        .sheet(isPresented: $showingSearch) {
            SearchSheet(document: document) { selection in
                controller.navigate(to: selection)
            }
        }
        .sheet(isPresented: $showingInfo) {
            DocumentInfoSheet(document: document)
        }
        .sheet(item: $exportedAnnotations) { file in
            ActivityShareSheet(items: [file.url])
        }
        .sheet(isPresented: $showingPasswordSheet) {
            PasswordPromptSheet(error: passwordError) { password in
                attemptUnlock(with: password)
            }
        }
        .sheet(
            isPresented: $showingSignatureSheet,
            onDismiss: {
                // Hand the captured signature to the placement-trigger
                // binding once the picker has finished dismissing. This
                // pattern (intermediate capture + .sheet(item:)) avoids
                // the race where pendingSignatureImage briefly reads as
                // nil while SwiftUI builds the second sheet's content.
                if let captured = capturedSignature {
                    placementTrigger = captured
                    capturedSignature = nil
                }
            }
        ) {
            SignatureSheet { image in
                capturedSignature = PlacementTrigger(
                    image: image,
                    pageIndex: controller.currentPageIndex ?? 0
                )
            }
        }
        .sheet(item: $placementTrigger) { trigger in
            SignaturePlacementSheet(
                document: document,
                pageIndex: trigger.pageIndex,
                signatureImage: trigger.image
            ) { bounds, rotation in
                controller.placeSignature(
                    trigger.image,
                    bounds: bounds,
                    rotationDegrees: rotation,
                    onPageAt: trigger.pageIndex
                )
                document.isSigned = true
            }
        }
        .sheet(isPresented: $showingPageEditor) {
            PageEditorView(document: document) {
                pdfReloadToken = UUID()
            }
        }
        .sheet(isPresented: $showingInkSheet) {
            InkSheet(document: document, pageIndex: inkPageIndex) { image in
                controller.stampInk(image, onPageAt: inkPageIndex)
            }
        }
        .sheet(isPresented: $showingSidebar) {
            ReaderSidebarView(
                document: document,
                currentPageIndex: sidebarSnapshotPageIndex,
                onNavigatePage: { index in controller.goToPage(index) },
                onNavigateDestination: { destination in controller.go(to: destination) },
                onNavigateAnnotation: { annotation in controller.navigate(to: annotation) }
            )
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView()
        }
        .alert("Add Text", isPresented: $showingAddText) {
            TextField("Text to add", text: $newTextContent)
            Button("Cancel", role: .cancel) { newTextContent = "" }
            Button("Add") {
                let value = newTextContent
                newTextContent = ""
                controller.addText(value)
            }
        } message: {
            Text("Text appears at the center of the current page. Tap and drag to reposition after adding.")
        }
        .alert("Add Sticky Note", isPresented: $showingNotePrompt) {
            TextField("Note text", text: $noteText)
            Button("Cancel", role: .cancel) { noteText = "" }
            Button("Add") {
                let text = noteText
                noteText = ""
                controller.addStickyNote(text: text)
            }
        } message: {
            Text("Tap the note icon on the page to reveal the text later.")
        }
        .sheet(isPresented: $showingWatermarkSheet) {
            WatermarkView(preselected: document)
        }
        .task {
            if !didApplyDefaults {
                displayMode = PDFDisplayMode(rawValue: defaultDisplayModeRaw) ?? .singlePageContinuous
                displayDirection = PDFDisplayDirection(rawValue: defaultDisplayDirectionRaw) ?? .vertical
                didApplyDefaults = true
            }
            checkLockStatus()
            document.lastOpenedAt = Date()
            document.isUnread = false
        }
        .onDisappear {
            controller.flushSave()
            controller.disconnect()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Flush pending annotation saves before the app suspends. Without
            // this, the 1-second debounce can swallow recent edits when the
            // user backgrounds the app quickly after annotating.
            if newPhase == .background || newPhase == .inactive {
                controller.flushSave()
            }
        }
    }

    private var markupMenu: some View {
        Menu {
            Button {
                controller.highlightSelection()
            } label: {
                Label("Highlight Selection", systemImage: "highlighter")
            }
            Button {
                noteText = ""
                showingNotePrompt = true
            } label: {
                Label("Sticky Note", systemImage: "note.text.badge.plus")
            }
            Button {
                startInk()
            } label: {
                Label("Ink", systemImage: "scribble.variable")
            }
        } label: {
            Label("Markup", systemImage: "pencil.tip.crop.circle")
        }
    }

    private var editMenu: some View {
        Menu {
            Button {
                gated { showingAddText = true }
            } label: {
                proItem("Add Text", systemImage: "character.textbox")
            }
            Button {
                gated { controller.redactSelection() }
            } label: {
                proItem("Redact Selection", systemImage: "rectangle.fill")
            }
            Button {
                gated { showingWatermarkSheet = true }
            } label: {
                proItem("Add Watermark", systemImage: "drop")
            }
            Divider()
            Button {
                gated { showingPageEditor = true }
            } label: {
                proItem("Edit Pages", systemImage: "rectangle.stack")
            }
        } label: {
            Label("Edit", systemImage: "pencil")
        }
    }

    private var aiMenu: some View {
        Menu {
            Button {
                gated { showingSummary = true }
            } label: {
                proItem("Summarize", systemImage: "text.alignleft")
            }
            Button {
                gated { showingChat = true }
            } label: {
                proItem("Chat with PDF", systemImage: "message")
            }
            Button {
                gated { showingTranslate = true }
            } label: {
                proItem("Translate", systemImage: "character.bubble")
            }
            Button {
                gated { showingExtract = true }
            } label: {
                proItem("Extract Data", systemImage: "tablecells")
            }
            Button {
                gated { showingFormFill = true }
            } label: {
                proItem("Auto-Fill Form", systemImage: "checklist")
            }
        } label: {
            proLabel("AI", systemImage: "sparkles")
        }
    }

    private var viewMenu: some View {
        Menu {
            Picker("Page Mode", selection: $displayMode) {
                Label("Single Page", systemImage: "rectangle.portrait")
                    .tag(PDFDisplayMode.singlePage)
                Label("Continuous", systemImage: "rectangle.split.1x2")
                    .tag(PDFDisplayMode.singlePageContinuous)
                Label("Two Up", systemImage: "rectangle.split.2x1")
                    .tag(PDFDisplayMode.twoUp)
                Label("Two Up Continuous", systemImage: "rectangle.split.2x2")
                    .tag(PDFDisplayMode.twoUpContinuous)
            }
            Picker("Scroll Direction", selection: $displayDirection) {
                Label("Vertical", systemImage: "arrow.up.and.down")
                    .tag(PDFDisplayDirection.vertical)
                Label("Horizontal", systemImage: "arrow.left.and.right")
                    .tag(PDFDisplayDirection.horizontal)
            }
            Divider()
            Button {
                if let url = AnnotationExporter.export(document) {
                    exportedAnnotations = ExportedFile(url: url)
                }
            } label: {
                Label("Export Annotations", systemImage: "square.and.arrow.up.on.square")
            }
            Button {
                showingInfo = true
            } label: {
                Label("Document Info", systemImage: "info.circle")
            }
            if horizontalSizeClass == .regular {
                Button {
                    openWindow(value: document.id)
                } label: {
                    Label("Open in New Window", systemImage: "macwindow.badge.plus")
                }
            }
        } label: {
            Label("View Options", systemImage: "rectangle.grid.1x2")
        }
    }

    private var lockedPlaceholder: some View {
        ContentUnavailableView {
            Label("Password Required", systemImage: "lock.fill")
        } description: {
            Text("This PDF is encrypted.")
        } actions: {
            Button("Enter Password") {
                passwordError = nil
                showingPasswordSheet = true
            }
            .buttonStyle(.glassProminent)
        }
    }

    private func checkLockStatus() {
        guard let pdf = PDFDocument(url: document.fileURL) else { return }
        if pdf.isLocked {
            isLocked = true
            passwordError = nil
            showingPasswordSheet = true
        } else {
            isLocked = false
        }
    }

    private func attemptUnlock(with password: String) {
        guard let pdf = PDFDocument(url: document.fileURL) else {
            passwordError = "Couldn't open document."
            return
        }
        if pdf.unlock(withPassword: password) {
            if pdf.write(to: document.fileURL) {
                isLocked = false
                passwordError = nil
                showingPasswordSheet = false
                pdfReloadToken = UUID()
            } else {
                passwordError = "Couldn't save unlocked document."
            }
        } else {
            passwordError = "Incorrect password. Try again."
        }
    }

    private func startInk() {
        guard let index = controller.currentPageIndex else { return }
        inkPageIndex = index
        showingInkSheet = true
    }

    private func toggleReadAloud() {
        if readAloud.state == .idle {
            readAloud.onPageChange = { index in
                controller.goToPage(index)
            }
            readAloud.start(document: document, fromPage: controller.currentPageIndex ?? 0)
        } else {
            readAloud.stop()
        }
    }

    /// Runs `action` if the user is Pro, otherwise presents the paywall.
    private func gated(_ action: () -> Void) {
        if entitlements.isPro {
            action()
        } else {
            showingPaywall = true
        }
    }

    /// Pro menu item label. Keeps the real icon for discoverability and only
    /// appends "(Pro)" to the title when the feature is locked.
    @ViewBuilder
    private func proItem(_ title: String, systemImage: String) -> some View {
        if entitlements.isPro {
            Label(title, systemImage: systemImage)
        } else {
            Label("\(title) (Pro)", systemImage: systemImage)
        }
    }

    /// Pro toolbar label. Renders the same as the unlocked variant — Pro state
    /// is signaled at the menu/paywall level rather than via a noisy badge.
    private func proLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
    }
}
/// Identifiable payload that triggers the signature placement sheet via
/// `.sheet(item:)`. Carrying the image + page index in one identified
/// value guarantees SwiftUI never builds the sheet body with a nil image.
private struct PlacementTrigger: Identifiable {
    let id = UUID()
    let image: UIImage
    let pageIndex: Int
}

