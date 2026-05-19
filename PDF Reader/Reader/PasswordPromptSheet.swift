import SwiftUI

/// Sheet for entering the password of an encrypted PDF. Stays visible until
/// the caller dismisses it (so an "Incorrect password" error can be shown
/// in-place without re-presenting).
struct PasswordPromptSheet: View {
    let error: String?
    let onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .onSubmit(submit)
                } footer: {
                    if let error {
                        Text(error)
                            .foregroundStyle(.red)
                    } else {
                        Text("This PDF is encrypted. Enter the password to view it.")
                    }
                }
            }
            .navigationTitle("Password Required")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Unlock") { submit() }
                        .buttonStyle(.glassProminent)
                        .disabled(password.isEmpty)
                }
            }
        }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        onSubmit(password)
    }
}
