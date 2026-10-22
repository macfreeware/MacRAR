import XCTest
@testable import MacRARCore

final class PasswordVaultTests: XCTestCase {
    func testInMemoryRoundTrip() throws {
        let store = InMemoryPasswordStore()
        XCTAssertEqual(try store.load(), [])
        let item = SavedPassword(name: "Muhasebe", password: "gizli şifre ğüşiöç")
        try store.save([item])
        XCTAssertEqual(try store.load(), [item])
    }

    /// Gerçek Anahtar Zinciri: benzersiz bir servis adıyla yazar, okur, günceller ve siler.
    func testKeychainRoundTripWithUnicodeAndUpdate() throws {
        let store = KeychainPasswordStore(service: "macrar-test-\(UUID().uuidString)")
        defer { store.destroy() }
        do {
            XCTAssertEqual(try store.load(), [], "öğe yokken boş liste dönmeli")
            let a = SavedPassword(name: "A", password: "p@ss\"w'ord\n123 ğ", lastUsed: Date(timeIntervalSince1970: 1_700_000_000))
            try store.save([a])
            XCTAssertEqual(try store.load(), [a])
            let b = SavedPassword(name: "B", password: "ikinci")
            try store.save([a, b])               // güncelleme (yeni öğe eklenmez)
            XCTAssertEqual(try store.load(), [a, b])
            try store.save([])
            XCTAssertEqual(try store.load(), [])
        } catch PasswordVaultError.keychain(let status) where status == errSecInteractionNotAllowed || status == errSecNotAvailable {
            throw XCTSkip("Bu ortamda anahtar zinciri kullanılamıyor (\(status))")
        }
    }
}
