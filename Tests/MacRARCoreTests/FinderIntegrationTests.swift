import XCTest
@testable import MacRARCore

final class FinderIntegrationTests: XCTestCase {
    func url(_ p: String) -> URL { URL(fileURLWithPath: p) }

    func testMenuForSingleArchive() {
        let m = FinderIntegration.menuItems(for: [url("/Users/x/İndirilenler/proje.rar")])
        XCTAssertEqual(m.map(\.action), [.open, .extractDialog, .extractHere, .extractFolder])
        XCTAssertTrue(m[3].title.contains("“proje/”"), m[3].title)
        XCTAssertTrue(m.allSatisfy { $0.title.hasPrefix("MacRAR · ") })
    }

    func testMenuForTarGzUsesBaseWithoutTar() {
        let m = FinderIntegration.menuItems(for: [url("/a/yedek.tar.gz")])
        XCTAssertTrue(m.last!.title.contains("“yedek/”"), m.last!.title)
    }

    func testMenuForMultipleArchives() {
        let m = FinderIntegration.menuItems(for: [url("/a/1.rar"), url("/a/2.zip")])
        XCTAssertEqual(m.last?.title, "MacRAR · Her birini kendi klasörüne Çıkar")
    }

    func testMenuForFolderAndFile() {
        let folder = URL(fileURLWithPath: "/Users/x/Fotoğraflar", isDirectory: true)
        let m = FinderIntegration.menuItems(for: [folder])
        XCTAssertEqual(m.map(\.action), [.add, .compress, .compressStamped, .compressZip, .compressZipStamped])
        XCTAssertEqual(m[1].title, "MacRAR · “Fotoğraflar.rar” olarak Sıkıştır")
        XCTAssertEqual(m[3].title, "MacRAR · “Fotoğraflar.zip” olarak Sıkıştır")
        XCTAssertEqual(m[4].title, "MacRAR · Zaman Damgalı ZIP’e Sıkıştır")

        let file = URL(fileURLWithPath: "/Users/x/rapor.final.pdf", isDirectory: false)
        XCTAssertEqual(FinderIntegration.menuItems(for: [file])[1].title, "MacRAR · “rapor.final.rar” olarak Sıkıştır")

        let multi = FinderIntegration.menuItems(for: [folder, file])
        XCTAssertEqual(multi[1].title, "MacRAR · RAR’a Sıkıştır")
        XCTAssertEqual(multi[3].title, "MacRAR · ZIP’e Sıkıştır")
    }

    func testRarCompressItemsAreHiddenWithoutRarButZipAndArchiveActionsRemain() {
        let folder = URL(fileURLWithPath: "/Users/x/Fotoğraflar", isDirectory: true)
        let without = FinderIntegration.menuItems(for: [folder], canCompressRAR: false)
        XCTAssertEqual(without.map(\.action), [.add, .compressZip, .compressZipStamped])
        XCTAssertFalse(without.contains { $0.title.contains("RAR’a") || $0.title.contains(".rar”") }, "RAR sıkıştırma başlıkları görünmemeli")
        // Arşiv seçiliyken (çıkarma girdileri) rar'dan bağımsızdır.
        let archive = FinderIntegration.menuItems(for: [url("/a/x.rar")], canCompressRAR: false)
        XCTAssertEqual(archive.map(\.action), [.open, .extractDialog, .extractHere, .extractFolder])
    }

    func testMixedArchiveAndFileShowsCompressGroup() {
        let m = FinderIntegration.menuItems(for: [url("/a/x.rar"), url("/a/not.txt")])
        XCTAssertEqual(m.map(\.action), [.add, .compress, .compressStamped, .compressZip, .compressZipStamped])
    }

    func testEmptySelectionHasNoMenu() {
        XCTAssertTrue(FinderIntegration.menuItems(for: []).isEmpty)
    }

    func testCommandURLRoundTripWithUnicodeSpacesAndSpecialChars() throws {
        let paths = ["/Users/x/Belgeler/rapor özet & final #1.pdf", "/Users/x/Klasör (kopya)/a=b?c.txt"]
        let u = try XCTUnwrap(FinderIntegration.commandURL(action: .compress, paths: paths, token: "T0K3N"))
        let parsed = try XCTUnwrap(FinderIntegration.parse(u, expectedToken: "T0K3N"))
        XCTAssertEqual(parsed.action, .compress)
        XCTAssertEqual(parsed.files.map(\.path), paths)
    }

