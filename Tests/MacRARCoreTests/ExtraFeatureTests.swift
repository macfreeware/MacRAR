import XCTest
@testable import MacRARCore

/// Karşılaştırma, birleştirme çakışmaları, boyut tahmini, ZIP ayrıntıları ve bsdtar ile sınama.
final class ExtraFeatureTests: XCTestCase {
    var tmp: URL!
    var service: ArchiveService!
    var tools: ToolPaths!
    let fm = FileManager.default

    override func setUpWithError() throws {
        tools = TestTools.paths()
        service = ArchiveService(tools: tools)
        tmp = fm.temporaryDirectory.appendingPathComponent("macrar-extra-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { if let tmp { try? fm.removeItem(at: tmp) } }

    @discardableResult
    func write(_ text: String, _ rel: String, under base: URL) throws -> URL {
        let url = base.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func makeZip(_ name: String, files: [String: String], password: String? = nil, format: ArchiveFormat = .zip) async throws -> URL {
        let src = tmp.appendingPathComponent("src-\(name)", isDirectory: true)
        for (rel, text) in files { try write(text, rel, under: src) }
        let archive = tmp.appendingPathComponent(name)
        var o = CompressOptions(archive: archive, sources: try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil))
        o.format = format
        o.password = password
        try await service.add(o)
        return archive
    }

    // MARK: ZIP ayrıntıları

    func testZipListingCarriesCRCPackedSizeAndMethod() async throws {
        try XCTSkipUnless(tools.bsdtar != nil)
        let zip = try await makeZip("a.zip", files: ["kök.txt": String(repeating: "abc", count: 500), "klasör/iç.txt": "iç"])
        let entries = try await service.list(archive: zip).entries
        let big = try XCTUnwrap(entries.first { $0.path == "kök.txt" })
        XCTAssertEqual(big.crc32?.count, 8)
        XCTAssertNotNil(big.packedSize)
        XCTAssertLessThan(big.packedSize ?? .max, big.size, "tekrarlı metin sıkışmalı")
        XCTAssertNotNil(big.method)
        let dir = try XCTUnwrap(entries.first { $0.path == "klasör" })
        XCTAssertNil(dir.crc32)
    }

    func testCentralDirectoryReadsNFDNamesStoredMethodAndEncryption() async throws {
        try XCTSkipUnless(tools.bsdtar != nil)
        // Ayrışık (NFD) Unicode adı: macOS'ta sık görülür; `unzip -v` bunu bozuyordu.
        let nfd = "ku\u{0308}çük dosya.txt"
        let zip = try await makeZip("n.zip", files: [nfd: "içerik", "klasör/iç.txt": "x"])
        let info = ZipCentralDirectory.read(zip)
        let key = nfd.precomposedStringWithCanonicalMapping
        XCTAssertNotNil(info[key], "\(info.keys)")
        XCTAssertEqual(info[key]?.size, Int64("içerik".utf8.count))
        XCTAssertEqual(info[key]?.encrypted, false)
        XCTAssertNotNil(info[key]?.crc)
        // Listeye de yansır (bsdtar listesindeki ad NFD olsa bile)
        let entries = try await service.list(archive: zip).entries
        XCTAssertTrue(entries.filter { !$0.isDirectory }.allSatisfy { $0.crc32?.count == 8 }, "\(entries.map { ($0.path, $0.crc32 as Any) })")

        // Şifreli: girdiler şifreli işaretlenir, AE-2'de CRC bilinmez
        let enc = try await makeZip("e.zip", files: ["gizli.txt": "gizli veri"], password: "p")
        let e = try XCTUnwrap(ZipCentralDirectory.read(enc)["gizli.txt"])
        XCTAssertTrue(e.encrypted)
        XCTAssertTrue(e.method.hasPrefix("AES+"), e.method)
        let listed = try await service.list(archive: enc, password: "p").entries
        XCTAssertEqual(listed.first { $0.path == "gizli.txt" }?.isEncrypted, true)
    }

    func testCentralDirectoryMatchesInfoZipForCRC() async throws {
        try XCTSkipUnless(tools.bsdtar != nil && fm.isExecutableFile(atPath: "/usr/bin/unzip"))
        let zip = try await makeZip("c.zip", files: ["a.txt": String(repeating: "x", count: 4000), "b/c.txt": "merhaba"])
        let r = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-v", zip.path])
        for (name, info) in ZipCentralDirectory.read(zip) {
            let crc = String(format: "%08x", info.crc ?? 0)
            XCTAssertTrue(r.text.contains("\(crc)  \(name)"), "\(name) \(crc)\n\(r.text)")
        }
    }

    func testCentralDirectoryHandlesZip64AndGarbage() throws {
        func le(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }
        let name = Array("büyük.bin".utf8)
        // zip64 ek alanı: gerçek boyutlar (usize, csize)
        let extra: [UInt8] = le(1, 2) + le(16, 2) + le(5_000_000_000, 8) + le(4_000_000_000, 8)
        var cd: [UInt8] = le(0x0201_4B50, 4) + le(45, 2) + le(45, 2) + le(0x800, 2) + le(8, 2) + le(0, 2) + le(0, 2)
            + le(0xDEADBEEF, 4) + le(0xFFFF_FFFF, 4) + le(0xFFFF_FFFF, 4) + le(UInt64(name.count), 2) + le(UInt64(extra.count), 2)
            + le(0, 2) + le(0, 2) + le(0, 2) + le(0, 4) + le(0, 4)
        cd += name + extra
        let body = [UInt8](repeating: 0, count: 10)                       // yerel kayıt yerine sahte gövde
        let cdOffset = UInt64(body.count)
        let z64Offset = cdOffset + UInt64(cd.count)
        let z64: [UInt8] = le(0x0606_4B50, 4) + le(44, 8) + le(45, 2) + le(45, 2) + le(0, 4) + le(0, 4)
            + le(1, 8) + le(1, 8) + le(UInt64(cd.count), 8) + le(cdOffset, 8)
        let locator: [UInt8] = le(0x0706_4B50, 4) + le(0, 4) + le(z64Offset, 8) + le(1, 4)
        let eocd: [UInt8] = le(0x0605_4B50, 4) + le(0, 2) + le(0, 2) + le(0xFFFF, 2) + le(0xFFFF, 2)
            + le(0xFFFF_FFFF, 4) + le(0xFFFF_FFFF, 4) + le(0, 2)
        let url = tmp.appendingPathComponent("z64.zip")
        try Data(body + cd + z64 + locator + eocd).write(to: url)
        let info = try XCTUnwrap(ZipCentralDirectory.read(url)["büyük.bin"])
        XCTAssertEqual(info.size, 5_000_000_000)
        XCTAssertEqual(info.packed, 4_000_000_000)
        XCTAssertEqual(info.crc, 0xDEADBEEF)
        XCTAssertEqual(info.method, "Deflate")

        let junk = tmp.appendingPathComponent("junk.zip")
        try Data((0..<5000).map { UInt8($0 % 251) }).write(to: junk)
        XCTAssertTrue(ZipCentralDirectory.read(junk).isEmpty)
        let tiny = tmp.appendingPathComponent("tiny.zip")
        try Data([0x50, 0x4B]).write(to: tiny)
        XCTAssertTrue(ZipCentralDirectory.read(tiny).isEmpty)
        XCTAssertTrue(ZipCentralDirectory.read(tmp.appendingPathComponent("yok.zip")).isEmpty)
    }

    // MARK: Karşılaştırma

    func entry(_ path: String, size: Int64, crc: String? = nil, dir: Bool = false) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: dir, size: size, crc32: crc)
    }

