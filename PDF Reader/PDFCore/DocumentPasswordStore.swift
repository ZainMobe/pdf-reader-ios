import Foundation
import PDFKit
import Security

/// Remembers the password of every encrypted PDF the user has unlocked, so a
/// locked document is only ever asked about once.
///
/// Two deliberate choices:
///
///  * **The password lives in the Keychain**, not `UserDefaults`. The item is
///    `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so it survives
///    relaunches, is unavailable before the device is first unlocked, and never
///    leaves the device via iCloud Keychain or an encrypted backup.
///  * **The PDF on disk stays encrypted.** Opening a protected document to read
///    it must not silently strip its protection — that's the user's decision to
///    make, through Tools → Remove Password.
///
/// Keyed by filename rather than full path: the container URL changes between
/// installs, the `<uuid>.pdf` filename does not.
enum DocumentPasswordStore {

    private static let service = "com.wappltd.pdf.document-password"

    /// Keychain reads are a syscall each, and `PDFDocument.opened(at:)` runs on
    /// every thumbnail, search and AI pass. Memoise per launch.
    private static var cache: [String: String] = [:]
    private static var misses: Set<String> = []
    private static let lock = NSLock()

    // MARK: - Lookup

    /// The stored password for `url`, or nil if we've never unlocked it.
    static func password(for url: URL) -> String? {
        let key = url.lastPathComponent

        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        if misses.contains(key) {
            lock.unlock()
            return nil
        }
        lock.unlock()

        let found = readKeychain(key)

        lock.lock()
        if let found {
            cache[key] = found
        } else {
            misses.insert(key)
        }
        lock.unlock()

        return found
    }

    /// True when we hold a password for this document.
    static func hasPassword(for url: URL) -> Bool {
        password(for: url) != nil
    }

    // MARK: - Mutation

    /// Records the password that successfully unlocked `url`.
    static func store(_ password: String, for url: URL) {
        let key = url.lastPathComponent
        guard let data = password.data(using: .utf8) else { return }

        lock.lock()
        cache[key] = password
        misses.remove(key)
        lock.unlock()

        var query = baseQuery(key)
        let attributes: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    /// Forgets the password for `url`. Called when a document is deleted and
    /// after its protection is removed, so nothing lingers in the Keychain.
    static func remove(for url: URL) {
        let key = url.lastPathComponent

        lock.lock()
        cache.removeValue(forKey: key)
        misses.insert(key)
        lock.unlock()

        SecItemDelete(baseQuery(key) as CFDictionary)
    }

    // MARK: - Keychain plumbing

    private static func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    private static func readKeychain(_ key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard
            SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }

        return String(data: data, encoding: .utf8)
    }
}

// MARK: - PDFDocument

extension PDFDocument {

    /// Opens `url`, applying a previously-accepted password when the file is
    /// encrypted.
    ///
    /// This is the app's single entry point for reading a PDF off disk. Every
    /// call site — renderer, text search, thumbnails, AI, Tools — goes through
    /// it, which is what makes "enter the password once" hold everywhere rather
    /// than only in the Reader.
    ///
    /// A document we have no password for is still returned, locked; callers
    /// that care check `isLocked` as before.
    static func opened(at url: URL) -> PDFDocument? {
        guard let pdf = PDFDocument(url: url) else { return nil }
        guard pdf.isLocked else { return pdf }

        if let saved = DocumentPasswordStore.password(for: url) {
            _ = pdf.unlock(withPassword: saved)
        }
        return pdf
    }
}
