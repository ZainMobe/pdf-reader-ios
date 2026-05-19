import SwiftUI

/// Editor for the user's auto-fill profile. Bound directly to `UserDefaults`
/// via `@AppStorage` so changes persist as the user types.
struct ProfileEditorView: View {
    @AppStorage(ProfileKeys.fullName) private var fullName = ""
    @AppStorage(ProfileKeys.email) private var email = ""
    @AppStorage(ProfileKeys.phone) private var phone = ""
    @AppStorage(ProfileKeys.addressLine1) private var addressLine1 = ""
    @AppStorage(ProfileKeys.addressLine2) private var addressLine2 = ""
    @AppStorage(ProfileKeys.city) private var city = ""
    @AppStorage(ProfileKeys.state) private var state = ""
    @AppStorage(ProfileKeys.zipCode) private var zipCode = ""
    @AppStorage(ProfileKeys.country) private var country = ""
    @AppStorage(ProfileKeys.company) private var company = ""
    @AppStorage(ProfileKeys.jobTitle) private var jobTitle = ""

    var body: some View {
        Form {
            Section("Personal") {
                TextField("Full name", text: $fullName)
                    .textContentType(.name)
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Phone", text: $phone)
                    .textContentType(.telephoneNumber)
                    .keyboardType(.phonePad)
            }
            Section("Address") {
                TextField("Street address", text: $addressLine1)
                    .textContentType(.streetAddressLine1)
                TextField("Apt / Suite (optional)", text: $addressLine2)
                    .textContentType(.streetAddressLine2)
                TextField("City", text: $city)
                    .textContentType(.addressCity)
                TextField("State / Region", text: $state)
                    .textContentType(.addressState)
                TextField("ZIP / Postal code", text: $zipCode)
                    .textContentType(.postalCode)
                TextField("Country", text: $country)
                    .textContentType(.countryName)
            }
            Section("Work") {
                TextField("Company", text: $company)
                    .textContentType(.organizationName)
                TextField("Job title", text: $jobTitle)
                    .textContentType(.jobTitle)
            }
            Section {
                Text("These fields are passed to the on-device AI when filling forms so it can autofill matching rows. The profile is stored locally and never leaves this device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button(role: .destructive) {
                    clearAll()
                } label: {
                    Label("Clear Profile", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Auto-Fill Profile")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func clearAll() {
        fullName = ""
        email = ""
        phone = ""
        addressLine1 = ""
        addressLine2 = ""
        city = ""
        state = ""
        zipCode = ""
        country = ""
        company = ""
        jobTitle = ""
    }
}

#Preview {
    NavigationStack {
        ProfileEditorView()
    }
}