    func testCompareClassifiesEveryCase() {
        let a = [entry("same.txt", size: 3, crc: "AAAAAAAA"), entry("changed.txt", size: 3, crc: "11111111"),
                 entry("resized.txt", size: 3), entry("unverified.txt", size: 9), entry("onlyA.txt", size: 1, crc: "01010101"),
                 entry("dir", size: 0, dir: true), entry("kind", size: 1, crc: "22222222")]
        let b = [entry("same.txt", size: 3, crc: "aaaaaaaa"), entry("changed.txt", size: 3, crc: "22222222"),
                 entry("resized.txt", size: 4), entry("unverified.txt", size: 9, crc: "33333333"), entry("onlyB.txt", size: 1),
                 entry("dir", size: 0, dir: true), entry("kind", size: 0, dir: true)]
        let r = ArchiveComparison.compare(a, b)
        func status(_ p: String) -> ArchiveComparison.Status? { r.items.first { $0.path == p }?.status }
        XCTAssertEqual(status("same.txt"), .identical, "CRC büyük/küçük harf duyarsız")
        XCTAssertEqual(status("changed.txt"), .differentContent)
        XCTAssertEqual(status("resized.txt"), .differentSize)
        XCTAssertEqual(status("unverified.txt"), .sameSizeUnverified)
        XCTAssertEqual(status("onlyA.txt"), .onlyInFirst)
        XCTAssertEqual(status("onlyB.txt"), .onlyInSecond)
        XCTAssertEqual(status("kind"), .typeMismatch)
        XCTAssertNil(status("dir"), "iki tarafta da olan klasör satırı yok")
        XCTAssertEqual(r.differenceCount, 5)
        XCTAssertFalse(r.isIdentical)
    }

