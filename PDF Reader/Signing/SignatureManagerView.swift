import SwiftUI
import SwiftData
import UIKit

/// Settings sub-screen for managing the user's library of saved signatures.
/// Add new signatures, rename, or delete; the result is shared by every
/// place that lists signatures (the Reader sign sheet, etc.).
struct SignatureManagerView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SignatureAsset.createdAt, order: .reverse) private var signatures: [SignatureAsset]

    @State private var showingNewSheet = false
    @State private var renamingAsset: SignatureAsset?
    @State private var renameText = ""

    var body: some View {
        Group {
            if signatures.isEmpty {
                ContentUnavailableView {
                    Label("No Signatures", systemImage: "signature")
                } description: {
                    Text("Save signatures here so you can sign documents quickly without redrawing each time.")
                } actions: {
                    Button("Add Signature") { showingNewSheet = true }
                        .buttonStyle(.glassProminent)
                }
            } else {
                List {
                    ForEach(signatures) { signature in
                        SignatureRow(signature: signature)
                            .contextMenu {
                                Button {
                                    renamingAsset = signature
                                    renameText = signature.name
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    modelContext.delete(signature)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            modelContext.delete(signatures[index])
                        }
                    }
                }
            }
        }
        .navigationTitle("Signatures")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingNewSheet = true
                } label: {
                    Label("Add Signature", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingNewSheet) {
            // SignatureSheet already persists the new SignatureAsset on save;
            // we don't need the returned image since we're managing the library.
            SignatureSheet { _ in }
        }
        .alert(
            "Rename Signature",
            isPresented: Binding(
                get: { renamingAsset != nil },
                set: { if !$0 { renamingAsset = nil } }
            )
        ) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingAsset = nil }
            Button("Save") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let asset = renamingAsset, !trimmed.isEmpty {
                    asset.name = trimmed
                }
                renamingAsset = nil
            }
        }
    }
}

private struct SignatureRow: View {
    let signature: SignatureAsset

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.m) {
            if let image = UIImage(data: signature.imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 40)
                    .background(.tertiary, in: RoundedRectangle(cornerRadius: DesignSystem.Radius.small))
            } else {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.small)
                    .fill(.tertiary)
                    .frame(width: 80, height: 40)
                    .overlay {
                        Image(systemName: "signature")
                            .foregroundStyle(.secondary)
                    }
            }
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(signature.name).font(.headline)
                Text(signature.createdAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
