import SwiftUI
import PDFKit
import StoreKit

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
    @AppStorage(ReaderTheme.storageKey) private var themeRaw: String = ReaderTheme.light.rawValue
    @State private var showingReflow = false
    @State private var showingSummary = false
    @State private var showingChat = false
    @State private var showingTranslate = false
    @State private var showingExtract = false
    @State private var showingFormFill = false
    @State private var showingSearch = false
    @State private var showingInfo = false
    @State private var exportedAnnotations: ExportedFile?
    @State private var isLocked = false
    /// True when the file can't be opened at all (not downloaded yet,
    /// corrupt, missing). Shows a retry state instead of a blank PDFView.
    @State private var openFailed = false
    @State private var isPreparing = true
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
    @State private var showingFindRedact = false
    @State private var findRedactText = ""
    @State private var findRedactResult: String?
    @State private var showingApplyRedactions = false
    @State private var isApplyingRedactions = false
    @State private var redactionError: String?
    @State private var redactionResultMessage: String?
    @State private var pdfReloadToken = UUID()
    @State private var controller: ReaderController
    @State private var readAloud = ReadAloud()
    @State private var session = ReadingSessionTracker()
    @State private var paywallSource: AnalyticsSource = .reader
    @State private var inkSource: AnalyticsSource = .reader
    private let openSource: AnalyticsSource?

    init(document: Document, openSource: AnalyticsSource? = nil) {
        self.openSource = openSource
        _document = Bindable(wrappedValue: document)
        let controller = ReaderController()
        controller.initialPageIndex = document.lastPageIndex
        _controller = State(initialValue: controller)
    }

    private let entitlements = EntitlementStore.shared

    @AppStorage(AppSettings.cloudAIConsent) private var cloudConsent = false
    @AppStorage(AppSettings.aiProcessingMode) private var processingModeRaw = AIProcessingMode.automatic.rawValue
    @State private var showingCloudConsent = false
    @State private var pendingAIAction: (() -> Void)?

    @Environment(\.openWindow) private var openWindow
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview

    var body: some View {
        Group {
            if isPreparing {
                ProgressView("Opening…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if openFailed {
                openFailedPlaceholder
            } else if isLocked {
                lockedPlaceholder
            } else {
                PDFKitView(
                    url: document.fileURL,
                    documentID: document.id,
                    displayMode: $displayMode,
                    displayDirection: $displayDirection,
                    controller: controller,
                    isRedactingArea: controller.isRedactingArea,
                    theme: readerTheme,
                    onPencilAction: { startInk(source: .readerPencil) }
                )
                .id(pdfReloadToken)
                .background(Color(uiColor: readerTheme.viewBackground))
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .overlay(alignment: .bottom) {
            if readAloud.state != .idle {
                ReadAloudControls(aloud: readAloud)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) {
            if !isLocked && controller.canUndo {
                undoFloatingButton
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) {
            if controller.isRedactingArea && !isLocked {
                HStack(spacing: DesignSystem.Spacing.s) {
                    Image(systemName: "rectangle.dashed")
                    Text("Drag over anything to mark it for redaction.")
                        .font(.footnote)
                    Button("Done") { controller.isRedactingArea = false }
                        .font(.footnote.weight(.semibold))
                }
                .padding(.horizontal, DesignSystem.Spacing.l)
                .padding(.vertical, DesignSystem.Spacing.s)
                .compatGlass(.capsule)
                .padding(.top, DesignSystem.Spacing.s)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay {
            if isApplyingRedactions {
                VStack(spacing: DesignSystem.Spacing.s) {
                    ProgressView()
                    Text("Removing content…").font(.subheadline)
                }
                .padding(DesignSystem.Spacing.xl)
                .compatGlass(.rect(DesignSystem.Radius.medium))
            }
        }
        .animation(DesignSystem.Motion.snappy, value: readAloud.state)
        .animation(DesignSystem.Motion.snappy, value: controller.canUndo)
        .animation(DesignSystem.Motion.snappy, value: controller.isRedactingArea)
        .alert("Find and Mark for Redaction", isPresented: $showingFindRedact) {
            TextField("Text to redact", text: $findRedactText)
                .textInputAutocapitalization(.never)
            Button("Mark All") {
                let r = controller.redactOccurrences(of: findRedactText)
                if r.marks > 0 { entitlements.recordUse(.editing) }
                AppAnalytics.log(.redactionMarked, [.option: "find", .marks: r.marks, .pages: r.pages])
                findRedactResult = r.marks == 0
                    ? "No matches for \"\(findRedactText)\"."
                    : "Marked \(r.marks) \(r.marks == 1 ? "match" : "matches") on \(r.pages) \(r.pages == 1 ? "page" : "pages"). Review them, then choose Apply Redactions."
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every occurrence in this document will be marked. Nothing is removed until you apply.")
        }
        .alert("Redaction", isPresented: Binding(
            get: { findRedactResult != nil || redactionResultMessage != nil },
            set: { if !$0 { findRedactResult = nil; redactionResultMessage = nil } }
        )) {
            Button("OK") { findRedactResult = nil; redactionResultMessage = nil }
        } message: {
            Text(redactionResultMessage ?? findRedactResult ?? "")
        }
        .confirmationDialog(
            "Apply \(controller.pendingRedactionCount) \(controller.pendingRedactionCount == 1 ? "redaction" : "redactions")?",
            isPresented: $showingApplyRedactions,
            titleVisibility: .visible
        ) {
            Button("Permanently Remove Content", role: .destructive) { applyRedactions() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Text and images under the marks are deleted from the file, not just covered. Marked pages are flattened. This cannot be undone.")
        }
        .alert("Couldn't redact", isPresented: Binding(
            get: { redactionError != nil }, set: { if !$0 { redactionError = nil } }
        )) {
            Button("OK") { redactionError = nil }
        } message: {
            Text(redactionError ?? "")
        }
        .alert("Couldn't save", isPresented: Binding(
            get: { controller.saveError != nil }, set: { if !$0 { controller.saveError = nil } }
        )) {
            Button("OK") { controller.saveError = nil }
        } message: {
            Text(controller.saveError ?? "")
        }
        .trackScreen(.reader)
        .onAppear {
            controller.onPageChanged = { [document, session] index in
                if document.lastPageIndex != index { document.lastPageIndex = index }
                session.pageViewed(index)
            }
            // Keep the Library card and file size in step with what was just
            // written; the persisted thumbnail otherwise shows the pre-edit
            // first page forever.
            controller.onSaved = { [document] in
                let url = document.fileURL
                Task {
                    let data = await Task.detached(priority: .utility) {
                        ThumbnailGenerator.persistableThumbnailData(at: url)
                    }.value
                    if let data { document.thumbnailData = data }
                    if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64 {
                        document.fileSize = size
                    }
                }
            }
        }
        .preferredColorScheme(readerTheme.prefersDarkChrome ? .dark : nil)
        .sheet(isPresented: $showingReflow) {
            ReflowReaderView(document: document, startPage: controller.currentPageIndex ?? 0) { page in
                controller.goToPage(page)
            }
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Flush the debounced annotation save first so the shared
                // file includes an edit made a moment ago.
                ShareLink(item: document.fileURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .simultaneousGesture(TapGesture().onEnded {
                    controller.flushSave()
                    AppAnalytics.log(.documentShared, [.source: AnalyticsSource.reader.rawValue])
                    AppAnalytics.feature(.shareDocument, source: AnalyticsSource.reader.rawValue)
                })
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    AppAnalytics.readerAction(.findInDocument)
                    showingSearch = true
                } label: {
                    Label("Find", systemImage: "magnifyingglass")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    sidebarSnapshotPageIndex = controller.currentPageIndex ?? 0
                    AppAnalytics.readerAction(.browseSidebar)
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
                    // Non-consuming check: the signature allowance is charged
                    // when a signature is actually placed, not when the
                    // picker is opened and cancelled.
                    if entitlements.canUse(.signing) {
                        showingSignatureSheet = true
                    } else {
                        paywallSource = .reader
                        showingPaywall = true
                    }
                } label: {
                    proLabel("Sign", systemImage: "signature")
                }
            }
            if AIEngine.availability().isReady || AIEngine.availability() == .needsCloudConsent {
                ToolbarItem(placement: .topBarTrailing) {
                    aiMenu
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                viewMenu
            }
        }
        .cloudAIConsent(isPresented: $showingCloudConsent) {
            pendingAIAction?()
            pendingAIAction = nil
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
            SearchSheet(document: document) { pageIndex, bounds in
                controller.navigate(toPageIndex: pageIndex, bounds: bounds)
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
                AppAnalytics.log(.signaturePlaced, [.pageBucket: AppAnalytics.pageBucket(document.pageCount)])
                AppAnalytics.feature(.signature, source: AnalyticsSource.reader.rawValue)
                document.isSigned = true
                entitlements.recordUse(.signing)
                ReviewPrompt.requestIfNeeded(using: requestReview)
            }
        }
        .sheet(isPresented: $showingPageEditor) {
            PageEditorView(document: document) {
                entitlements.recordUse(.editing)
                pdfReloadToken = UUID()
            }
        }
        .sheet(isPresented: $showingInkSheet) {
            InkSheet(document: document, pageIndex: inkPageIndex) { image in
                controller.stampInk(image, onPageAt: inkPageIndex)
                AppAnalytics.annotation(.ink, source: inkSource)
            }
        }
        .sheet(isPresented: $showingSidebar) {
            ReaderSidebarView(
                document: document,
                currentPageIndex: sidebarSnapshotPageIndex,
                onNavigatePage: { index in controller.goToPage(index) },
                onNavigateDestination: { index, point in controller.go(toPageIndex: index, point: point) },
                onNavigateAnnotation: { index, bounds in controller.navigate(toAnnotationAtPageIndex: index, bounds: bounds) }
            )
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView(source: paywallSource)
        }
        .alert("Add Text", isPresented: $showingAddText) {
            TextField("Text to add", text: $newTextContent)
            Button("Cancel", role: .cancel) { newTextContent = "" }
            Button("Add") {
                let value = newTextContent
                newTextContent = ""
                if !value.trimmingCharacters(in: .whitespaces).isEmpty {
                    controller.addText(value)
                    entitlements.recordUse(.editing)
                    AppAnalytics.annotation(.text)
                }
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
                AppAnalytics.annotation(.stickyNote, [.option: text.isEmpty ? "empty" : "text"])
            }
        } message: {
            Text("Tap the note icon on the page to reveal the text later.")
        }
        .sheet(isPresented: $showingWatermarkSheet) {
            WatermarkView(preselected: document, analyticsSource: .reader)
        }
        .task {
            if !didApplyDefaults {
                displayMode = PDFDisplayMode(rawValue: defaultDisplayModeRaw) ?? .singlePageContinuous
                displayDirection = PDFDisplayDirection(rawValue: defaultDisplayDirectionRaw) ?? .vertical
                didApplyDefaults = true
            }
            await prepareDocument()
            document.lastOpenedAt = Date()
            document.isUnread = false
            logOpenIfNeeded()
        }
        .onChange(of: displayMode) { old, new in
            guard session.didLogOpen, old != new else { return }
            AppAnalytics.readerAction(.displayMode, [.displayMode: displayModeName])
        }
        .onChange(of: displayDirection) { old, new in
            guard session.didLogOpen, old != new else { return }
            AppAnalytics.readerAction(.displayMode, [.displayMode: displayModeName])
        }
        .onChange(of: themeRaw) { _, newTheme in
            AppAnalytics.readerAction(.readerTheme, [.theme: newTheme])
            AppAnalytics.setUserProperty(.readerTheme, newTheme)
        }
        .onDisappear {
            session.finish(pageCount: document.pageCount, theme: themeRaw, displayMode: displayModeName)
            // Speech would otherwise keep going (and keep other apps ducked)
            // after the reader is popped.
            readAloud.stop()
            controller.flushSave()
            controller.disconnect()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Flush pending annotation saves before the app suspends. Without
            // this, the 1-second debounce can swallow recent edits when the
            // user backgrounds the app quickly after annotating.
            if newPhase == .background || newPhase == .inactive {
                controller.flushSave()
                session.pause()
            } else if newPhase == .active, session.didLogOpen {
                session.resume()
            }
        }
    }

    private var markupMenu: some View {
        Menu {
            Button {
                if controller.highlightSelection() {
                    let color = UserDefaults.standard.string(forKey: AppSettings.highlightColor) ?? "yellow"
                    AppAnalytics.annotation(.highlight, [.option: color])
                }
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
                startInk(source: .reader)
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
                // Charged when the text is actually added, not on Cancel.
                if entitlements.canUse(.editing) {
                    showingAddText = true
                } else {
                    paywallSource = .reader
                    showingPaywall = true
                }
            } label: {
                proItem("Add Text", systemImage: "character.textbox")
            }
            Menu {
                Button {
                    // Nothing selected is a no-op; don't charge for it.
                    guard controller.hasTextSelection else {
                        Haptics.warning()
                        return
                    }
                    gated {
                        controller.redactSelection()
                        AppAnalytics.log(.redactionMarked, [.option: "selection"])
                        AppAnalytics.feature(.redact, source: AnalyticsSource.reader.rawValue)
                    }
                } label: {
                    Label("Mark Selected Text", systemImage: "text.badge.minus")
                }
                Button {
                    if controller.isRedactingArea {
                        // Turning the mode off is free.
                        controller.isRedactingArea = false
                    } else {
                        gated {
                            controller.isRedactingArea = true
                            AppAnalytics.log(.redactionMarked, [.option: "area_mode"])
                            AppAnalytics.feature(.redact, source: AnalyticsSource.reader.rawValue)
                        }
                    }
                } label: {
                    Label(controller.isRedactingArea ? "Stop Marking Areas" : "Mark an Area",
                          systemImage: controller.isRedactingArea ? "xmark.rectangle" : "rectangle.dashed")
                }
                Button {
                    // The allowance is charged in the alert's "Mark All"
                    // action once matches are actually marked.
                    if entitlements.canUse(.editing) {
                        findRedactText = ""
                        findRedactResult = nil
                        showingFindRedact = true
                    } else {
                        paywallSource = .reader
                        showingPaywall = true
                    }
                } label: {
                    Label("Find and Mark…", systemImage: "text.magnifyingglass")
                }
                if controller.pendingRedactionCount > 0 {
                    Divider()
                    Button(role: .destructive) {
                        showingApplyRedactions = true
                    } label: {
                        Label("Apply \(controller.pendingRedactionCount) \(controller.pendingRedactionCount == 1 ? "Redaction" : "Redactions")", systemImage: "eye.slash.fill")
                    }
                    Button {
                        AppAnalytics.log(.redactionMarked, [.option: "clear", .marks: controller.pendingRedactionCount])
                        controller.clearRedactionMarks()
                    } label: {
                        Label("Clear Marks", systemImage: "eraser")
                    }
                }
            } label: {
                proItem("Redact", systemImage: "rectangle.fill")
            }
            Button {
                gated {
                    AppAnalytics.toolOpened(.watermark, source: .reader)
                    showingWatermarkSheet = true
                }
            } label: {
                proItem("Add Watermark", systemImage: "drop")
            }
            Divider()
            Button {
                // Charged when the page editor saves, not on Cancel.
                if entitlements.canUse(.editing) {
                    showingPageEditor = true
                } else {
                    paywallSource = .reader
                    showingPaywall = true
                }
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
                logAITap(.summarize)
                aiGated { showingSummary = true }
            } label: {
                proItem("Summarize", systemImage: "text.alignleft")
            }
            Button {
                logAITap(.chat)
                aiGated { showingChat = true }
            } label: {
                proItem("Chat with PDF", systemImage: "message")
            }
            Button {
                logAITap(.translate)
                aiGated { showingTranslate = true }
            } label: {
                proItem("Translate", systemImage: "character.bubble")
            }
            Button {
                logAITap(.extract)
                aiGated { showingExtract = true }
            } label: {
                proItem("Extract Data", systemImage: "tablecells")
            }
            Button {
                // Auto-Fill charges its free-tier use on Apply.
                logAITap(.formFill)
                withCloudConsent {
                    if entitlements.canUse(.aiAction) {
                        showingFormFill = true
                    } else {
                        paywallSource = .reader
                        showingPaywall = true
                    }
                }
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
            Picker("Theme", selection: $themeRaw) {
                ForEach(ReaderTheme.allCases) { theme in
                    Label(theme.title, systemImage: theme.systemImage).tag(theme.rawValue)
                }
            }
            Button {
                AppAnalytics.readerAction(.textView)
                showingReflow = true
            } label: {
                Label("Text View", systemImage: "text.justify.left")
            }
            Divider()
            Button {
                if let url = AnnotationExporter.export(document) {
                    AppAnalytics.readerAction(.exportAnnotations)
                    exportedAnnotations = ExportedFile(url: url)
                }
            } label: {
                Label("Export Annotations", systemImage: "square.and.arrow.up.on.square")
            }
            Button {
                AppAnalytics.readerAction(.documentInfo)
                showingInfo = true
            } label: {
                Label("Document Info", systemImage: "info.circle")
            }
            if horizontalSizeClass == .regular {
                Button {
                    AppAnalytics.feature(.openNewWindow, source: AnalyticsSource.reader.rawValue)
                    openWindow(value: document.id)
                } label: {
                    Label("Open in New Window", systemImage: "macwindow.badge.plus")
                }
            }
        } label: {
            Label("View Options", systemImage: "rectangle.grid.1x2")
        }
    }

    private var undoFloatingButton: some View {
        Button {
            controller.undoLastEdit()
            AppAnalytics.log(.annotationUndone)
            AppAnalytics.feature(.undo, source: AnalyticsSource.reader.rawValue)
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
        }
        .compatGlassButtonStyle()
        .clipShape(Circle())
        .accessibilityLabel("Undo last edit")
        .padding(.trailing, DesignSystem.Spacing.m)
        .padding(.top, DesignSystem.Spacing.s)
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
            .compatGlassButtonStyle(prominent: true)
        }
    }

    private var openFailedPlaceholder: some View {
        ContentUnavailableView {
            Label("Couldn't Open This PDF", systemImage: "icloud.slash")
        } description: {
            Text(DocumentStorage.isUsingICloud
                 ? "The file may still be downloading from iCloud, or it could be damaged."
                 : "The file may be missing or damaged.")
        } actions: {
            Button("Try Again") {
                Task { await prepareDocument() }
            }
            .compatGlassButtonStyle(prominent: true)
        }
    }

    /// Makes sure the file is local, then decides whether the reader has to
    /// ask for a password or show a failure state.
    ///
    /// `PDFDocument.opened(at:)` already applies a password we accepted on a
    /// previous open, so a document the user has unlocked before comes back
    /// unlocked and the prompt never appears again.
    private func prepareDocument() async {
        isPreparing = true
        let url = document.fileURL
        await DocumentStorage.ensureDownloaded(at: url)
        let status = await Task.detached(priority: .userInitiated) { () -> Bool? in
            guard let pdf = PDFDocument.opened(at: url) else { return nil }
            return pdf.isLocked
        }.value
        isPreparing = false
        guard let locked = status else {
            openFailed = true
            AppAnalytics.log(.documentOpenFailed, [.errorType: "unreadable", .encrypted: false])
            return
        }
        openFailed = false
        if locked {
            isLocked = true
            passwordError = nil
            showingPasswordSheet = true
        } else {
            isLocked = false
        }
    }

    /// Validates a typed password and remembers it.
    ///
    /// Earlier builds rewrote the file with `write(to:)` here. PDFKit does not
    /// reliably drop the encryption dictionary on that path, so the document was
    /// still locked when the view reloaded, `checkLockStatus()` fired again, and
    /// the prompt reappeared forever without the PDF ever opening.
    ///
    /// Now the password goes to the Keychain and the file is left exactly as it
    /// is. Stripping the protection permanently is a separate, explicit action:
    /// Tools -> Remove Password.
    private func attemptUnlock(with password: String) {
        guard let pdf = PDFDocument(url: document.fileURL) else {
            passwordError = "Couldn't open document."
            return
        }
        guard pdf.unlock(withPassword: password) else {
            AppAnalytics.log(.readerAction, [.action: AnalyticsFeature.unlockPassword.rawValue, .success: false])
            passwordError = "Incorrect password. Try again."
            return
        }
        DocumentPasswordStore.store(password, for: document.fileURL)
        AppAnalytics.readerAction(.unlockPassword)
        isLocked = false
        passwordError = nil
        showingPasswordSheet = false
        pdfReloadToken = UUID()
    }

    private func applyRedactions() {
        isApplyingRedactions = true
        Task {
            defer { isApplyingRedactions = false }
            do {
                let result = try await controller.applyRedactions()
                AppAnalytics.log(.redactionApplied, [.marks: result.marksApplied, .pages: result.pagesRedacted])
                AppAnalytics.feature(.redact, source: AnalyticsSource.reader.rawValue, [.option: "apply"])
                // The text layer changed: refresh the searchable text and
                // the Library thumbnail so nothing redacted lingers in search.
                if let pdf = PDFDocument.opened(at: document.fileURL) {
                    let body = pdf.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    document.ocrText = body.isEmpty ? nil : body
                    document.pageCount = pdf.pageCount
                    document.fileSize = (try? FileManager.default.attributesOfItem(atPath: document.fileURL.path)[.size] as? Int64) ?? document.fileSize
                    document.thumbnailData = ThumbnailGenerator.persistableThumbnailData(at: document.fileURL)
                }
                redactionResultMessage = "Removed content under \(result.marksApplied) \(result.marksApplied == 1 ? "mark" : "marks") on \(result.pagesRedacted) \(result.pagesRedacted == 1 ? "page" : "pages")."
            } catch {
                AppAnalytics.log(.redactionApplied, [.success: false, .errorType: AppAnalytics.errorLabel(error)])
                redactionError = error.localizedDescription
            }
        }
    }

    private var readerTheme: ReaderTheme { ReaderTheme(rawValue: themeRaw) ?? .light }

    private func startInk(source: AnalyticsSource) {
        guard let index = controller.currentPageIndex else { return }
        inkSource = source
        inkPageIndex = index
        showingInkSheet = true
    }

    private var displayModeName: String {
        let mode: String
        switch displayMode {
        case .singlePage: mode = "single"
        case .singlePageContinuous: mode = "continuous"
        case .twoUp: mode = "two_up"
        case .twoUpContinuous: mode = "two_up_continuous"
        @unknown default: mode = "other"
        }
        return displayDirection == .horizontal ? "\(mode)_horizontal" : mode
    }

    private func logOpenIfNeeded() {
        guard !openFailed else { return }
        guard !session.didLogOpen else {
            session.resume()
            return
        }
        session.markOpened()
        session.resume()
        let source = openSource ?? IncomingFileRouter.shared.takeOpenSource() ?? .library
        let size = (try? FileManager.default.attributesOfItem(atPath: document.fileURL.path)[.size]) as? Int64
        AppAnalytics.log(.documentOpened, [
            .source: source.rawValue,
            .pageBucket: AppAnalytics.pageBucket(document.pageCount),
            .sizeBucket: AppAnalytics.sizeBucket(bytes: size),
            .encrypted: isLocked,
            .theme: themeRaw,
        ])
        AppAnalytics.feature(.readDocument, source: source.rawValue)
    }

    private func toggleReadAloud() {
        if readAloud.state == .idle {
            AppAnalytics.readerAction(.readAloud)
            readAloud.onPageChange = { index in
                controller.goToPage(index)
            }
            readAloud.start(document: document, fromPage: controller.currentPageIndex ?? 0)
        } else {
            readAloud.stop()
        }
    }

    private func logAITap(_ action: AnalyticsAIAction) {
        AppAnalytics.log(.aiActionTapped, [.aiAction: action.rawValue, .source: AnalyticsSource.reader.rawValue])
    }

    private func withCloudConsent(_ action: @escaping () -> Void) {
        if AIEngine.availability() == .needsCloudConsent {
            pendingAIAction = action
            showingCloudConsent = true
        } else {
            action()
        }
    }

    private func aiGated(_ action: @escaping () -> Void) {
        withCloudConsent {
            gated(.aiAction, action)
        }
    }

    /// Runs `action` if the user is Pro or has a free-tier use left (which is
    /// consumed), otherwise presents the paywall. Only for actions that take
    /// effect immediately; use `canUse` + `recordUse` for sheets and alerts.
    private func gated(_ feature: ProFeature = .editing, _ action: () -> Void) {
        if entitlements.unlock(feature) {
            action()
        } else {
            paywallSource = .reader
            showingPaywall = true
        }
    }

    /// Pro menu item label. Keeps the real icon for discoverability and only
    /// appends "(Pro)" to the title when the feature is locked.
    @ViewBuilder
    private func proItem(_ title: String, systemImage: String, feature: ProFeature = .editing) -> some View {
        if entitlements.isPro {
            Label(title, systemImage: systemImage)
        } else {
            let _ = entitlements.usageVersion
            Label("\(title) \(FreeTier.suffix(for: feature))", systemImage: systemImage)
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

