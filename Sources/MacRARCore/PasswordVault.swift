import Foundation
import Security

/// Parola yöneticisinde saklanan bir parola.
public struct SavedPassword: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var password: String
    public var lastUsed: Date?
    /// İsteğe bağlı ipucu/not (örn. "Muhasebe 2024 arşivleri"). Eski kayıtlarda yoktur.
    public var hint: String?

    public init(id: UUID = UUID(), name: String, password: String, lastUsed: Date? = nil, hint: String? = nil) {
        self.id = id
        self.name = name
        self.password = password
        self.lastUsed = lastUsed
        self.hint = hint
    }
}

public enum PasswordVaultError: LocalizedError, Sendable {
    case keychain(OSStatus)
    case corrupted

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? String(localized: "kod \(status)")
            return String(localized: "Anahtar Zinciri hatası: \(msg)")
        case .corrupted:
            return String(localized: "Kayıtlı parola listesi okunamadı (bozuk veri).")
        }
    }
}

/// Parola listesinin saklandığı yer. Tüm liste tek parça olarak okunur/yazılır.
public protocol PasswordStoring: Sendable {
    func load() throws -> [SavedPassword]
    func save(_ items: [SavedPassword]) throws
}

/// macOS Anahtar Zinciri'nde **tek bir öğe** olarak (JSON) saklar.
///
/// Neden tek öğe: macOS'un klasik anahtar zinciri birden çok öğeyi parolalarıyla birlikte toplu
/// okumaya izin vermez; öğe başına okumak ise her biri için ayrı izin penceresi demektir.
/// Not: Uygulama ad-hoc imzalı olduğundan, uygulama yeniden derlenince macOS bir kez daha
/// "Anahtar Zinciri'ne erişim" onayı isteyebilir ("Her Zaman İzin Ver" ile kalıcı olur).
public final class KeychainPasswordStore: PasswordStoring {
    private let service: String
    private let account: String

    public init(service: String = "local.macrar.password-manager", account: String = "vault") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() throws -> [SavedPassword] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw PasswordVaultError.keychain(status) }
        guard let data = out as? Data else { throw PasswordVaultError.corrupted }
        do { return try JSONDecoder().decode([SavedPassword].self, from: data) }
        catch { throw PasswordVaultError.corrupted }
    }

    public func save(_ items: [SavedPassword]) throws {
        let data = try JSONEncoder().encode(items)
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw PasswordVaultError.keychain(update) }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "MacRAR kayıtlı arşiv parolaları"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw PasswordVaultError.keychain(status) }
    }

    /// Öğeyi tamamen siler (testler / sıfırlama için).
    public func destroy() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// Testler için bellek içi depo.
public final class InMemoryPasswordStore: PasswordStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SavedPassword]
    public init(_ items: [SavedPassword] = []) { self.items = items }
    public func load() throws -> [SavedPassword] { lock.lock(); defer { lock.unlock() }; return items }
    public func save(_ items: [SavedPassword]) throws { lock.lock(); self.items = items; lock.unlock() }
}
