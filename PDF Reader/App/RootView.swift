import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import VisionKit
import UIKit

/// Composition root for PDF AI.
///
/// Five tabs (Library, AI, Add, Tools, Settings). The center Add tab
/// shows a full destination with the three creation actions —
/// Scan / Import / New Blank — so they're one tap away from anywhere
/// in the app. Adaptive: tab bar on iPhone, sidebar on iPad/Mac via
/// `sidebarAdaptable`.
struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.requestReview) private var requestReview

    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding: Bool = false

    @State private var selection: Destination = .library
    @State private var showingImporter = false
    @State private var showingScanner = false
    @State private var showingNewBlank = false
    @State private var importError: String?
    @State private var isProcessingScan = false

    private let incomingRouter = IncomingFileRouter.shared

    var body: some View {
        TabView(selection: $selection) {
            Tab("Library", systemImage: "books.vertical", value: Destination.library) {
                LibraryHomeView()
            }
            Tab("AI", systemImage: "sparkles", value: Destination.ai) {
                AIAssistantView()
            }
            Tab("Add", systemImage: "plus.circle.fill", value: Destination.add) {
                AddHomeView(
                    onScan: {
                        Haptics.impact(.light)
                        showingScanner = true
                    },
                    onImport: {
                        Haptics.impact(.light)
                        showingImporter = true
                    },
                    onNewBlank: {
                        Haptics.impact(.light)
                        showingNewBlank = true
                    }
                )
            }
            Tab("Tools", systemImage: "wrench.and.screwdriver", value: Destination.tools) {
                ToolsHomeView()
            }
            Tab("Settings", systemImage: "gearshape", value: Destination.settings) {
                SettingsHomeView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.pdf, .image],
            allowsMultipleSelection: true,
            onCompletion: handleImport
        )
        // Switch to the Library when an incoming file asks to be shown.
        .onChange(of: incomingRouter.libraryRequestToken) { _, _ in
            selection = .library
        }
        .overlay(alignment: .top) {
            if let banner = incomingRouter.banner {
                IncomingFileBanner(banner: banner)
                    .padding(.horizontal, DesignSystem.Spacing.l)
                    .padding(.top, DesignSystem.Spacing.s)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .fullScreenCover(isPresented: $showingScanner) {
            ScannerLauncher(onCompletion: handleScan)
        }
        .sheet(isPresented: $showingNewBlank) {
            NewBlankPDFView()
        }
        .overlay(alignment: .bottom) {
            if isProcessingScan || incomingRouter.inFlightCount > 0 {
                HStack(spacing: DesignSystem.Spacing.s) {
                    ProgressView()
                    Text(isProcessingScan ? "Running OCR…" : "Adding to Library…")
                        .font(.footnote)
                }
                .padding(.horizontal, DesignSystem.Spacing.l)
                .padding(.vertical, DesignSystem.Spacing.m)
                .glassEffect(.regular, in: .capsule)
            }
        }
        .alert(
            "Couldn't add document",
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )
        ) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .fullScreenCover(isPresented: Binding(
            get: { !hasSeenOnboarding },
            set: { if $0 == false { hasSeenOnboarding = true } }
        )) {
            OnboardingView {
                hasSeenOnboarding = true
            }
        }
    }

    // MARK: - Action handlers

    private func handleImport(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            // The router validates, converts images, de-duplicates and
            // shows the "Added" banner with an Open action.
            incomingRouter.handle(urls: urls)
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func handleScan(_ result: Result<[UIImage], any Error>) {
        switch result {
        case .success(let images) where !images.isEmpty:
            Task {
                isProcessingScan = true
                defer { isProcessingScan = false }
                do {
                    try await ScanToPDF.createDocument(from: images, in: modelContext)
                    Haptics.success()
                    ReviewPrompt.requestIfNeeded(using: requestReview)
                } catch {
                    importError = error.localizedDescription
                }
            }
        case .success:
            break
        case .failure(let err):
            importError = err.localizedDescription
        }
    }
}

private enum Destination: Hashable {
    case library, ai, add, tools, settings
}

/// Top banner shown after files arrive from outside the app. Tap Open to
/// jump to the document (or the Library for multi-file batches); swipe up
/// or wait to dismiss.
private struct IncomingFileBanner: View {
    let banner: IncomingFileRouter.Banner
    private let router = IncomingFileRouter.shared

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.m) {
            Image(systemName: banner.systemImage)
                .font(.title3)
                .foregroundStyle(banner.isError ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let subtitle = banner.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if banner.documentID != nil || banner.opensLibrary {
                Button("Open") {
                    Haptics.impact(.light)
                    router.performBannerAction()
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.l)
        .padding(.vertical, DesignSystem.Spacing.m)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignSystem.Radius.large))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .gesture(
            DragGesture(minimumDistance: 10)
                .onEnded { value in
                    if value.translation.height < -20 { router.dismissBanner() }
                }
        )
        .onTapGesture {
            if banner.documentID != nil || banner.opensLibrary {
                router.performBannerAction()
            } else {
                router.dismissBanner()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Full-screen Add destination with the three creation actions.
private struct AddHomeView: View {
    let onScan: () -> Void
    let onImport: () -> Void
    let onNewBlank: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Add to Library") {
                    if VNDocumentCameraViewController.isSupported {
                        Button(action: onScan) {
                            row(
                                "Scan Document",
                                systemImage: "doc.viewfinder",
                                subtitle: "Capture paper documents with OCR"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    Button(action: onImport) {
                        row(
                            "Import Files",
                            systemImage: "square.and.arrow.down",
                            subtitle: "PDFs and images from Files or other apps"
                        )
                    }
                    .buttonStyle(.plain)
                    Button(action: onNewBlank) {
                        row(
                            "New Blank PDF",
                            systemImage: "doc.badge.plus",
                            subtitle: "Create an empty document"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Add")
        }
    }

    private func row(_ title: String, systemImage: String, subtitle: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.m) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(title).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

#Preview {
    RootView()
}
