import SwiftUI
import SwiftData

/// Tool sheet for adding a diagonal text watermark across every page of a
/// selected document. The result is saved as a new document so the original
/// stays intact.
struct WatermarkView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Document.addedAt, order: .reverse) private var documents: [Document]

    /// When set, the picker preselects this document and the user only has
    /// to choose watermark text + opacity. Used when opened from the Reader.
    var preselected: Document?
    var analyticsSource: AnalyticsSource = .toolsTab

    @State private var selectedDoc: Document?
    @State private var watermarkText = "CONFIDENTIAL"
    @State private var opacity: Double = 0.2
    @State private var error: String?
    @State private var success: ToolSuccessResult?
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Group {
                if let success {
                    ToolSuccessView(result: success) { dismiss() }
                } else {
                    formContent
                }
            }
            .navigationTitle(success == nil ? "Add Watermark" : "Done")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if success != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close") { dismiss() }
                    }
                }
            }
        }
        .trackScreen(.toolWatermark)
    }

    private var formContent: some View {
        Form {
                Section("Watermark") {
                    TextField("Text", text: $watermarkText)
                        .textInputAutocapitalization(.characters)
                    HStack {
                        Text("Opacity")
                        Slider(value: $opacity, in: 0.1...0.8)
                        Text("\(Int(opacity * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Apply to") {
                    if documents.isEmpty {
                        Text("No documents in your library yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(documents) { doc in
                            Button {
                                selectedDoc = doc
                            } label: {
                                HStack {
                                    Image(systemName: selectedDoc?.id == doc.id ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(.tint)
                                    Text(doc.title)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text("\(doc.pageCount) pages")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section {
                    Text("Annotations and form fields on the original document are flattened in the watermarked copy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.disabled(isWorking)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Apply") { apply() }
                        .compatGlassButtonStyle(prominent: true)
                        .disabled(!canApply || isWorking)
                }
            }
            .overlay {
                if isWorking {
                    VStack(spacing: DesignSystem.Spacing.s) {
                        ProgressView()
                        Text("Adding watermark…").font(.subheadline)
                    }
                    .padding(DesignSystem.Spacing.xl)
                    .compatGlass(.rect(DesignSystem.Radius.medium))
                }
            }
            .alert(
                "Couldn't add watermark",
                isPresented: Binding(
                    get: { error != nil },
                    set: { if !$0 { error = nil } }
                )
            ) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
            .onAppear {
                if selectedDoc == nil, let pre = preselected {
                    selectedDoc = pre
                }
            }
    }

    private var canApply: Bool {
        selectedDoc != nil
            && !watermarkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func apply() {
        guard let doc = selectedDoc else { return }
        let trimmed = watermarkText.trimmingCharacters(in: .whitespacesAndNewlines)
        let alpha = opacity
        isWorking = true
        let started = Date()
        Task {
            defer { isWorking = false }
            await DocumentStorage.ensureDownloaded(at: doc.fileURL)
            do {
                let stamped = try PDFOperations.watermark(
                    doc,
                    text: trimmed,
                    opacity: alpha,
                    in: modelContext
                )
                try? modelContext.save()
                AppAnalytics.toolCompleted(.watermark, startedAt: started, pageCount: stamped.pageCount, [.source: analyticsSource.rawValue])
                success = ToolSuccessResult(
                    title: "Watermark Added",
                    summary: "Stamped \(stamped.pageCount) \(stamped.pageCount == 1 ? "page" : "pages") with \u{201C}\(trimmed)\u{201D}",
                    documents: [stamped]
                )
            } catch {
                AppAnalytics.toolFailed(.watermark, error: error)
                self.error = error.localizedDescription
            }
        }
    }
}
