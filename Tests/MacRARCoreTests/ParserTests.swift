import XCTest
@testable import MacRARCore

final class ParserTests: XCTestCase {
    func testRarListParsing() {
        let text = """

        UNRAR 6.24 freeware      Copyright (c) 1993-2023 Alexander Roshal

        hello comment


        Archive: f.rar
        Details: RAR 5, solid, recovery record, lock

                Name: src/kök.txt
                Type: File
                Size: 3
         Packed size: 3
               Ratio: 100%
               mtime: 2026-10-09 10:20:07,594972898
          Attributes: -rw-r--r--
               CRC32: ED6F7A7A
             Host OS: Unix
         Compression: RAR 5.0(v50) -m0 -md=128K

                Name: src/klasör/türkçe: dosya.txt
                Type: File
               Flags: encrypted
                Size: 15
         Packed size: 31

                Name: src/klasör
                Type: Directory
               mtime: 2026-10-09 10:20:07,589308197

                Name: CMT
                Type: Service
                Size: 5

        """.replacingOccurrences(of: "\n        ", with: "\n")

        let r = RarListParser.parse(text)
        XCTAssertTrue(r.recognizedArchive)
        XCTAssertFalse(r.passwordProblem)
        XCTAssertEqual(r.info.formatName, "RAR 5")
        XCTAssertTrue(r.info.isSolid)
        XCTAssertTrue(r.info.hasRecoveryRecord)
        XCTAssertTrue(r.info.isLocked)
        XCTAssertEqual(r.info.comment, "hello comment")
        XCTAssertEqual(r.entries.count, 3, "Service girdisi atlanmalı")

        XCTAssertEqual(r.entries[0].path, "src/kök.txt")
        XCTAssertEqual(r.entries[0].size, 3)
        XCTAssertEqual(r.entries[0].crc32, "ED6F7A7A")
        XCTAssertNotNil(r.entries[0].modified)
        XCTAssertEqual(r.entries[1].path, "src/klasör/türkçe: dosya.txt")
        XCTAssertTrue(r.entries[1].isEncrypted)
        XCTAssertEqual(r.entries[1].packedSize, 31)
        XCTAssertTrue(r.entries[2].isDirectory)
    }

    /// RAR 7.x yorumun önüne "Archive comment:" başlığı yazar ve deneme sürümü hatırlatma satırları ekler;
    /// hiçbiri yorumun parçası sayılmamalı. (Gerçek unrar 7.23 çıktısından.)
    func testRarListCommentIgnoresHeadersFromRar7AndTrialReminders() {
        let rar7 = "\nUNRAR 7.23 freeware      Copyright (c) 1993-2026 Alexander Roshal\n\nArchive comment:\nMerhaba yorum\n\n\nArchive: cm.rar\nDetails: RAR 5\n\n        Name: a.txt\n        Type: File\n        Size: 8\n"
        XCTAssertEqual(RarListParser.parse(rar7).info.comment, "Merhaba yorum")
        XCTAssertEqual(RarListParser.parse(rar7).entries.count, 1)

        let rar6 = "\nUNRAR 6.24 freeware      Copyright (c) 1993-2023 Alexander Roshal\n\nMerhaba yorum\n\n\nArchive: cm.rar\nDetails: RAR 5\n\n        Name: a.txt\n        Type: File\n        Size: 8\n"
        XCTAssertEqual(RarListParser.parse(rar6).info.comment, "Merhaba yorum", "6.x biçimi de çalışmalı")

        // `rar` ile listelenirse (unrar yoksa) deneme sürümü satırları yorum sayılmamalı
        let trial = "\n  Cannot open /usr/local/etc/rarreg.key\n  Operation not permitted\nRAR 7.23   Copyright (c) 1993-2026 Alexander Roshal   27 Jun 2026\nTrial version             Type 'rar -?' for help\n\nEvaluation copy. Please register.\n\nArchive: x.rar\nDetails: RAR 5\n\n        Name: a.txt\n        Type: File\n        Size: 1\n"
        XCTAssertNil(RarListParser.parse(trial).info.comment, "hatırlatma satırları yorum olmamalı")

        // Yorum yoksa 7.x çıktısı yorum üretmemeli
        let none = "\nUNRAR 7.23 freeware      Copyright (c) 1993-2026 Alexander Roshal\n\nArchive: x.rar\nDetails: RAR 5\n\n        Name: a.txt\n        Type: File\n        Size: 1\n"
        XCTAssertNil(RarListParser.parse(none).info.comment)
    }

    // MARK: lsar / unar (gerçek çıktı yapısından)

