import XCTest
@testable import MacRARCore

/// Mevcut ZIP arşivini düzenleme (ekleme / silme / yeniden adlandırma): parolasız ve parolalı (AES-256).
final class ZipEditingTests: XCTestCase {
    var tmp: URL!
    var service: ArchiveService!
    var tools: ToolPaths!
    let fm = FileManager.default

    override func setUpWithError() throws {
        tools = TestTools.paths()
        try XCTSkipUnless(tools.bsdtar != nil, "bsdtar yok")
        service = ArchiveService(tools: tools)
        tmp = fm.temporaryDirectory.appendingPathComponent("macrar-zipedit-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { if let tmp { try? fm.removeItem(at: tmp) } }

    // MARK: Yardımcılar

    @discardableResult
    func write(_ text: String, _ rel: String, under base: URL) throws -> URL {
        let url = base.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// src/{a.txt, klasör/b.txt, klasör/alt/c.txt, tuhaf[1]*.txt, link -> a.txt}; ZIP olarak paketlenir.
    func makeZip(password: String? = nil) async throws -> URL {
        let src = tmp.appendingPathComponent("src", isDirectory: true)
        try write("A", "a.txt", under: src)
        try write("B", "klasör/b.txt", under: src)
        try write("C", "klasör/alt/c.txt", under: src)
        try write("W", "tuhaf[1]*.txt", under: src)
        try fm.createSymbolicLink(at: src.appendingPathComponent("link"), withDestinationURL: URL(fileURLWithPath: "a.txt"))
        let archive = tmp.appendingPathComponent("test.zip")
        let items = try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)
        var o = CompressOptions(archive: archive, sources: items)
        o.format = .zip
        o.password = password
        try await service.add(o)
        return archive
    }

    func paths(_ archive: URL, password: String? = nil) async throws -> Set<String> {
        Set(try await service.list(archive: archive, password: password).entries.map(\.path))
    }

    func content(_ archive: URL, _ path: String, password: String? = nil) async throws -> String {
        let out = tmp.appendingPathComponent("out-\(UUID().uuidString)")
        let entry = try await service.list(archive: archive, password: password).entries.first { $0.path == path }
        let e = try XCTUnwrap(entry, "arşivde yok: \(path)")
        try await service.extract(archive: archive, selection: [e], options: ExtractOptions(destination: out), password: password)
        return try String(contentsOf: out.appendingPathComponent(path), encoding: .utf8)
    }

    func entry(_ archive: URL, _ path: String, password: String? = nil) async throws -> ArchiveEntry {
        let all = try await service.list(archive: archive, password: password).entries
        return try XCTUnwrap(all.first { $0.path == path }, "arşivde yok: \(path)")
    }

    func addOptions(_ archive: URL, _ sources: [URL], password: String? = nil, folder: String = "") -> CompressOptions {
        var o = CompressOptions(archive: archive, sources: sources)
        o.format = .zip
        o.appendToExisting = true
        o.password = password
        o.pathInArchive = folder
        return o
    }

    func assertNoLeftovers(file: StaticString = #filePath, line: UInt = #line) throws {
        let names = try fm.contentsOfDirectory(atPath: tmp.path)
        XCTAssertFalse(names.contains { $0.contains("macrar-") && $0.hasSuffix(".tmp") }, "\(names)", file: file, line: line)
    }

    // MARK: Parolasız

    func testIsZIPDetectsByContent() async throws {
        let zip = try await makeZip()
        XCTAssertTrue(ArchiveService.isZIP(zip))
        XCTAssertFalse(ArchiveService.isZIP(tmp.appendingPathComponent("src/a.txt")))
    }

    func testDeleteFileAndFolderAndOddName() async throws {
        let zip = try await makeZip()
        let before = try await paths(zip)
        XCTAssertTrue(before.contains("tuhaf[1]*.txt"))

        let doomed = [try await entry(zip, "a.txt"), try await entry(zip, "klasör"), try await entry(zip, "tuhaf[1]*.txt")]
        try await service.delete(from: zip, entries: doomed)
        let after = try await paths(zip)
        XCTAssertEqual(after, ["link"], "\(after)")
        try assertNoLeftovers()
    }

    func testDeleteDoesNotTouchSimilarNames() async throws {
        let zip = try await makeZip()
        let extra = try write("X", "klasör2/x.txt", under: tmp.appendingPathComponent("more"))
        try await service.add(addOptions(zip, [extra.deletingLastPathComponent()]))
        try await service.delete(from: zip, entries: [try await entry(zip, "klasör")])
        let after = try await paths(zip)
        XCTAssertFalse(after.contains("klasör/b.txt"))
        XCTAssertTrue(after.contains("klasör2/x.txt"), "\(after)")
        XCTAssertTrue(after.contains("a.txt"))
    }

    func testDeleteEverythingLeavesValidEmptyZip() async throws {
        let zip = try await makeZip()
        let all = try await service.list(archive: zip).entries
        try await service.delete(from: zip, entries: all)
        let after = try await paths(zip)
        XCTAssertTrue(after.isEmpty)
        XCTAssertTrue(ArchiveService.isZIP(zip))
        // Boş ZIP'e yeniden ekleme çalışmalı
        let f = try write("yeni", "y.txt", under: tmp.appendingPathComponent("n"))
        try await service.add(addOptions(zip, [f]))
        let afterAdd = try await paths(zip)
        XCTAssertEqual(afterAdd, ["y.txt"])
    }

    func testRenameFileAndFolder() async throws {
        let zip = try await makeZip()
        try await service.rename(in: zip, entry: try await entry(zip, "a.txt"), newPath: "z.txt")
        try await service.rename(in: zip, entry: try await entry(zip, "klasör"), newPath: "dizin")
        let after = try await paths(zip)
        XCTAssertTrue(after.isSuperset(of: ["z.txt", "dizin", "dizin/b.txt", "dizin/alt", "dizin/alt/c.txt", "link", "tuhaf[1]*.txt"]), "\(after)")
        XCTAssertFalse(after.contains("a.txt"))
        XCTAssertFalse(after.contains("klasör/b.txt"))
        let c = try await content(zip, "dizin/alt/c.txt")
        XCTAssertEqual(c, "C")
        // Sembolik bağlantının hedefi değişmemeli (yeniden adlandırılan dosyayı gösterse bile)
        let link = try await entry(zip, "link")
        XCTAssertTrue(link.isSymlink)
        let listing = try await service.list(archive: zip)
        XCTAssertEqual(listing.entries.filter { $0.path == "z.txt" }.count, 1)
        try assertNoLeftovers()
    }

    func testRenameNestedAndSpecialCharacters() async throws {
        let zip = try await makeZip()
        try await service.rename(in: zip, entry: try await entry(zip, "klasör/alt"), newPath: "klasör/yeni & [ad]")
        try await service.rename(in: zip, entry: try await entry(zip, "tuhaf[1]*.txt"), newPath: "düz.txt")
        let after = try await paths(zip)
        XCTAssertTrue(after.contains("klasör/yeni & [ad]/c.txt"), "\(after)")
        XCTAssertTrue(after.contains("düz.txt"))
        XCTAssertFalse(after.contains("tuhaf[1]*.txt"))
    }

    func testRenameToExistingNameFails() async throws {
        let zip = try await makeZip()
        let sizeBefore = try fm.attributesOfItem(atPath: zip.path)[.size] as? Int
        do {
            try await service.rename(in: zip, entry: try await entry(zip, "a.txt"), newPath: "klasör")
            XCTFail("hata beklenirdi")
        } catch let e as ArchiveError {
            guard case .unsupported = e else { return XCTFail("\(e)") }
        }
        XCTAssertEqual(try fm.attributesOfItem(atPath: zip.path)[.size] as? Int, sizeBefore)
    }

    func testAddAtRootReplacesSameNameWithoutDuplicates() async throws {
        let zip = try await makeZip()
        let newA = try write("YENİ A", "a.txt", under: tmp.appendingPathComponent("incoming"))
        let n = try write("N", "n.txt", under: tmp.appendingPathComponent("incoming"))
        let tracker = await ProgressTracker.forAdding(addOptions(zip, [newA, n]))
        try await service.add(addOptions(zip, [newA, n]), tracker: tracker)

        let listing = try await service.list(archive: zip)
        XCTAssertEqual(listing.entries.filter { $0.path == "a.txt" }.count, 1, "yinelenen girdi")
        let a = try await content(zip, "a.txt")
        let nn = try await content(zip, "n.txt")
        XCTAssertEqual(a, "YENİ A")
        XCTAssertEqual(nn, "N")
        let b = try await content(zip, "klasör/b.txt")
        XCTAssertEqual(b, "B")
        XCTAssertEqual(tracker.drain().fraction ?? 0, 1.0, accuracy: 0.01)
        try assertNoLeftovers()
    }

    func testAddFolderMergesWithExistingFolder() async throws {
        let zip = try await makeZip()
        let incoming = tmp.appendingPathComponent("incoming/klasör", isDirectory: true)
        try write("B2", "b.txt", under: incoming)
        try write("D", "d.txt", under: incoming)
        try await service.add(addOptions(zip, [incoming]))

        let listing = try await service.list(archive: zip)
        XCTAssertEqual(listing.entries.filter { $0.path == "klasör" }.count, 1, "klasör girdisi yinelendi")
        XCTAssertEqual(listing.entries.filter { $0.path == "klasör/b.txt" }.count, 1)
        let b = try await content(zip, "klasör/b.txt")
        let d = try await content(zip, "klasör/d.txt")
        let c = try await content(zip, "klasör/alt/c.txt")
        XCTAssertEqual(b, "B2")
        XCTAssertEqual(d, "D")
        XCTAssertEqual(c, "C", "eskiden olup yeni klasörde bulunmayan dosya korunmalı")
    }

    func testAddIntoSubfolderOfArchive() async throws {
        let zip = try await makeZip()
        let f = try write("içerik", "yeni dosya.txt", under: tmp.appendingPathComponent("incoming"))
        let d = tmp.appendingPathComponent("incoming/kl", isDirectory: true)
        try write("1", "x.txt", under: d)
        try await service.add(addOptions(zip, [f, d], folder: "klasör/alt"))
        let after = try await paths(zip)
        XCTAssertTrue(after.contains("klasör/alt/yeni dosya.txt"), "\(after)")
        XCTAssertTrue(after.contains("klasör/alt/kl/x.txt"))
        XCTAssertTrue(after.contains("klasör/alt/c.txt"))
        XCTAssertFalse(after.contains("yeni dosya.txt"))
        XCTAssertFalse(after.contains { $0.hasPrefix("macrar-new") }, "\(after)")
        let t = try await content(zip, "klasör/alt/yeni dosya.txt")
        XCTAssertEqual(t, "içerik")
    }

    func testAddIntoSubfolderWithSpecialCharactersAndReplace() async throws {
        let zip = try await makeZip()
        let f = try write("v1", "p.txt", under: tmp.appendingPathComponent("i1"))
        try await service.add(addOptions(zip, [f], folder: "a & b|c#1"))
        let f2 = try write("v2", "p.txt", under: tmp.appendingPathComponent("i2"))
        try await service.add(addOptions(zip, [f2], folder: "a & b|c#1"))
        let listing = try await service.list(archive: zip)
        XCTAssertEqual(listing.entries.filter { $0.path == "a & b|c#1/p.txt" }.count, 1, "\(listing.entries.map(\.path))")
        let p = try await content(zip, "a & b|c#1/p.txt")
        XCTAssertEqual(p, "v2")
    }

    func testAddKeepsSymlinksAndOldEntriesUntouched() async throws {
        let zip = try await makeZip()
        let f = try write("n", "n.txt", under: tmp.appendingPathComponent("i"))
        try await service.add(addOptions(zip, [f]))
        let link = try await entry(zip, "link")
        XCTAssertTrue(link.isSymlink)
        let b = try await content(zip, "klasör/b.txt")
        XCTAssertEqual(b, "B")
    }

    func testAddDeleteAfterRemovesSources() async throws {
        let zip = try await makeZip()
        let f = try write("n", "silinecek.txt", under: tmp.appendingPathComponent("i"))
        var o = addOptions(zip, [f])
        o.deleteAfter = true
        try await service.add(o)
        XCTAssertFalse(fm.fileExists(atPath: f.path))
        let after = try await paths(zip)
        XCTAssertTrue(after.contains("silinecek.txt"))
    }

    func testAddLargeFileProgressAndIntegrity() async throws {
        let zip = try await makeZip()
        let big = tmp.appendingPathComponent("incoming/big.bin")
        try fm.createDirectory(at: big.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try data.write(to: big)
        try await service.add(addOptions(zip, [big]))
        let out = tmp.appendingPathComponent("out-big")
        let e = try await entry(zip, "big.bin")
        try await service.extract(archive: zip, selection: [e], options: ExtractOptions(destination: out))
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("big.bin")), data)
    }

    func testAddToNonZipFileIsRejected() async throws {
        let notZip = try write("düz metin", "x.zip", under: tmp)
        let f = try write("n", "n.txt", under: tmp.appendingPathComponent("i"))
        do {
            try await service.add(addOptions(notZip, [f]))
            XCTFail("hata beklenirdi")
        } catch {}
        XCTAssertEqual(try String(contentsOf: notZip, encoding: .utf8), "düz metin")
    }

    func testCreatingNewZipStillOverwrites() async throws {
        let zip = try await makeZip()
        let f = try write("n", "yalniz.txt", under: tmp.appendingPathComponent("i"))
        var o = CompressOptions(archive: zip, sources: [f])
        o.format = .zip
        try await service.add(o)
        let after = try await paths(zip)
        XCTAssertEqual(after, ["yalniz.txt"])
    }

    // MARK: Parolalı (AES-256)

    func testEncryptedAddDeleteRenameKeepEncryptionAndContent() async throws {
        let pw = "şifre-ğüş 123"
        let zip = try await makeZip(password: pw)
        // ekle (aynı adlıyı değiştir + klasöre)
        let newA = try write("YENİ A", "a.txt", under: tmp.appendingPathComponent("i"))
        let deep = try write("derin", "d.txt", under: tmp.appendingPathComponent("i2"))
        try await service.add(addOptions(zip, [newA], password: pw))
        try await service.add(addOptions(zip, [deep], password: pw, folder: "klasör/alt"))
        // yeniden adlandır + sil
        try await service.rename(in: zip, entry: try await entry(zip, "klasör", password: pw), newPath: "dizin", password: pw)
        try await service.delete(from: zip, entries: [try await entry(zip, "tuhaf[1]*.txt", password: pw)], password: pw)

        let after = try await paths(zip, password: pw)
        XCTAssertTrue(after.isSuperset(of: ["a.txt", "dizin/b.txt", "dizin/alt/c.txt", "dizin/alt/d.txt", "link"]), "\(after)")
        XCTAssertFalse(after.contains("tuhaf[1]*.txt"))
        let a = try await content(zip, "a.txt", password: pw)
        let d = try await content(zip, "dizin/alt/d.txt", password: pw)
        XCTAssertEqual(a, "YENİ A")
        XCTAssertEqual(d, "derin")

        // Hâlâ şifreli mi: parolasız çıkarma başarısız olmalı
        let out = tmp.appendingPathComponent("noPw")
        do {
            try await service.extract(archive: zip, selection: nil, options: ExtractOptions(destination: out))
            let leaked = try? String(contentsOf: out.appendingPathComponent("a.txt"), encoding: .utf8)
            XCTAssertNotEqual(leaked, "YENİ A", "arşiv şifresiz kaydedilmiş")
        } catch {}
        try assertNoLeftovers()
    }

    func testEncryptedWrongPasswordLeavesArchiveIntact() async throws {
        let zip = try await makeZip(password: "dogru")
        let before = try Data(contentsOf: zip)
        let f = try write("n", "n.txt", under: tmp.appendingPathComponent("i"))
        do {
            try await service.add(addOptions(zip, [f], password: "yanlis"))
            XCTFail("hata beklenirdi")
        } catch ArchiveError.wrongPassword {} catch ArchiveError.passwordRequired {} catch { XCTFail("\(error)") }
        XCTAssertEqual(try Data(contentsOf: zip), before)
        try assertNoLeftovers()
    }

    func testEncryptedDeleteEverything() async throws {
        let pw = "p"
        let zip = try await makeZip(password: pw)
        let all = try await service.list(archive: zip, password: pw).entries
        try await service.delete(from: zip, entries: all, password: pw)
        let after = try await paths(zip, password: pw)
        XCTAssertTrue(after.isEmpty)
    }

    /// Hata raporu: AES şifreli ZIP parolasız açılabildiğinden (adlar şifresiz) ekleme parolasız kopyalama yoluna giriyor ve
    /// bsdtar sonsuz "Enter passphrase" yazıyordu. Artık parola istenmeli, arşiv değişmemeli.
    func testEncryptedZipEditsWithoutPasswordAskForPasswordInsteadOfLooping() async throws {
        let zip = try await makeZip(password: "gizli")
        let before = try Data(contentsOf: zip)
        let f = try write("n", "n.txt", under: tmp.appendingPathComponent("i"))
        let start = Date()

        do { try await service.add(addOptions(zip, [f])); XCTFail("parola istenmeliydi") }
        catch ArchiveError.passwordRequired {} catch { XCTFail("add: \(error)") }
        do { try await service.delete(from: zip, entries: [try await entry(zip, "a.txt")]); XCTFail("parola istenmeliydi") }
        catch ArchiveError.passwordRequired {} catch { XCTFail("delete: \(error)") }
        do { try await service.rename(in: zip, entry: try await entry(zip, "a.txt"), newPath: "z.txt"); XCTFail("parola istenmeliydi") }
        catch ArchiveError.passwordRequired {} catch { XCTFail("rename: \(error)") }

        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "döngüye girmemeli")
        XCTAssertEqual(try Data(contentsOf: zip), before, "arşiv değişmemeli")
        try assertNoLeftovers()
    }

    func testEmptyPasswordStringIsTreatedAsNoPassword() async throws {
        let zip = try await makeZip(password: "gizli")
        let f = try write("n", "n.txt", under: tmp.appendingPathComponent("i"))
        do { try await service.add(addOptions(zip, [f], password: "")); XCTFail("parola istenmeliydi") }
        catch ArchiveError.passwordRequired {} catch { XCTFail("\(error)") }
    }

    func testUnencryptedZipStillEditsWithoutPassword() async throws {
        let zip = try await makeZip()
        let f = try write("n", "n.txt", under: tmp.appendingPathComponent("i"))
        try await service.add(addOptions(zip, [f]))
        let after = try await paths(zip)
        XCTAssertTrue(after.contains("n.txt"))
    }
}
