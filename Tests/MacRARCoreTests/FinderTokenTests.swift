import XCTest
@testable import MacRARCore

final class FinderTokenTests: XCTestCase {
    var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("macrar-token-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    func perms(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testGeneratedTokensAreRandomAndWellFormed() {
        let tokens = (0..<50).map { _ in FinderToken.generate() }
        XCTAssertEqual(Set(tokens).count, 50, "her üretim farklı olmalı")
        for t in tokens { XCTAssertTrue(FinderToken.isValid(t), t); XCTAssertEqual(t.count, 64) }
    }

    func testEnsureCreatesPrivateFileOnce() throws {
        XCTAssertNil(FinderToken.read(home: home), "başta anahtar yok")
        let first = try FinderToken.ensureExists(home: home)
        XCTAssertTrue(FinderToken.isValid(first))
        XCTAssertEqual(FinderToken.read(home: home), first)
        XCTAssertEqual(try perms(FinderToken.fileURL(home: home)), 0o600, "dosya yalnızca sahibine açık olmalı")
        XCTAssertEqual(try perms(FinderToken.directoryURL(home: home)), 0o700, "klasör yalnızca sahibine açık olmalı")
        // ikinci çağrı aynı anahtarı korur (güncellemelerde değişmez)
        XCTAssertEqual(try FinderToken.ensureExists(home: home), first)
    }

    func testTwoInstallationsGetDifferentTokens() throws {
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("macrar-token-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: other) }
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertNotEqual(try FinderToken.ensureExists(home: home), try FinderToken.ensureExists(home: other),
                          "her kurulum/kullanıcı ayrı anahtar almalı")
    }

    func testCorruptedOrWeakTokensAreReplaced() throws {
        let dir = FinderToken.directoryURL(home: home)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for bad in ["", "kısa", String(repeating: "A", count: 64), String(repeating: "g", count: 64), String(repeating: "a", count: 63)] {
            try bad.write(to: FinderToken.fileURL(home: home), atomically: true, encoding: .utf8)
            XCTAssertNil(FinderToken.read(home: home), "geçersiz anahtar okunmamalı: \(bad.prefix(8))")
            let fresh = try FinderToken.ensureExists(home: home)
            XCTAssertTrue(FinderToken.isValid(fresh))
            XCTAssertNotEqual(fresh, bad)
        }
    }

    func testWideOpenPermissionsAreRepaired() throws {
        let t = try FinderToken.ensureExists(home: home)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: FinderToken.fileURL(home: home).path)
        XCTAssertEqual(try FinderToken.ensureExists(home: home), t, "anahtar korunur")
        XCTAssertEqual(try perms(FinderToken.fileURL(home: home)), 0o600, "izinler onarılır")
    }

    func testTrailingNewlineIsTolerated() throws {
        let t = FinderToken.generate()
        try FileManager.default.createDirectory(at: FinderToken.directoryURL(home: home), withIntermediateDirectories: true)
        try (t + "\n").write(to: FinderToken.fileURL(home: home), atomically: true, encoding: .utf8)
        XCTAssertEqual(FinderToken.read(home: home), t)
    }

    func testRealHomeIsNotAContainer() {
        XCTAssertFalse(FinderToken.realHome().path.contains("/Library/Containers/"))
        XCTAssertTrue(FinderToken.realHome().path.hasPrefix("/Users/") || FinderToken.realHome().path.hasPrefix("/var/"))
    }
}
