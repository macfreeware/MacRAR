import XCTest
@testable import MacRARCore

/// Finder/Dock'tan açılan uygulamanın çalışma klasörü "/" (salt okunur). rar, arşivi değiştirirken geçici dosyayı çalışma
/// klasöründe açtığından düzenleme işlemleri "Cannot create __rar_….rartemp" ile çöküyordu.
final class ReadOnlyWorkingDirectoryTests: XCTestCase {
    private var root: URL!
    private var savedCwd = ""

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("macrar-rocwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "birinci".write(to: root.appendingPathComponent("src/a.txt"), atomically: true, encoding: .utf8)
        try "ikinci".write(to: root.appendingPathComponent("src/b.txt"), atomically: true, encoding: .utf8)
        savedCwd = FileManager.default.currentDirectoryPath
    }
    override func tearDown() {
        FileManager.default.changeCurrentDirectoryPath(savedCwd)
        try? FileManager.default.removeItem(at: root)
    }

    func testEditOperationsWorkWhenProcessWorkingDirectoryIsRoot() async throws {
        let tools = TestTools.paths()
        try XCTSkipUnless(tools.canWriteRAR, "rar yok")
        let svc = ArchiveService(tools: tools)
        let archive = root.appendingPathComponent("t.rar")
        var o = CompressOptions(archive: archive, sources: [root.appendingPathComponent("src")])
        o.format = .rar5
        _ = try await svc.add(o)

        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath("/"), "çalışma klasörü / olmalı")
        // Her işlem, kullanıcının gerçek akışındaki gibi "/" çalışma klasörüyle:
        _ = try await svc.setComment(archive: archive, comment: "yorum metni")
        _ = try await svc.addRecoveryRecord(archive: archive, percent: 3)
        var listing = try await svc.list(archive: archive)
        XCTAssertEqual((listing.info.comment ?? "").trimmingCharacters(in: .whitespacesAndNewlines), "yorum metni")
        let entry = try XCTUnwrap(listing.entries.first { $0.path.hasSuffix("a.txt") })
        _ = try await svc.rename(in: archive, entry: entry, newPath: "src/yeni ad.txt")
        listing = try await svc.list(archive: archive)
        XCTAssertTrue(listing.entries.contains { $0.path.hasSuffix("yeni ad.txt") })
        let b = try XCTUnwrap(listing.entries.first { $0.path.hasSuffix("b.txt") })
        _ = try await svc.delete(from: archive, entries: [b])
        listing = try await svc.list(archive: archive)
        XCTAssertFalse(listing.entries.contains { $0.path.hasSuffix("b.txt") })
        // Mevcut arşive ekleme (rar a, var olan arşivi günceller)
        try "üçüncü".write(to: root.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        var more = CompressOptions(archive: archive, sources: [root.appendingPathComponent("c.txt")])
        more.format = .rar5
        _ = try await svc.add(more)
        _ = try await svc.lock(archive: archive)
        listing = try await svc.list(archive: archive)
        XCTAssertTrue(listing.entries.contains { $0.path.hasSuffix("c.txt") })
    }

    func testRunnerFallsBackToTemporaryDirectoryWhenCwdIsRoot() async throws {
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath("/"))
        let r = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/pwd"), [])
        let printed = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotEqual(printed, "/", "alt süreç salt okunur '/' içinde çalışmamalı")
        XCTAssertTrue(FileManager.default.isWritableFile(atPath: printed))
    }
}
