import SwiftUI
import SwiftData
import VisionKit

/// ToolsHomeView — hub of file-level PDF operations.
///
/// Free: Scan, New Blank PDF, Images to PDF.
/// Pro: Merge, Split, Watermark, Page Numbers, Remove Password, Compress,
/// File to PDF, PDF to Images, PDF to Word.
struct ToolsHomeView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var activeSheet: ToolSheet?
    @State private var showingScanner = false
    @State private var showingPaywall = false
    @State private var isProcessingScan = false
    @State private var scanError: String?

    private let entitlements = EntitlementStore.shared

    enum ToolSheet: Identifiable {
        case newBlank, merge, split, watermark, pageNumbers, compress, removePassword
        case imagesToPDF, fileToPDF, pdfToImages, pdfToWord, protect, flatten, compare
        var id: Self { self }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Create") {
                    if VNDocumentCameraViewController.isSupported {
                        Button {
                            showingScanner = true
                        } label: {
                            row("Scan to PDF", systemImage: "doc.viewfinder", subtitle: "Capture paper documents with OCR")
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        activeSheet = .newBlank
                    } label: {
                        row("New Blank PDF", systemImage: "doc.badge.plus", subtitle: "Create an empty document")
                    }
                    .buttonStyle(.plain)
                }
                Section("Convert") {
                    Button {
                        activeSheet = .imagesToPDF
                    } label: {
                        row("Images to PDF", systemImage: "photo.on.rectangle.angled", subtitle: "Photos and screenshots into one PDF, with OCR")
                    }
                    .buttonStyle(.plain)
                    Button {
                        gated { activeSheet = .fileToPDF }
                    } label: {
                        proRow("File to PDF", systemImage: "doc.text.below.ecg", subtitle: "Word, Excel, PowerPoint, Pages, text, web pages")
                    }
                    .buttonStyle(.plain)
                    Button {
                        gated { activeSheet = .pdfToImages }
                    } label: {
                        proRow("PDF to Images", systemImage: "photo.stack", subtitle: "Export pages as JPEG or PNG")
                    }
                    .buttonStyle(.plain)
                    Button {
                        gated { activeSheet = .pdfToWord }
                    } label: {
                        proRow("PDF to Word", systemImage: "doc.richtext", subtitle: "Editable .docx or plain text")
                    }
                    .buttonStyle(.plain)
                }
                Section("Organize") {
                    Button {
                        gated { activeSheet = .merge }
                    } label: {
                        proRow("Merge PDFs", systemImage: "doc.on.doc", subtitle: "Combine multiple PDFs into one")
                    }
                    .buttonStyle(.plain)
                    Button {
                        gated { activeSheet = .split }
                    } label: {
                        proRow("Split PDF", systemImage: "rectangle.split.2x1", subtitle: "Break a PDF into two documents")
                    }
                    .buttonStyle(.plain)
                }
                Section("Review") {
                    Button {
                        gated { activeSheet = .compare }
                    } label: {
                        proRow("Compare PDFs", systemImage: "doc.on.doc.fill", subtitle: "See what changed between two versions")
                    }
                    .buttonStyle(.plain)
                    Button {
                        gated { activeSheet = .flatten }
                    } label: {
                        proRow("Flatten PDF", systemImage: "square.3.layers.3d.down.right", subtitle: "Lock annotations and form fields into the page")
                    }
                    .buttonStyle(.plain)
                }
                Section("Stamp") {
                    Button {
                        gated { activeSheet = .watermark }
                    } label: {
                        proRow("Add Watermark", systemImage: "drop", subtitle: "Diagonal text across every page")
                    }
                    .buttonStyle(.plain)
                    Button {
                        gated { activeSheet = .pageNumbers }
                    } label: {
                        proRow("Add Page Numbers", systemImage: "number", subtitle: "N / Total in the bottom-right")
                    }
                    .buttonStyle(.plain)
                }
                Section("Security") {
                    Button {
                        gated { activeSheet = .protect }
                    } label: {
                        proRow(
                            "Protect PDF",
                            systemImage: "lock.doc",
                            subtitle: "Require a password to open, limit printing and copying"
                        )
                    }
                    .buttonStyle(.plain)
                    Button {
                        gated { activeSheet = .removePassword }
                    } label: {
                        proRow(
                            "Remove Password",
                            systemImage: "lock.open",
                            subtitle: "Save an unlocked copy of a protected PDF"
                        )
                    }
                    .buttonStyle(.plain)
                }
                Section("Optimize") {
                    Button {
                        gated { activeSheet = .compress }
                    } label: {
                        proRow("Compress PDF", systemImage: "arrow.down.right.and.arrow.up.left", subtitle: "Reduce file size for sharing")
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Tools")
            .overlay(alignment: .bottom) {
                if isProcessingScan {
                    HStack(spacing: DesignSystem.Spacing.s) {
                        ProgressView()
                        Text("Running OCR…").font(.footnote)
                    }
                    .padding(.horizontal, DesignSystem.Spacing.l)
                    .padding(.vertical, DesignSystem.Spacing.m)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, DesignSystem.Spacing.xl)
                }
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .newBlank: NewBlankPDFView()
                case .merge: MergePDFsView()
                case .split: SplitPDFView()
                case .watermark: WatermarkView()
                case .pageNumbers: PageNumbersView()
                case .compress: CompressView()
                case .removePassword: RemovePasswordView()
                case .imagesToPDF: ImagesToPDFView()
                case .fileToPDF: FileToPDFView()
                case .pdfToImages: PDFToImagesView()
                case .pdfToWord: PDFToWordView()
                case .protect: ProtectPDFView()
                case .flatten: FlattenPDFView()
                case .compare: ComparePDFsView()
                }
            }
            .fullScreenCover(isPresented: $showingScanner) {
                ScannerLauncher(onCompletion: handleScan)
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView()
            }
            .alert(
                "Scan failed",
                isPresented: Binding(
                    get: { scanError != nil },
                    set: { if !$0 { scanError = nil } }
                )
            ) {
                Button("OK") { scanError = nil }
            } message: {
                Text(scanError ?? "")
            }
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

    @ViewBuilder
    private func proRow(_ title: String, systemImage: String, subtitle: String) -> some View {
        if entitlements.isPro {
            row(title, systemImage: systemImage, subtitle: subtitle)
        } else {
            row("\(title) \(FreeTier.suffix(for: .tool))", systemImage: systemImage, subtitle: subtitle)
        }
    }

    private func gated(_ action: () -> Void) {
        if entitlements.unlock(.tool) {
            action()
        } else {
            showingPaywall = true
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
                } catch {
                    scanError = error.localizedDescription
                }
            }
        case .success:
            break
        case .failure(let err):
            scanError = err.localizedDescription
        }
    }
}

#Preview {
    ToolsHomeView()
        .modelContainer(for: [Document.self, Folder.self, Tag.self], inMemory: true)
}
