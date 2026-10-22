import XCTest
@testable import MacRARCore

final class TransferMonitorTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("macrar-transfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testRealPathResolvesPrivateVarPrefixLikeTheKernel() {
        XCTAssertTrue(TransferMonitor.realPath(root.path).hasPrefix("/private/var/"), TransferMonitor.realPath(root.path))
        XCTAssertEqual(TransferMonitor.realPath("/yok/boyle/bir/yol"), "/yok/boyle/bir/yol", "var olmayan yol aynen döner")
    }

    func testReadsFileOffsetOfRunningChildProcess() throws {
        let file = root.appendingPathComponent("veri.bin")
        try Data(repeating: 7, count: 5000).write(to: file)
        // fd 3 dosyayı açar, dd tam 1000 bayt okur (bs=1), ardından süreç uyur: konum 1000 olmalı.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "exec 3<'\(file.path)'; dd bs=1 count=1000 <&3 >/dev/null 2>&1; sleep 5"]
        try p.run()
        defer { p.terminate(); p.waitUntilExit() }
        var found: TransferMonitor.OpenFile?
        for _ in 0..<40 {
            found = TransferMonitor.openFiles(pid: p.processIdentifier).first { $0.path.hasSuffix("veri.bin") }
            if found?.offset == 1000 { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(found?.offset, 1000, "açık dosya konumu işletim sisteminden okunabilmeli")
        let rootPath = TransferMonitor.realPath(root.path)
        let c = TransferMonitor.candidates(in: [.init(path: rootPath + "/proje/alt/d.bin", offset: 1000),
                                                .init(path: "/dev/null", offset: 99)], roots: [rootPath])
        XCTAssertEqual(c.map(\.key), ["proje/alt/d.bin"])
        XCTAssertEqual(c.map(\.offset), [1000])
        XCTAssertTrue(TransferMonitor.candidates(in: [.init(path: "/baska/yer", offset: 5)], roots: [rootPath]).isEmpty)
    }

    func testTrackerUsesActiveFileOffsetAndBsdtarNamesArriveAfterCompletion() {
        let tracker = ProgressTracker(weights: ["big.bin": 1000, "kucuk.txt": 100], style: .bsdtar)
        XCTAssertEqual(tracker.drain().fraction ?? -1, 0, accuracy: 0.001)
        tracker.setActive(candidates: [("big.bin", 550), ("a.zip", 9_999_999)])   // arşivin kendisi ağırlıksız: yok sayılır
        XCTAssertEqual(tracker.drain().fraction ?? -1, 550.0 / 1100.0, accuracy: 0.001, "tek büyük dosyada bile ilerlemeli")
        tracker.setActive(candidates: [("big.bin", 5000)])         // dosya boyutunu aşan konum sınırlanır
        XCTAssertEqual(tracker.drain().fraction ?? -1, 1000.0 / 1100.0, accuracy: 0.001)
        tracker.feed(Data("a big.bin\n".utf8))                      // ad bitişte gelir: tek kez sayılmalı (çift sayım yok)
        XCTAssertEqual(tracker.drain().fraction ?? -1, 1000.0 / 1100.0, accuracy: 0.001)
        tracker.setActive(candidates: [("kucuk.txt", 50)])
        XCTAssertEqual(tracker.drain().fraction ?? -1, 1050.0 / 1100.0, accuracy: 0.001)
        tracker.feed(Data("a kucuk.txt\n".utf8))
        XCTAssertEqual(tracker.drain().fraction ?? -1, 1.0, accuracy: 0.001)
    }

    /// Gerçek bsdtar ile: tek büyük dosyayı sıkıştırırken ilerleme 0 ile 1 arasında ara değerler almalı.
    func testZipOfOneBigFileReportsIntermediateProgress() async throws {
        let tools = TestTools.paths()
        try XCTSkipUnless(tools.bsdtar != nil, "bsdtar yok")
        let src = root.appendingPathComponent("buyuk.bin")
        var rng = SystemRandomNumberGenerator()
        let chunk = Data((0..<1_048_576).map { _ in UInt8.random(in: 0...255, using: &rng) })
        FileManager.default.createFile(atPath: src.path, contents: nil)
        let h = try FileHandle(forWritingTo: src)
        for _ in 0..<100 { try h.write(contentsOf: chunk) }       // ~100 MB rastgele (deflate yavaş ve sıkıştırılamaz)
        try h.close()

        var options = CompressOptions(archive: root.appendingPathComponent("a.zip"), sources: [src])
        options.format = .zip
        let tracker = await ProgressTracker.forAdding(options)
        let samples = LockedSamples()
        let poller = Task {
            while !Task.isCancelled {
                if let f = tracker.drain().fraction { samples.add(f) }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        _ = try await ArchiveService(tools: tools).add(options, tracker: tracker)
        poller.cancel()
        let values = samples.values
        XCTAssertTrue(values.contains { $0 > 0.05 && $0 < 0.95 }, "ara değer görülmedi: \(values.suffix(8))")
        XCTAssertTrue(FileManager.default.fileExists(atPath: options.archive.path))
    }

    func testTrackerNeverGoesBackwardsAndDoesNotDoubleCountFinishedFiles() {
        let tracker = ProgressTracker(weights: ["/a/x.bin": 100, "/a/y.bin": 100], style: .rar)
        tracker.feed(Data("Adding    /a/x.bin       ".utf8)); tracker.feed(Data("\u{8}\u{8}\u{8}\u{8} 80%".utf8)); tracker.feed(Data("\u{8}".utf8))
        let first = tracker.drain().fraction ?? -1
        XCTAssertEqual(first, 0.4, accuracy: 0.001)
        tracker.feed(Data("\u{8}\u{8}\u{8}\u{8}  5%\u{8}".utf8))          // rar ikinci geçişte yüzdeyi yeniden başlatır
        XCTAssertGreaterThanOrEqual(tracker.drain().fraction ?? -1, first, "çubuk geri gitmemeli")
        tracker.feed(Data("\u{8}\u{8}\u{8}\u{8}100%\u{8}\u{8}\u{8}\u{8}  OK\n".utf8))
        tracker.setActive(candidates: [("/a/x.bin", 100)])                    // bitmiş dosya kapanmadan okunsa bile yeniden sayılmaz
        XCTAssertEqual(tracker.drain().fraction ?? -1, 0.5, accuracy: 0.001)
        tracker.setActive(candidates: [("/a/y.bin", 50)])
        XCTAssertEqual(tracker.drain().fraction ?? -1, 0.75, accuracy: 0.001)
    }

    /// RAR, birden çok büyük (sıkıştırılamaz) dosyada: çubuk yalnızca ileri gider ve büyük sıçramalar yapmaz.
    func testRarMultipleBigFilesProgressIsSmoothAndMonotonic() async throws {
        let tools = TestTools.paths()
        try XCTSkipUnless(tools.canWriteRAR, "rar yok")
        let folder = root.appendingPathComponent("coklu", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var rng = SystemRandomNumberGenerator()
        let chunk = Data((0..<1_048_576).map { _ in UInt8.random(in: 0...255, using: &rng) })
        for n in 1...3 {
            let f = folder.appendingPathComponent("d\(n).bin")
            FileManager.default.createFile(atPath: f.path, contents: nil)
            let h = try FileHandle(forWritingTo: f)
            for _ in 0..<70 { try h.write(contentsOf: chunk) }
            try h.close()
        }
        var options = CompressOptions(archive: root.appendingPathComponent("c.rar"), sources: [folder])
        options.format = .rar5
        let tracker = await ProgressTracker.forAdding(options)
        let samples = LockedSamples()
        let poller = Task {
            while !Task.isCancelled {
                if let f = tracker.drain().fraction { samples.add(f) }
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
        _ = try await ArchiveService(tools: tools).add(options, tracker: tracker)
        poller.cancel()
        let v = samples.values
        XCTAssertEqual(zip(v, v.dropFirst()).filter { $1 < $0 }.count, 0, "çubuk geri gitti")
        // Dosya bazlı sıçrama olsaydı (3 dosya) yalnızca ~3-4 farklı %5'lik dilim görülürdü.
        let buckets = Set(v.map { Int(($0 * 20).rounded(.down)) })
        XCTAssertGreaterThanOrEqual(buckets.count, 8, "çubuk takılıp sıçrıyor: \(buckets.sorted())")
        XCTAssertGreaterThan(v.last ?? 0, 0.9)
    }

    /// RAR: tek büyük dosya (klasör içinde, Finder'daki gibi) sıkıştırılırken çubuk ara değerler almalı.
    func testRarOfOneBigFileInFolderReportsIntermediateProgress() async throws {
        let tools = TestTools.paths()
        try XCTSkipUnless(tools.canWriteRAR, "rar yok")
        let folder = root.appendingPathComponent("proje", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let src = folder.appendingPathComponent("buyuk.bin")
        var rng = SystemRandomNumberGenerator()
        let chunk = Data((0..<1_048_576).map { _ in UInt8.random(in: 0...255, using: &rng) })
        FileManager.default.createFile(atPath: src.path, contents: nil)
        let h = try FileHandle(forWritingTo: src)
        for _ in 0..<80 { try h.write(contentsOf: chunk) }
        try h.close()

        var options = CompressOptions(archive: root.appendingPathComponent("a.rar"), sources: [folder])
        options.format = .rar5
        let tracker = await ProgressTracker.forAdding(options)
        let samples = LockedSamples()
        let poller = Task {
            while !Task.isCancelled {
                if let f = tracker.drain().fraction { samples.add(f) }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        _ = try await ArchiveService(tools: tools).add(options, tracker: tracker)
        poller.cancel()
        let distinct = Set(samples.values.map { ($0 * 20).rounded() })   // %5'lik dilimler
        XCTAssertGreaterThanOrEqual(distinct.count, 6, "çubuk düzgün ilerlemeli, görülen değerler: \(samples.values.enumerated().filter { $0.offset % 8 == 0 }.map { String(format: "%.2f", $0.element) })")
    }

    /// Çıkarma da aynı mekanizmayı kullanır; çok hızlı olduğundan büyük dosya gerekir: MACRAR_TEST_BIG=1 ile çalışır.
    func testZipExtractionOfOneBigFileReportsIntermediateProgress() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MACRAR_TEST_BIG"] == "1", "büyük dosya testi (MACRAR_TEST_BIG=1)")
        let tools = TestTools.paths()
        try XCTSkipUnless(tools.bsdtar != nil, "bsdtar yok")
        let src = root.appendingPathComponent("buyuk.bin")
        var rng = SystemRandomNumberGenerator()
        let chunk = Data((0..<1_048_576).map { _ in UInt8.random(in: 0...255, using: &rng) })
        FileManager.default.createFile(atPath: src.path, contents: nil)
        let h = try FileHandle(forWritingTo: src)
        for _ in 0..<1500 { try h.write(contentsOf: chunk) }      // ~1,5 GB
        try h.close()
        var options = CompressOptions(archive: root.appendingPathComponent("b.zip"), sources: [src])
        options.format = .zip; options.method = .store
        _ = try await ArchiveService(tools: tools).add(options, tracker: nil)
        try FileManager.default.removeItem(at: src)

        let svc = ArchiveService(tools: tools)
        let listing = try await svc.list(archive: options.archive)
        let dest = root.appendingPathComponent("cikti", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        var opts = ExtractOptions(destination: dest)
        opts.keepPaths = true
        let tracker = ProgressTracker.forExtraction(entries: listing.entries.filter { !$0.isDirectory }, destination: dest,
                                                          flatten: false, engine: .libarchive)
        let samples = LockedSamples()
        let poller = Task {
            while !Task.isCancelled {
                if let f = tracker.drain().fraction { samples.add(f) }
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
        _ = try await svc.extract(archive: options.archive, selection: nil, options: opts, tracker: tracker)
        poller.cancel()
        XCTAssertTrue(samples.values.contains { $0 > 0.05 && $0 < 0.95 }, "ara değer görülmedi: \(samples.values.suffix(8))")
    }
}

private final class LockedSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Double] = []
    func add(_ v: Double) { lock.lock(); items.append(v); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return items }
}
