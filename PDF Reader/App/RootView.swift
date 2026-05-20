import SwiftUI
import UniformTypeIdentifiers
import VisionKit
import UIKit

/// Composition root for PDF AI.
///
/// Four tabs (Library, AI, Tools, Settings) plus a floating central
/// Add FAB that opens an action menu — Scan / Import / New Blank — so
/// the most common creation flows are one tap away from anywhere in
/// the app. Adaptive: tab bar on iPhone, sidebar on iPad/Mac via
/// `sidebarAdaptable`.
struct RootView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var selection: Destination = .library
    @State private var previousSelection: Destination = .library
    @State private var showingImporter = false
    @State private var showingScanner = false
    @State private var showingNewBlank = false
    @State private var showingAddMenu = false
    @State private var importError: String?
    @State private var isProcessingScan = false

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selection) {
                Tab("Library", systemImage: "books.vertical", value: Destination.library) {
                    LibraryHomeView()
                }
                Tab("AI", systemImage: "sparkles", value: Destination.ai) {
                    AIAssistantView()
                }
                // Invisible center placeholder so Library/AI sit on the left
                // and Tools/Settings sit on the right, with the FAB occupying
                // the middle slot. Selecting it pops the Add menu and bounces
                // selection back to the previous tab.
                Tab("", systemImage: "", value: Destination.add) {
                    Color.clear
                }
                Tab("Tools", systemImage: "wrench.and.screwdriver", value: Destination.tools) {
                    ToolsHomeView()
                }
                Tab("Settings", systemImage: "gearshape", value: Destination.settings) {
                    SettingsHomeView()
                }
            }
            .tabViewStyle(.sidebarAdaptable)
            .onChange(of: selection) { oldValue, newValue in
                if newValue == .add {
                    selection = oldValue == .add ? previousSelection : oldValue
                    showingAddMenu = true
                } else {
                    previousSelection = newValue
                }
            }

            addFloatingButton
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: true,
            onCompletion: handleImport
        )
        .fullScreenCover(isPresented: $showingScanner) {
            ScannerLauncher(onCompletion: handleScan)
        }
        .sheet(isPresented: $showingNewBlank) {
            NewBlankPDFView()
        }
        .overlay(alignment: .bottom) {
            if isProcessingScan {
                HStack(spacing: DesignSystem.Spacing.s) {
                    ProgressView()
                    Text("Running OCR…")
                        .font(.footnote)
                }
                .padding(.horizontal, DesignSystem.Spacing.l)
                .padding(.vertical, DesignSystem.Spacing.m)
                .glassEffect(.regular, in: .capsule)
//                .padding(.bottom, 170)
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
    }

    // MARK: - Add FAB

    private var addFloatingButton: some View {
        Button {
            Haptics.impact(.light)
            showingAddMenu = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .glassEffect(
                    .regular.tint(Color.accentColor).interactive(),
                    in: .circle
                )
                .shadow(color: Color.black.opacity(0.18), radius: 8, y: 4)
        }
        .accessibilityLabel("Add")
        .confirmationDialog("Add to Library", isPresented: $showingAddMenu, titleVisibility: .visible) {
            if VNDocumentCameraViewController.isSupported {
                Button {
                    Haptics.impact(.light)
                    selection = .library
                    showingScanner = true
                } label: {
                    Label("Scan Document", systemImage: "doc.viewfinder")
                }
            }
            Button {
                Haptics.impact(.light)
                selection = .library
                showingImporter = true
            } label: {
                Label("Import PDF", systemImage: "square.and.arrow.down")
            }
            Button {
                Haptics.impact(.light)
                selection = .library
                showingNewBlank = true
            } label: {
                Label("New Blank PDF", systemImage: "doc.badge.plus")
            }
        }
    }

    // MARK: - Action handlers

    private func handleImport(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                do {
                    try DocumentStorage.importPDF(from: url, into: modelContext)
                    Haptics.success()
                } catch {
                    importError = error.localizedDescription
                }
            }
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

#Preview {
    RootView()
}