    func testCompareMatchesUnicodeNormalizationAndSorts() {
        let nfd = "ku\u{0308}çük.txt"      // ü ayrışık
        let nfc = "küçük.txt"
        let r = ArchiveComparison.compare([entry(nfd, size: 1, crc: "AB")], [entry(nfc, size: 1, crc: "AB"), entry("a.txt", size: 1)])
        XCTAssertEqual(r.count(.identical), 1)
        XCTAssertEqual(r.count(.onlyInSecond), 1)
        XCTAssertEqual(r.items.first?.path, "a.txt")
    }

    func testCompareIdenticalArchivesIsIdentical() {
        let e = [entry("x", size: 1, crc: "AA"), entry("d", size: 0, dir: true)]
        XCTAssertTrue(ArchiveComparison.compare(e, e).isIdentical)
        XCTAssertTrue(ArchiveComparison.compare([], []).isIdentical)
    }

    func testCompareRealZipsDetectsContentChangeWithSameSize() async throws {
        try XCTSkipUnless(tools.bsdtar != nil)
        let a = try await makeZip("a.zip", files: ["x.txt": "AAAA", "y.txt": "same", "only-a.txt": "1"])
        let b = try await makeZip("b.zip", files: ["x.txt": "BBBB", "y.txt": "same", "only-b.txt": "2"])
        let r = ArchiveComparison.compare(try await service.list(archive: a).entries, try await service.list(archive: b).entries)
        func status(_ p: String) -> ArchiveComparison.Status? { r.items.first { $0.path == p }?.status }
        XCTAssertEqual(status("x.txt"), .differentContent, "boyut aynı, içerik farklı: CRC ile yakalanmalı")
        XCTAssertEqual(status("y.txt"), .identical)
        XCTAssertEqual(status("only-a.txt"), .onlyInFirst)
        XCTAssertEqual(status("only-b.txt"), .onlyInSecond)
    }

    func testCompareRarWithZipUsesCRC() async throws {
        try XCTSkipUnless(tools.bsdtar != nil && tools.canWriteRAR && tools.canReadRAR, "rar yok")
        let files = ["x.txt": "içerik", "y.txt": "başka"]
        let z = try await makeZip("a.zip", files: files)
        let r = try await makeZip("b.rar", files: files, format: .rar5)
        let cmp = ArchiveComparison.compare(try await service.list(archive: z).entries, try await service.list(archive: r).entries)
        XCTAssertEqual(cmp.count(.identical), 2, "\(cmp.items.map { "\($0.path):\($0.status)" })")
    }

    // MARK: Birleştirme çakışmaları

    func testMergeConflictsListsOnlyDuplicateFiles() {
        let a = [entry("a.txt", size: 1), entry("d", size: 0, dir: true), entry("d/x", size: 1)]
        let b = [entry("d", size: 0, dir: true), entry("d/x", size: 2), entry("b.txt", size: 1)]
        let c = [entry("a.txt", size: 3)]
        XCTAssertEqual(ArchiveMerge.conflicts(in: [a, b, c]), ["a.txt", "d/x"])
        XCTAssertTrue(ArchiveMerge.conflicts(in: [a, [entry("z", size: 1)]]).isEmpty)
    }

    // MARK: Boyut tahmini

    func testEstimatorSeesCompressibleAndIncompressibleData() throws {
        let compressible = tmp.appendingPathComponent("c.txt")
        try String(repeating: "merhaba dünya ", count: 100_000).write(to: compressible, atomically: true, encoding: .utf8)
        let random = tmp.appendingPathComponent("r.bin")
        var rng = SystemRandomNumberGenerator()
        try Data((0..<600_000).map { _ in UInt8.random(in: 0...255, using: &rng) }).write(to: random)

        let c = try XCTUnwrap(SizeEstimator.estimate(sources: [compressible]))
        XCTAssertTrue(c.sampled)
        XCTAssertLessThan(c.estimatedBytes, c.totalBytes / 20, "çok tekrarlı metin ≥20 kat sıkışmalı")
        let r = try XCTUnwrap(SizeEstimator.estimate(sources: [random]))
        XCTAssertGreaterThan(r.estimatedBytes, r.totalBytes * 9 / 10, "rastgele veri sıkışmaz")
        XCTAssertLessThanOrEqual(r.estimatedBytes, r.totalBytes + 200, "tahmin kaynaktan büyük olmamalı")
    }

