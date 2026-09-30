import SwiftUI

/// The sheet users see after tapping "PDF Editor" in the share sheet.
///
/// States: loading (reading attachments), ready (list + options + Save),
/// saving, saved (checkmark, auto-dismiss), failed (message + Close).
struct ShareSheetView: View {
    @Bindable var model: ShareModel

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .loading:
                    loadingView
                case .ready, .saving:
                    readyView
                case .saved:
                    savedView
                case .failed(let message):
                    failedView(message)
                }
            }
            .navigationTitle("Save to PDF Editor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancel() }
                        .disabled(model.phase == .saving || model.phase == .saved)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        model.save()
                    } label: {
                        if model.phase == .saving {
                            ProgressView()
                        } else {
                            Text("Save").bold()
                        }
                    }
                    .disabled(model.phase != .ready)
                }
            }
        }
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Reading files…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var readyView: some View {
        Form {
            Section {
                ForEach(model.rows) { row in
                    HStack(spacing: 12) {
                        thumbnail(for: row)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .lineLimit(2)
                            Text(subtitle(for: row))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(model.summary)
            } footer: {
                if model.skippedCount > 0 {
                    Text(model.skippedCount == 1
                         ? "1 item was skipped because it isn't a PDF or image."
                         : "\(model.skippedCount) items were skipped because they aren't PDFs or images.")
                }
            }

            if model.showsCombineOption {
                Section {
                    Toggle("Combine into one PDF", isOn: $model.combineImages)
                    if model.combineImages {
                        TextField("Title", text: $model.combinedTitle)
                            .textInputAutocapitalization(.words)
                    }
                } footer: {
                    Text(model.combineImages
                         ? "All \(model.imageCount) images become pages of a single PDF, in this order."
                         : "Each image becomes its own PDF.")
                }
            }

            Section {
                Label("Files are added to your Library the next time you open PDF Editor.",
                      systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(model.phase == .saving)
    }

    private var savedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: model.phase)
            Text("Saved")
                .font(.title2.weight(.semibold))
            Text("Open PDF Editor to find it in your Library.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Can't Share", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Close") { model.cancel() }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private func thumbnail(for row: ShareModel.Row) -> some View {
        Group {
            if let image = row.thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: row.kind == .pdf ? "doc.richtext" : "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 58)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func subtitle(for row: ShareModel.Row) -> String {
        let size = ByteCountFormatter.string(fromByteCount: row.byteCount, countStyle: .file)
        return (row.kind == .pdf ? "PDF" : "Image") + " · " + size
    }
}