    func testUnarListParsing() throws {
        let json = """
        {"lsarFormatVersion":2,"lsarContents":[
          {"XADIndex":0,"XADFileName":"src/kök dosya.txt","XADFileSize":14,"XADCompressedSize":14,
           "XADLastModificationDate":"2026-10-09 15:30:38 +0000","RAR5CRC32":3176627853,"RAR5OSName":"Unix",
           "XADCompressionName":"Normal v5.0 (0)","XADIsEncrypted":true},
          {"XADIndex":1,"XADFileName":"src/klasör/","XADIsDirectory":true,"XADLastModificationDate":"2026-10-09 15:30:38 +0000"},
          {"XADIndex":2,"XADFileName":"src/link","XADFileSize":3,"XADIsLink":true}
        ],"lsarEncoding":"windows-1252","lsarFormatName":"RAR 5"}
        """
        let r = try XCTUnwrap(UnarListParser.parse(Data(json.utf8)))
        XCTAssertEqual(r.formatName, "RAR 5")
        XCTAssertNil(r.errorCode)
        XCTAssertEqual(r.entries.map(\.path), ["src/kök dosya.txt", "src/klasör", "src/link"], "sondaki / atılmalı")
        XCTAssertEqual(r.entries.map(\.index), [0, 1, 2])
        let f = r.entries[0]
        XCTAssertEqual(f.size, 14); XCTAssertEqual(f.packedSize, 14); XCTAssertEqual(f.crc32, "BD4D4B8D".isEmpty ? nil : String(format: "%08X", 3176627853))
        XCTAssertTrue(f.isEncrypted); XCTAssertEqual(f.hostOS, "Unix"); XCTAssertNotNil(f.modified)
        XCTAssertTrue(r.entries[1].isDirectory); XCTAssertNil(r.entries[1].crc32)
        XCTAssertTrue(r.entries[2].isSymlink)
    }