    func testEstimatorStoreModeAndFoldersAndEmpty() throws {
        let dir = tmp.appendingPathComponent("d", isDirectory: true)
        try write(String(repeating: "x", count: 1000), "a.txt", under: dir)
        try write(String(repeating: "y", count: 2000), "alt/b.txt", under: dir)
        let stored = try XCTUnwrap(SizeEstimator.estimate(sources: [dir], store: true))
        XCTAssertEqual(stored.totalBytes, 3000)
        XCTAssertEqual(stored.fileCount, 2)
        XCTAssertEqual(stored.estimatedBytes, 3000)
        let normal = try XCTUnwrap(SizeEstimator.estimate(sources: [dir]))
        XCTAssertLessThan(normal.estimatedBytes, 3000)

        let empty = tmp.appendingPathComponent("empty", isDirectory: true)
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        let e = try XCTUnwrap(SizeEstimator.estimate(sources: [empty]))
        XCTAssertEqual(e.totalBytes, 0)
        XCTAssertEqual(e.estimatedBytes, 0)
        let missing = try XCTUnwrap(SizeEstimator.estimate(sources: [tmp.appendingPathComponent("yok")]))
        XCTAssertEqual(missing.totalBytes, 0)
    }

    func testEstimateIsCloseToRealZipSize() async throws {
        try XCTSkipUnless(tools.bsdtar != nil)
        let src = tmp.appendingPathComponent("proj", isDirectory: true)
        let lorem = (0..<4000).map { "satır \($0): Türkçe örnek metin, sıkıştırma oranı için \($0 % 17)\n" }.joined()
        try write(lorem, "a.txt", under: src)
        try write(lorem + lorem, "b/c.txt", under: src)
        let est = try XCTUnwrap(SizeEstimator.estimate(sources: [src]))
        var o = CompressOptions(archive: tmp.appendingPathComponent("p.zip"), sources: [src])
        o.format = .zip
        try await service.add(o)
        let real = Int64(try fm.attributesOfItem(atPath: o.archive.path)[.size] as? Int ?? 0)
        let ratio = Double(est.estimatedBytes) / Double(real)
        XCTAssertTrue((0.5...2.0).contains(ratio), "tahmin \(est.estimatedBytes), gerçek \(real)")
    }

    // MARK: bsdtar ile sınama (ZIP/7Z/TAR)

    func testZipTestPassesOnGoodArchiveAndFailsOnCorruption() async throws {
        try XCTSkipUnless(tools.bsdtar != nil)
        let zip = try await makeZip("a.zip", files: ["büyük.bin": String(repeating: "0123456789", count: 20_000)])
        _ = try await service.test(archive: zip)

        // Ortadan bir bayt boz (sıkıştırılmış veri içinde)
        var data = try Data(contentsOf: zip)
        let mid = data.count / 2
        data[mid] ^= 0xFF
        data[mid + 1] ^= 0xFF
        let bad = tmp.appendingPathComponent("bad.zip")
        try data.write(to: bad)
        do { _ = try await service.test(archive: bad); XCTFail("bozuk arşiv sınamadan geçmemeli") }
        catch ArchiveError.failed {} catch { XCTFail("beklenmeyen hata: \(error)") }
    }

    func testTarGzAndSevenZipTest() async throws {
        try XCTSkipUnless(tools.bsdtar != nil)
        for (name, fmt) in [("a.tar.gz", ArchiveFormat.tarGz), ("a.7z", .sevenZip)] {
            let a = try await makeZip(name, files: ["x.txt": String(repeating: "veri", count: 1000)], format: fmt)
            _ = try await service.test(archive: a)
        }
    }

    func testEncryptedZipTestNeedsCorrectPassword() async throws {
        try XCTSkipUnless(tools.bsdtar != nil)
        let zip = try await makeZip("e.zip", files: ["x.txt": "gizli içerik"], password: "ş1")
        do { _ = try await service.test(archive: zip); XCTFail("parolasız sınama geçmemeli") }
        catch ArchiveError.passwordRequired {} catch { XCTFail("\(error)") }
        do { _ = try await service.test(archive: zip, password: "yanlış"); XCTFail("yanlış parola geçmemeli") }
        catch ArchiveError.wrongPassword {} catch { XCTFail("\(error)") }
        _ = try await service.test(archive: zip, password: "ş1")
    }

    func testNotAnArchiveFailsTest() async throws {
        try XCTSkipUnless(tools.bsdtar != nil)
        let f = try write("düz metin", "x.zip", under: tmp)
        do { _ = try await service.test(archive: f); XCTFail("arşiv olmayan dosya sınamadan geçmemeli") }
        catch ArchiveError.failed {} catch { XCTFail("\(error)") }
    }

    // MARK: Parola ipucu

    func testSavedPasswordHintRoundTripsAndOldRecordsDecode() throws {
        let item = SavedPassword(name: "Muhasebe", password: "p", hint: "2024 arşivleri")
        let back = try JSONDecoder().decode(SavedPassword.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(back.hint, "2024 arşivleri")
        let old = #"{"id":"6F6E1E2A-0000-4000-8000-000000000001","name":"Eski","password":"x"}"#
        let decoded = try JSONDecoder().decode(SavedPassword.self, from: Data(old.utf8))
        XCTAssertNil(decoded.hint)
        XCTAssertEqual(decoded.name, "Eski")
    }
}
