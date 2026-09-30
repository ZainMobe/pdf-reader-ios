import PDFKit
import SwiftData
import SwiftUI

/// Tool sheet: add a password to a PDF, with optional permission limits.
struct ProtectPDFView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var selectedDoc: Document?
    @State private var password = ""
    @State private var confirm = ""
    @State private var showPassword = false
    @State private var useSeparateOwnerPassword = false
    @State private var ownerPassword = ""
    @State private var allowPrinting = true
    @State private var allowCopying = true
    @State private var allowEditing = true
    @State private var rememberOnThisDevice = true
    @State private var replaceOriginal = true

    @State private var isWorking = false
    @State private var error: String?
    @State private var success: ToolSuccessResult?

    private var passwordsMatch: Bool { !password.isEmpty && password == confirm }

    private var strength: (label: String, fraction: Double, color: Color) {
        let length = password.count
        var score = 0
        if length >= 8 { score += 1 }
        if length >= 12 { score += 1 }
        if password.rangeOfCharacter(from: .decimalDigits) != nil { score += 1 }
        if password.rangeOfCharacter(from: .uppercaseLetters) != nil, password.rangeOfCharacter(from: .lowercaseLetters) != nil { score += 1 }
        if password.rangeOfCharacter(from: .punctuationCharacters.union(.symbols)) != nil { score += 1 }
        switch score {
        case 0...1: return ("Weak", 0.25, .red)
        case 2...3: return ("Fair", 0.55, .orange)
        default: return ("Strong", 1, .green)
        }
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
            .navigationTitle(success == nil ? "Protect PDF" : "Done")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if success != nil {
                    ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } }
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { dismiss() }.disabled(isWorking)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Protect") { apply() }
                            .buttonStyle(.glassProminent)
                            .disabled(selectedDoc == nil || !passwordsMatch || isWorking
                                      || (useSeparateOwnerPassword && ownerPassword.isEmpty))
                    }
                }
            }
            .overlay {
                if isWorking {
                    VStack(spacing: DesignSystem.Spacing.s) {
                        ProgressView()
                        Text("Encrypting…").font(.subheadline)
                    }
                    .padding(DesignSystem.Spacing.xl)
                    .glassEffect(.regular, in: .rect(cornerRadius: DesignSystem.Radius.medium))
                }
            }
            .alert("Couldn't protect", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
    }

    private var formContent: some View {
        Form {
            SourceDocumentSection(selected: $selectedDoc)

            Section {
                HStack {
                    Group {
                        if showPassword {
                            TextField("Password", text: $password)
                        } else {
                            SecureField("Password", text: $password)
                        }
                    }
                    .textContentType(.newPassword)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                if showPassword {
                    TextField("Confirm password", text: $confirm)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    SecureField("Confirm password", text: $confirm)
                        .textContentType(.newPassword)
                }
                if !password.isEmpty {
                    HStack {
                        ProgressView(value: strength.fraction)
                            .tint(strength.color)
                        Text(strength.label)
                            .font(.caption)
                            .foregroundStyle(strength.color)
                            .frame(width: 52, alignment: .trailing)
                    }
                    if !confirm.isEmpty && !passwordsMatch {
                        Label("Passwords don't match", systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Password to open")
            } footer: {
                Text("Anyone opening the PDF will need this password. There is no way to recover it if it's lost.")
            }

            Section("Permissions") {
                Toggle("Allow printing", isOn: $allowPrinting)
                Toggle("Allow copying text and images", isOn: $allowCopying)
                Toggle("Allow editing and annotating", isOn: $allowEditing)
                Toggle("Separate owner password", isOn: $useSeparateOwnerPassword.animation())
                if useSeparateOwnerPassword {
                    SecureField("Owner password", text: $ownerPassword)
                        .textContentType(.newPassword)
                    Text("The owner password unlocks everything, including the permissions above. Without one, the open password is used for both.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Replace original in Library", isOn: $replaceOriginal)
                Toggle("Remember password on this device", isOn: $rememberOnThisDevice)
            } footer: {
                Text(replaceOriginal
                     ? "The unprotected file is deleted from this device and iCloud. "
                     : "A protected copy is added next to the original. ")
                + Text(rememberOnThisDevice
                       ? "The password is kept in your Keychain so the file opens here without asking."
                       : "You'll be asked for the password the next time you open it.")
            }
        }
    }

    private func apply() {
        guard let doc = selectedDoc, passwordsMatch else { return }
        var permissions: PDFAccessPermissions = [.allowsContentAccessibility]
        if allowPrinting { permissions.formUnion([.allowsLowQualityPrinting, .allowsHighQualityPrinting]) }
        if allowCopying { permissions.insert(.allowsContentCopying) }
        if allowEditing { permissions.formUnion([.allowsDocumentChanges, .allowsCommenting, .allowsFormFieldEntry, .allowsDocumentAssembly]) }

        let request = PDFOperations.ProtectRequest(
            userPassword: password,
            ownerPassword: useSeparateOwnerPassword ? ownerPassword : password,
            permissions: permissions,
            replaceOriginal: replaceOriginal,
            rememberPassword: rememberOnThisDevice
        )
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                await DocumentStorage.ensureDownloaded(at: doc.fileURL)
                let result = try PDFOperations.protect(doc, request: request, in: modelContext)
                try? modelContext.save()
                success = ToolSuccessResult(
                    title: "PDF Protected",
                    summary: replaceOriginal
                        ? "\(result.title) now requires a password to open."
                        : "A protected copy was added to your Library.",
                    documents: [result]
                )
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