    func testUnarListErrorsAndNonJSON() throws {
        let wrongPw = try XCTUnwrap(UnarListParser.parse(Data(#"{"lsarFormatVersion":2,"lsarContents":[],"lsarError":15,"lsarFormatName":"RAR 5"}"#.utf8)))
        XCTAssertEqual(wrongPw.errorCode, 15); XCTAssertTrue(wrongPw.entries.isEmpty)
        let notArchive = try XCTUnwrap(UnarListParser.parse(Data(#"{"lsarFormatVersion":2,"lsarError":0}"#.utf8)))
        XCTAssertEqual(notArchive.errorCode, 0)
        XCTAssertNil(UnarListParser.parse(Data("{\n  \"lsarFormatVersion\": 2,\n  \"lsarContents\": [".utf8)), "yarım JSON nil dönmeli")
        XCTAssertNil(UnarListParser.parse(Data()))
    }

    func testUnarProgressLines() {
        var p = ProgressParser(style: .unar)
        let out = """
        hp/enc.rar: RAR 5
          src/kök dosya.txt  (14 B)... OK.
          src/klasör/  (dir)... OK.
          a b.txt  (6 B)... Failed! (Missing or wrong password)
        OtaV3/x.bin... OK.
        OtaV3/y.bin... Unpacking failed!
        Successfully extracted to "out".

        """
        let ev = p.feed(Data(out.utf8)) + p.finish()
        XCTAssertEqual(ev, [
            .message("hp/enc.rar: RAR 5"),
            .file(name: "src/kök dosya.txt"), .fileFinished(ok: true),
            .file(name: "src/klasör/"), .fileFinished(ok: true),
            .file(name: "a b.txt"), .fileFinished(ok: false), .message("a b.txt  (6 B)... Failed! (Missing or wrong password)"),
            .file(name: "OtaV3/x.bin"), .fileFinished(ok: true),
            .file(name: "OtaV3/y.bin"), .fileFinished(ok: false), .message("OtaV3/y.bin... Unpacking failed!"),
            .message("Successfully extracted to \"out\"."),
        ])
    }

    func testUnarExitCodeInterpretation() throws {
        func result(_ code: Int32, _ text: String) -> ProcessResult { ProcessResult(exitCode: code, output: Data(text.utf8), killedEarly: false) }
        XCTAssertNoThrow(try ArchiveService.interpretUnar(result(0, "ok"), passwordGiven: false))
        XCTAssertThrowsError(try ArchiveService.interpretUnar(result(2, "This archive requires a password to unpack."), passwordGiven: false)) {
            guard case ArchiveError.passwordRequired = $0 else { return XCTFail("\($0)") } }
        XCTAssertThrowsError(try ArchiveService.interpretUnar(result(2, "requires a password"), passwordGiven: true)) {
            guard case ArchiveError.wrongPassword = $0 else { return XCTFail("\($0)") } }
        XCTAssertThrowsError(try ArchiveService.interpretUnar(result(1, "a.txt  (6 B)... Failed! (Missing or wrong password)"), passwordGiven: true)) {
            guard case ArchiveError.wrongPassword = $0 else { return XCTFail("\($0)") } }
        XCTAssertThrowsError(try ArchiveService.interpretUnar(result(1, "x.rar: Couldn't open archive. (Opening file failed.)"), passwordGiven: false)) {
            guard case ArchiveError.failed(_, let m) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(m.contains("Couldn't open archive"), m) }
    }

    func testRarListPasswordProblem() {
        let r = RarListParser.parse("\nIncorrect password for enc.rar\nArchive: enc.rar\nDetails: RAR 5, encrypted headers\n\n")
        XCTAssertTrue(r.passwordProblem)
        XCTAssertTrue(r.entries.isEmpty)
        XCTAssertTrue(r.info.hasEncryptedHeaders)
    }

    func testTarListParsing() {
        let now = ISO8601DateFormatter().date(from: "2026-10-09T12:00:00Z")!
        let text = """
        drwxr-xr-x  0 501    0           0 Oct  9 10:20 ./
        -rw-r--r--  0 501    0           3 Oct  9 10:20 ./kök.txt
        lrwxr-xr-x  0 501    0           0 Oct  9 10:20 ./link.txt -> kök.txt
        drwxr-xr-x  0 501    0           0 Oct  9 10:20 ./klasör/
        -rw-r--r--@ 0 501    0       15000 Jan  3  2023 ./klasör/türkçe dosya.txt
        """
        let e = TarListParser.parse(text, now: now)
        XCTAssertEqual(e.map { $0.path }, ["kök.txt", "link.txt", "klasör", "klasör/türkçe dosya.txt"])
        XCTAssertEqual(e[0].rawName, "./kök.txt")
        XCTAssertTrue(e[1].isSymlink)
        XCTAssertTrue(e[2].isDirectory)
        XCTAssertEqual(e[3].size, 15000)
        let year = Calendar(identifier: .gregorian).component(.year, from: e[3].modified!)
        XCTAssertEqual(year, 2023)
    }

    func testProgressParserHandlesSplitChunksAndBackspaces() {
        var p = ProgressParser()
        let raw = "Extracting  out/src/k\u{f6}k.txt      \u{8}\u{8}\u{8}\u{8}  0%\u{8}\u{8}\u{8}\u{8}\u{8}  OK \nCreating    out/src/d     OK\nAll OK\n"
        let bytes = Array(raw.utf8)
        var events: [ProgressEvent] = []
        // 7'şer baytlık parçalarla besle: UTF-8 ortasından bölünme dahil
        var i = 0
        while i < bytes.count {
            let end = min(i + 7, bytes.count)
            events += p.feed(Data(bytes[i..<end]))
            i = end
        }
        events += p.finish()
        XCTAssertEqual(events, [
            .file(name: "out/src/kök.txt"), .percent(0), .fileFinished(ok: true),
            .file(name: "out/src/d"), .fileFinished(ok: true),
            .message("All OK"),
        ])
    }

    func testProgressParserHeadersAreMessages() {
        var p = ProgressParser()
        let ev = p.feed(Data("Extracting from t.rar\nCreating archive p.rar\nDeleting from d.rar\n".utf8))
        XCTAssertEqual(ev.count, 3)
        for e in ev { if case .file = e { XCTFail("başlık dosya sanıldı: \(e)") } }
    }

    func testTrackerFractionUsesWeights() {
        let t = ProgressTracker(weights: ["a.txt": 100, "dir/b.txt": 300], stripPrefix: "/tmp/out/")
        t.feed(Data("Extracting  /tmp/out/a.txt     \u{8}\u{8}\u{8}\u{8}100%\u{8}\u{8}\u{8}\u{8}\u{8}  OK \n".utf8))
        XCTAssertEqual(t.drain().fraction ?? 0, 0.25, accuracy: 0.001)
        t.feed(Data("Extracting  /tmp/out/dir/b.txt     \u{8}\u{8}\u{8}\u{8} 50%\u{8}".utf8))
        let s = t.drain()
        XCTAssertEqual(s.fraction ?? 0, 0.625, accuracy: 0.001)
        XCTAssertEqual(s.currentFile, "/tmp/out/dir/b.txt")
    }

    func testSelectionExpansionIncludesDescendants() {
        func e(_ p: String, dir: Bool) -> ArchiveEntry { ArchiveEntry(path: p, isDirectory: dir, size: 1) }
        let all = [e("a", dir: true), e("a/b", dir: true), e("a/b/c.txt", dir: false),
                   e("a/x.txt", dir: false), e("ab.txt", dir: false)]
        let out = ArchiveSelection.expand([all[1]], in: all).map { $0.path }
        XCTAssertEqual(out, ["a/b", "a/b/c.txt"])
    }
}
