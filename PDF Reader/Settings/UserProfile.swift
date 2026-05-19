import Foundation

/// `UserDefaults`-backed user profile. Lightweight on purpose — just enough
/// info to autofill the common name/email/phone/address fields that appear
/// in 80% of PDF forms.
///
/// Stored as separate keys (rather than a SwiftData model) so each field
/// can be edited with `@AppStorage` and the profile stays out of the
/// CloudKit sync graph until we add encryption.
enum ProfileKeys {
    static let fullName = "profile.fullName"
    static let email = "profile.email"
    static let phone = "profile.phone"
    static let addressLine1 = "profile.addressLine1"
    static let addressLine2 = "profile.addressLine2"
    static let city = "profile.city"
    static let state = "profile.state"
    static let zipCode = "profile.zipCode"
    static let country = "profile.country"
    static let company = "profile.company"
    static let jobTitle = "profile.jobTitle"
}

struct UserProfile {
    var fullName: String
    var email: String
    var phone: String
    var addressLine1: String
    var addressLine2: String
    var city: String
    var state: String
    var zipCode: String
    var country: String
    var company: String
    var jobTitle: String

    static func load() -> UserProfile {
        let defaults = UserDefaults.standard
        return UserProfile(
            fullName: defaults.string(forKey: ProfileKeys.fullName) ?? "",
            email: defaults.string(forKey: ProfileKeys.email) ?? "",
            phone: defaults.string(forKey: ProfileKeys.phone) ?? "",
            addressLine1: defaults.string(forKey: ProfileKeys.addressLine1) ?? "",
            addressLine2: defaults.string(forKey: ProfileKeys.addressLine2) ?? "",
            city: defaults.string(forKey: ProfileKeys.city) ?? "",
            state: defaults.string(forKey: ProfileKeys.state) ?? "",
            zipCode: defaults.string(forKey: ProfileKeys.zipCode) ?? "",
            country: defaults.string(forKey: ProfileKeys.country) ?? "",
            company: defaults.string(forKey: ProfileKeys.company) ?? "",
            jobTitle: defaults.string(forKey: ProfileKeys.jobTitle) ?? ""
        )
    }

    /// True if the user has filled in at least one identity-bearing field.
    var hasContent: Bool {
        !fullName.isEmpty
            || !email.isEmpty
            || !phone.isEmpty
            || !addressLine1.isEmpty
            || !city.isEmpty
            || !company.isEmpty
            || !jobTitle.isEmpty
    }

    /// Plain-text rendering suitable for injecting into an LLM prompt. Only
    /// includes fields the user has actually filled in.
    var promptText: String {
        var lines: [String] = []
        if !fullName.isEmpty { lines.append("Name: \(fullName)") }
        if !email.isEmpty { lines.append("Email: \(email)") }
        if !phone.isEmpty { lines.append("Phone: \(phone)") }
        if !addressLine1.isEmpty { lines.append("Street: \(addressLine1)") }
        if !addressLine2.isEmpty { lines.append("Street (line 2): \(addressLine2)") }
        let regional = [city, state, zipCode].filter { !$0.isEmpty }.joined(separator: ", ")
        if !regional.isEmpty { lines.append("City / State / ZIP: \(regional)") }
        if !country.isEmpty { lines.append("Country: \(country)") }
        if !company.isEmpty { lines.append("Company: \(company)") }
        if !jobTitle.isEmpty { lines.append("Job title: \(jobTitle)") }
        return lines.joined(separator: "\n")
    }
}
