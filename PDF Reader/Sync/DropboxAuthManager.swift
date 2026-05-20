import Foundation
import UIKit
import SwiftyDropbox

/// Owns the Dropbox SDK lifecycle: reads the app key from Info.plist,
/// configures `DropboxClientsManager` at app launch, drives the OAuth
/// sign-in / sign-out flow, and exposes the authorized client to callers.
@MainActor
@Observable
final class DropboxAuthManager {
    static let shared = DropboxAuthManager()

    /// Whether the user currently has a valid Dropbox authorization.
    private(set) var isSignedIn: Bool

    /// Display name of the signed-in account, refreshed on sign-in.
    private(set) var accountName: String?

    /// True only when the app key in Info.plist has been replaced with a
    /// real value. Used by the UI to hide Dropbox surfaces when the dev
    /// hasn't finished configuring the integration yet.
    let isConfigured: Bool

    private let appKey: String

    private init() {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "DROPBOX_APP_KEY") as? String) ?? ""
        let configured = !raw.isEmpty && !raw.contains("REPLACE_WITH")
        self.isConfigured = configured
        self.appKey = configured ? raw : ""

        if configured {
            DropboxClientsManager.setupWithAppKey(raw)
        }
        self.isSignedIn = configured && DropboxClientsManager.authorizedClient != nil
    }

    /// Kicks off the PKCE OAuth flow. SwiftyDropbox decides whether to use
    /// the installed Dropbox app or fall back to an ASWebAuthenticationSession.
    func signIn(from presenter: UIViewController) {
        guard isConfigured else { return }
        let scopes = ["files.content.read", "files.content.write", "files.metadata.read", "account_info.read"]
        let scopeRequest = ScopeRequest(scopeType: .user, scopes: scopes, includeGrantedScopes: false)
        DropboxClientsManager.authorizeFromControllerV2(
            UIApplication.shared,
            controller: presenter,
            loadingStatusDelegate: nil,
            openURL: { url in UIApplication.shared.open(url, options: [:], completionHandler: nil) },
            scopeRequest: scopeRequest
        )
    }

    /// Processes a `db-<APP_KEY>://...` callback URL. Returns `true` if the
    /// URL was Dropbox's and was handled.
    @discardableResult
    func handleRedirect(_ url: URL) -> Bool {
        guard isConfigured else { return false }
        return DropboxClientsManager.handleRedirectURL(url, includeBackgroundClient: false) { [weak self] result in
            Task { @MainActor in
                self?.applyAuthResult(result)
            }
        }
    }

    /// Tears down the current session and clears keychain tokens.
    func signOut() {
        DropboxClientsManager.unlinkClients()
        isSignedIn = false
        accountName = nil
    }

    /// The authorized client, or `nil` if the user isn't signed in.
    var client: DropboxClient? {
        DropboxClientsManager.authorizedClient
    }

    private func applyAuthResult(_ result: DropboxOAuthResult?) {
        switch result {
        case .success:
            isSignedIn = DropboxClientsManager.authorizedClient != nil
            refreshAccount()
        case .cancel, .error, .none:
            isSignedIn = false
        }
    }

    private func refreshAccount() {
        guard let client = DropboxClientsManager.authorizedClient else { return }
        client.users.getCurrentAccount().response { [weak self] account, _ in
            Task { @MainActor in
                self?.accountName = account?.name.displayName
            }
        }
    }
}
