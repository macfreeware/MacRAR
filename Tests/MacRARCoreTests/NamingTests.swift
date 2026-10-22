import XCTest
@testable import MacRARCore

final class NamingTests: XCTestCase {
    // 2026-10-09 11:23:45 yerel saat dilimi değil, sabit UTC ile
    let date = Date(timeIntervalSince1970: 1_791_545_025) // 2026-10-09 11:23:45 UTC
    let utc = TimeZone(identifier: "UTC")!

    func testPresets() {
        let expect: [String: String] = [
            "yyyyMMddHHmmss": "20261009112345",
            "yyyyMMdd-HHmmss": "20261009-112345",
            "yyyy-MM-dd_HH-mm-ss": "2026-10-09_11-23-45",
            "yyyy-MM-dd HH.mm.ss": "2026-10-09 11.23.45",
            "dd-MM-yyyy_HH-mm": "09-10-2026_11-23",
            "yyyyMMdd": "20261009",
            "yyyy-MM-dd": "2026-10-09",
            "yyMMdd_HHmm": "261009_1123",
        ]
        for p in ArchiveNaming.presets {
            XCTAssertEqual(ArchiveNaming.timestamp(pattern: p.pattern, date: date, timeZone: utc), expect[p.pattern], p.pattern)
        }
    }

    func testIllegalCharactersAreReplaced() {
        XCTAssertEqual(ArchiveNaming.timestamp(pattern: "yyyy/MM/dd HH:mm", date: date, timeZone: utc), "2026-10-09 11-23")
    }

    func testFileNames() {
        XCTAssertEqual(ArchiveNaming.fileName(base: "klasör", stamp: nil, ext: "rar", date: date), "klasör.rar")
        let s = ArchiveNaming.fileName(base: "klasör", stamp: ("yyyyMMddHHmmss", "-"), ext: "rar", date: date)
        XCTAssertTrue(s.hasPrefix("klasör-2026") && s.hasSuffix(".rar") && s.count == "klasör-20261009112345.rar".count, s)
        XCTAssertEqual(ArchiveNaming.fileName(base: "a", stamp: ("yyyyMMdd", "_"), ext: "zip", date: date).prefix(6), "a_2026")
        XCTAssertTrue(ArchiveNaming.fileName(base: "a", stamp: ("yyyyMMdd", ""), ext: "rar", date: date).hasPrefix("a2026"))
    }

    func testValidation() {
        XCTAssertTrue(ArchiveNaming.isValid(pattern: "yyyyMMddHHmmss"))
        XCTAssertFalse(ArchiveNaming.isValid(pattern: ""))
        XCTAssertFalse(ArchiveNaming.isValid(pattern: "   "))
    }

    func testBaseNameAndUnique() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("naming-\(UUID().uuidString)")
        let folder = tmp.appendingPathComponent("Fotoğraflar")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = tmp.appendingPathComponent("rapor.final.pdf")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: tmp) }

        XCTAssertEqual(ArchiveNaming.baseName(for: [folder]), "Fotoğraflar")
        XCTAssertEqual(ArchiveNaming.baseName(for: [file]), "rapor.final")
        XCTAssertEqual(ArchiveNaming.baseName(for: [folder, file]), tmp.lastPathComponent)

        let first = ArchiveNaming.uniqueURL(in: tmp, fileName: "Fotoğraflar.rar", ext: "rar")
        XCTAssertEqual(first.lastPathComponent, "Fotoğraflar.rar")
        try Data().write(to: first)
        XCTAssertEqual(ArchiveNaming.uniqueURL(in: tmp, fileName: "Fotoğraflar.rar", ext: "rar").lastPathComponent, "Fotoğraflar 2.rar")
        try Data().write(to: tmp.appendingPathComponent("Fotoğraflar 2.rar"))
        XCTAssertEqual(ArchiveNaming.uniqueURL(in: tmp, fileName: "Fotoğraflar.rar", ext: "rar").lastPathComponent, "Fotoğraflar 3.rar")
    }
}
