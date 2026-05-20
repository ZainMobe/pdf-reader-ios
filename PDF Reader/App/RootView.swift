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
    @State private var showingImporter = false
    @State private var showingScanner = false
    @State private var showingNewBlank = false
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
                Tab("Tools", systemImage: "wrench.and.screwdriver", value: Destination.tools) {
                    ToolsHomeView()
                }
                Tab("Settings", systemImage: "gearshape", value: Destination.settings) {
                    SettingsHomeView()
                }
            }
            .tabViewStyle(.sidebarAdaptable)

            addFloatingButton
                .padding(.bottom, 28)
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
                .padding(.bottom, 110)
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
        Menu {
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
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(
                    Circle()
                        .fill(Color.accentColor)
                        .shadow(color: Color.black.opacity(0.25), radius: 10, y: 6)
                )
        }
        .menuOrder(.fixed)
        .sensoryFeedback(.impact(weight: .light), trigger: showingScanner)
        .accessibilityLabel("Add")
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
    case library, ai, tools, settings
}

#Preview {
    RootView()
}
