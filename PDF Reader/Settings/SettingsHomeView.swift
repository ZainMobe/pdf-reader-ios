import SwiftUI
import PDFKit
import StoreKit

/// SettingsHomeView — App preferences, subscription status, sync, and about.
struct SettingsHomeView: View {
    @State private var showingPaywall = false
    @State private var showingManageSubscription = false
    private let entitlements = EntitlementStore.shared

    @AppStorage(AppSettings.defaultDisplayMode)
    private var displayModeRaw: Int = PDFDisplayMode.singlePageContinuous.rawValue

    @AppStorage(AppSettings.defaultDisplayDirection)
    private var displayDirectionRaw: Int = PDFDisplayDirection.vertical.rawValue

    @AppStorage(AppSettings.highlightColor)
    private var highlightColorRaw: String = HighlightColor.yellow.rawValue

    var body: some View {
        NavigationStack {
            Form {
                Section("Subscription") {
                    LabeledContent("Plan", value: entitlements.isPro ? "Pro" : "Free")
                    if entitlements.isPro {
                        Button {
                            showingManageSubscription = true
                        } label: {
                            Label("Manage Subscription", systemImage: "creditcard")
                        }
                    } else {
                        Button {
                            showingPaywall = true
                        } label: {
                            Label("Upgrade to Pro", systemImage: "sparkles")
                        }
                    }
                }
                Section("Sync") {
                    NavigationLink {
                        SyncStatusView()
                    } label: {
                        Label("Cloud Storage", systemImage: "icloud")
                    }
                }
                Section("Profile") {
                    NavigationLink {
                        ProfileEditorView()
                    } label: {
                        Label("Auto-Fill Profile", systemImage: "person.text.rectangle")
                    }
                }
                Section("Signatures") {
                    NavigationLink {
                        SignatureManagerView()
                    } label: {
                        Label("Manage Signatures", systemImage: "signature")
                    }
                }
                Section("Reading") {
                    Picker("Page Mode", selection: $displayModeRaw) {
                        Text("Single Page").tag(PDFDisplayMode.singlePage.rawValue)
                        Text("Continuous").tag(PDFDisplayMode.singlePageContinuous.rawValue)
                        Text("Two Up").tag(PDFDisplayMode.twoUp.rawValue)
                        Text("Two Up Continuous").tag(PDFDisplayMode.twoUpContinuous.rawValue)
                    }
                    Picker("Scroll Direction", selection: $displayDirectionRaw) {
                        Text("Vertical").tag(PDFDisplayDirection.vertical.rawValue)
                        Text("Horizontal").tag(PDFDisplayDirection.horizontal.rawValue)
                    }
                }
                Section("Markup") {
                    Picker("Highlight Color", selection: $highlightColorRaw) {
                        ForEach(HighlightColor.allCases) { color in
                            HStack {
                                Circle()
                                    .fill(color.color)
                                    .frame(width: 14, height: 14)
                                Text(color.displayName)
                            }
                            .tag(color.rawValue)
                        }
                    }
                }
                Section("AI") {
                    LabeledContent("Engine", value: "On-device")
                    Text("All AI features run locally on this device using Apple's Foundation Models. Nothing leaves your device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Legal") {
                    Link(destination: URL(string: "https://propdfeditor.online/terms.html")!) {
                        Label("Terms of Service", systemImage: "doc.text")
                    }
                    Link(destination: URL(string: "https://propdfeditor.online/privacy.html")!) {
                        Label("Privacy Policy", systemImage: "lock.shield")
                    }
                }
                Section("About") {
                    LabeledContent("Version", value: "1.0.0 (1)")
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingPaywall) {
                PaywallView()
            }
            .manageSubscriptionsSheet(isPresented: $showingManageSubscription)
        }
    }
}

#Preview {
    SettingsHomeView()
}