    func testParseRejectsWrongOrMissingToken() throws {
        let u = try XCTUnwrap(FinderIntegration.commandURL(action: .extractHere, paths: ["/a/b.rar"], token: "dogru"))
        XCTAssertNil(FinderIntegration.parse(u, expectedToken: "yanlis"))
        XCTAssertNil(FinderIntegration.parse(u, expectedToken: nil), "anahtarsız (geliştirme) derlemede komut kabul edilmemeli")
        XCTAssertNil(FinderIntegration.parse(u, expectedToken: ""))
        let noToken = URL(string: "macrar://extractHere?p=/a/b.rar")!
        XCTAssertNil(FinderIntegration.parse(noToken, expectedToken: "dogru"))
    }

    /// Sistem URL ana makine adını küçültebilir ("extractHere" → "extracthere"); yine de çözülmeli.
    func testParseIsCaseInsensitiveForAction() throws {
        for a in FinderAction.allCases {
            let u = URL(string: "macrar://\(a.rawValue.lowercased())?t=k&p=/a/b")!
            XCTAssertEqual(FinderIntegration.parse(u, expectedToken: "k")?.action, a, a.rawValue)
        }
    }

    /// Eylemler sırasıyla etiketlenir; etiket → eylem eşlemesi eklentide kullanılıyor.
    func testActionTagsAreStableIndexes() {
        XCTAssertEqual(FinderAction.allCases.count, 9)
        // Eski eylemlerin sırası değişmemeli (eklenti etiketi sıraya dayanır): yenileri yalnızca sona eklenir.
        XCTAssertEqual(Array(FinderAction.allCases.prefix(7)),
                       [.add, .compress, .compressStamped, .open, .extractDialog, .extractHere, .extractFolder])
        for (i, a) in FinderAction.allCases.enumerated() { XCTAssertEqual(FinderAction.allCases[i], a) }
    }

    func testParseRejectsMalformedInput() throws {
        let t = "k"
        XCTAssertNil(FinderIntegration.parse(URL(string: "macrar://bilinmeyen?t=k&p=/a")!, expectedToken: t))
        XCTAssertNil(FinderIntegration.parse(URL(string: "macrar://compress?t=k")!, expectedToken: t), "yol yok")
        XCTAssertNil(FinderIntegration.parse(URL(string: "macrar://compress?t=k&p=goreli/yol")!, expectedToken: t), "göreli yol")
        XCTAssertNil(FinderIntegration.parse(URL(string: "https://compress?t=k&p=/a")!, expectedToken: t))
        // ".." bileşenleri temizlenir
        let ok = try XCTUnwrap(FinderIntegration.parse(URL(string: "macrar://compress?t=k&p=/a/b/../c.txt")!, expectedToken: t))
        XCTAssertEqual(ok.files.first?.path, "/a/c.txt")
    }

    // MARK: FinderState (uygulama → eklenti durum dosyası)

    private func tempHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("macrar-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: FinderToken.directoryURL(home: home), withIntermediateDirectories: true)
        return home
    }

    func testFinderStateRoundTripAndUnknownWhenMissing() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertNil(FinderState.readCanCompressRAR(home: home))
        XCTAssertTrue(FinderState.writeCanCompressRAR(true, home: home))
        XCTAssertEqual(FinderState.readCanCompressRAR(home: home), true)
        XCTAssertTrue(FinderState.writeCanCompressRAR(false, home: home))
        XCTAssertEqual(FinderState.readCanCompressRAR(home: home), false)
        try "çöp".write(to: FinderState.fileURL(home: home), atomically: true, encoding: .utf8)
        XCTAssertNil(FinderState.readCanCompressRAR(home: home), "bozuk dosya bilinmiyor sayılmalı")
    }

    func testFinderStateDoesNotCreateTheDirectory() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("macrar-nostate-\(UUID().uuidString)")
        XCTAssertFalse(FinderState.writeCanCompressRAR(true, home: home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: FinderToken.directoryURL(home: home).path),
                       "testler/ilk açılış öncesi kullanıcı klasörüne bir şey oluşturulmamalı")
    }

    func testOfferRARCompressionLogic() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let none: (String) -> Bool = { _ in false }
        XCTAssertFalse(FinderState.shouldOfferRARCompression(home: home, exists: none), "durum bilinmiyor + rar yok → gizle")
        FinderState.writeCanCompressRAR(false, home: home)
        XCTAssertFalse(FinderState.shouldOfferRARCompression(home: home, exists: none))
        FinderState.writeCanCompressRAR(true, home: home)
        XCTAssertTrue(FinderState.shouldOfferRARCompression(home: home, exists: none), "uygulama rar var dedi")
        FinderState.writeCanCompressRAR(false, home: home)
        XCTAssertTrue(FinderState.shouldOfferRARCompression(home: home, exists: { $0 == "/usr/local/bin/rar" }),
                      "uygulama kapalıyken rar sonradan kurulduysa menü görünmeli")
        XCTAssertTrue(FinderState.rarCandidatePaths(home: home).contains { $0.hasSuffix("MacRAR/tools/rar/rar") })
    }
}
