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

    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding: Bool = false

    @State private var selection: Destination = .library
    @State private var showingImporter = false
    @State private var showingScanner = false
    @State private var showingNewBlank = false
    @State private var importError: String?
    @State private var isProcessingScan = false

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
                            "Import PDF",
                            systemImage: "square.and.arrow.down",
                            subtitle: "Add PDFs from Files or other apps"
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
