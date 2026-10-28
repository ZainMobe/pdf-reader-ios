import SwiftUI
import PDFKit
import StoreKit

/// SettingsHomeView — App preferences, subscription status, sync, and about.
struct SettingsHomeView: View {
    static let versionString: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }()

    @State private var showingPaywall = false
    @State private var showingManageSubscription = false
    private let entitlements = EntitlementStore.shared

    @AppStorage(AppSettings.defaultDisplayMode)
    private var displayModeRaw: Int = PDFDisplayMode.singlePageContinuous.rawValue

    @AppStorage(AppSettings.defaultDisplayDirection)
    private var displayDirectionRaw: Int = PDFDisplayDirection.vertical.rawValue

    @AppStorage(AppSettings.highlightColor)
    private var highlightColorRaw: String = HighlightColor.yellow.rawValue

    @AppStorage(AppSettings.aiProcessingMode)
    private var aiProcessingModeRaw: String = AIProcessingMode.automatic.rawValue

    @AppStorage(AppSettings.cloudAIConsent)
    private var cloudAIConsent = false

    @State private var analyticsEnabled = AppAnalytics.isCollectionEnabled

    private var aiFooter: String {
        guard AIEngine.isCloudConfigured else {
            return "All AI features run locally on this device using Apple's Foundation Models. Nothing leaves your device."
        }
        switch AIProcessingMode(rawValue: aiProcessingModeRaw) ?? .automatic {
        case .automatic:
            return "Uses Apple Intelligence on this device when available. Otherwise, with your permission, document text is sent to Claude (Anthropic) to generate results. It isn't used for training."
        case .onDeviceOnly:
            return "Nothing leaves your device. AI features need Apple Intelligence (iPhone 15 Pro or newer with iOS 26)."
        case .cloudOnly:
            return "Document text is sent to Claude (Anthropic) to generate results. Best quality, every language and long documents. It isn't used for training."
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Subscription") {
                    LabeledContent("Plan", value: entitlements.isPro ? "Pro" : "Free")
                    // Lifetime is a one-time purchase; the subscription
                    // management sheet would be empty for it.
                    if entitlements.isPro, entitlements.activeProductID != SubscriptionTier.lifetime.id {
                        Button {
                            AppAnalytics.settingChanged("manage_subscription", "opened")
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
                Section {
                    ShareLink(
                        item: AppLinks.appStore,
                        subject: Text("PDF Editor"),
                        message: Text("I use PDF Editor to scan, sign and edit PDFs on my iPhone, with on-device AI. Try it:")
                    ) {
                        Label("Invite Friends", systemImage: "person.2")
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        AppAnalytics.log(.inviteShared, [.source: AnalyticsSource.settings.rawValue])
                        AppAnalytics.feature(.invite, source: AnalyticsSource.settings.rawValue)
                    })
                    Link(destination: AppLinks.writeReview) {
                        Label("Rate PDF Editor", systemImage: "star")
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        AppAnalytics.log(.reviewPromptRequested, [.source: AnalyticsSource.settings.rawValue])
                    })
                } header: {
                    Text("Spread the word")
                } footer: {
                    if !entitlements.isPro {
                        // Reading `usageVersion` subscribes this view to
                        // allowance changes made elsewhere in the app.
                        let _ = entitlements.usageVersion
                        Text("Free plan: \(FreeTier.remaining(.aiAction)) AI actions, \(FreeTier.remaining(.tool)) Pro tools and \(FreeTier.remaining(.editing)) editing actions left today. Limits reset at midnight.")
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
                    if AIEngine.isCloudConfigured {
                        Picker("Processing", selection: $aiProcessingModeRaw) {
                            ForEach(AIProcessingMode.allCases) { mode in
                                Text(mode.displayName).tag(mode.rawValue)
                            }
                        }
                        Toggle("Allow Cloud AI", isOn: Binding(
                            get: { cloudAIConsent },
                            set: { value in
                                cloudAIConsent = value
                                AppAnalytics.settingChanged("cloud_ai_consent", value ? "on" : "off")
                            }
                        ))
                    }
                    LabeledContent("Active engine", value: AIEngine.availability().backend?.displayName ?? "Unavailable")
                    Text(aiFooter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Share Usage Analytics", isOn: $analyticsEnabled)
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Anonymous usage data, such as which screens and tools are used, helps us decide what to improve next. It never includes your documents, file names or anything you type.")
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
                    LabeledContent("Version", value: Self.versionString)
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingPaywall) {
                PaywallView(source: .settings)
            }
            .onChange(of: displayModeRaw) { _, value in
                AppAnalytics.settingChanged("default_page_mode", String(value))
            }
            .onChange(of: displayDirectionRaw) { _, value in
                AppAnalytics.settingChanged("default_scroll_direction", String(value))
            }
            .onChange(of: highlightColorRaw) { _, value in
                AppAnalytics.settingChanged("highlight_color", value)
            }
            .onChange(of: aiProcessingModeRaw) { _, value in
                AppAnalytics.settingChanged("ai_processing_mode", value)
                AnalyticsUserProperties.refreshEnvironment()
            }
            .onChange(of: cloudAIConsent) { _, _ in
                AnalyticsUserProperties.refreshEnvironment()
            }
            .onChange(of: analyticsEnabled) { _, value in
                if !value { AppAnalytics.settingChanged("usage_analytics", "off") }
                AppAnalytics.isCollectionEnabled = value
                if value { AppAnalytics.settingChanged("usage_analytics", "on") }
            }
            .manageSubscriptionsSheet(isPresented: $showingManageSubscription)
        }
        .trackScreen(.settings)
    }
}

#Preview {
    SettingsHomeView()
}

/// Public links for the app. One place to update if the listing moves.
enum AppLinks {
    static let appStoreID = "6770882043"
    static let appStore = URL(string: "https://apps.apple.com/app/id\(appStoreID)")!
    static let writeReview = URL(string: "https://apps.apple.com/app/id\(appStoreID)?action=write-review")!
}
