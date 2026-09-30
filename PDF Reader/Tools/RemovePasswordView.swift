import SwiftUI
import SwiftData
import PDFKit

/// Tool sheet for stripping the password off an encrypted PDF.
///
/// Pick a protected document, enter its password, and a decrypted copy lands in
/// the Library. The original is left exactly as it was, in keeping with every
/// other tool here — removing a document's protection shouldn't be something
/// that can happen by accident.
struct RemovePasswordView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Document.addedAt, order: .reverse) private var documents: [Document]

    @State private var selectedDoc: Document?
    @State private var password = ""
    @State private var protectedIDs: Set<UUID> = []
    @State private var didScan = false
    @State private var isWorking = false
    @State private var error: String?
    @State private var success: ToolSuccessResult?

    private var protectedDocuments: [Document] {
        documents.filter { protectedIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let success {
                    ToolSuccessView(result: success) { dismiss() }
                } else {
                    formContent
                }
            }
            .navigationTitle(success == nil ? "Remove Password" : "Done")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if success != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close") { dismiss() }
                    }
                }
            }
            .task { await scanForProtectedDocuments() }
        }
    }

    private var formContent: some View {
        Form {
            Section("Protected PDF") {
                if !didScan {
                    HStack(spacing: DesignSystem.Spacing.s) {
                        ProgressView()
                        Text("Checking your library…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if protectedDocuments.isEmpty {
                    Text("None of your documents are password-protected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(protectedDocuments) { doc in
                        Button {
                            select(doc)
                        } label: {
                            HStack {
                                Image(systemName: selectedDoc?.id == doc.id
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading) {
                                    Text(doc.title)
                                        .foregroundStyle(.primary)
                                    Text(DocumentPasswordStore.hasPassword(for: doc.fileURL)
                                         ? "Password saved on this device"
                                         : "Password required")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "lock.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section {
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .onSubmit(apply)
                    .disabled(selectedDoc == nil)
            } header: {
                Text("Password")
            } footer: {
                Text("The unlocked copy is added to your Library as a new document. The original keeps its password.")
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
                    .disabled(isWorking)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Remove") { apply() }
                    .buttonStyle(.glassProminent)
                    .disabled(selectedDoc == nil || password.isEmpty || isWorking)
            }
        }
        .overlay {
            if isWorking {
                VStack(spacing: DesignSystem.Spacing.s) {
                    ProgressView()
                    Text("Removing password…")
                        .font(.subheadline)
                }
                .padding(DesignSystem.Spacing.xl)
                .glassEffect(.regular, in: .rect(cornerRadius: DesignSystem.Radius.medium))
            }
        }
        .alert(
            "Couldn't remove the password",
            isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )
        ) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    /// Selecting a document pre-fills the password when we already hold one, so
    /// a document the user has read before is a single tap away from unlocked.
    private func select(_ doc: Document) {
        selectedDoc = doc
        password = DocumentPasswordStore.password(for: doc.fileURL) ?? ""
    }

    /// Opening every PDF is cheap (PDFKit only parses the trailer to answer
    /// `isLocked`) but not instant on a large library, so it happens off the
    /// main actor and the list fills in when it lands.
    private func scanForProtectedDocuments() async {
        guard !didScan else { return }
        let urls = documents.map { ($0.id, $0.fileURL) }
        let locked: Set<UUID> = await Task.detached(priority: .userInitiated) {
            var found: Set<UUID> = []
            for (id, url) in urls where PDFDocument(url: url)?.isLocked == true {
                found.insert(id)
            }
            return found
        }.value
        protectedIDs = locked
        didScan = true
    }

    private func apply() {
        guard let doc = selectedDoc, !password.isEmpty else { return }
        isWorking = true
        // Defer one frame so the progress overlay renders before the
        // synchronous rewrite starts.
        DispatchQueue.main.async {
            do {
                let unlocked = try PDFOperations.removePassword(
                    doc, password: password, in: modelContext
                )
                isWorking = false
                protectedIDs.remove(doc.id)
                password = ""
                success = ToolSuccessResult(
                    title: "Password Removed",
                    summary: "\(unlocked.title) opens without a password. The original is unchanged.",
                    documents: [unlocked]
                )
            } catch {
                self.error = error.localizedDescription
                isWorking = false
            }
        }
    }
}
