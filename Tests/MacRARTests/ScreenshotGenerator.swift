import XCTest
import SwiftUI
import AppKit
import MacRARCore
@testable import MacRAR

/// README için ekran görüntüsü üretici. EKRAN YAKALAMAZ: arayüz görünümleri bellekte (ekran dışı pencerede) çizilir ve
/// yalnızca bu dosyadaki uydurma örnek veriyi gösterir. Normal test çalışmalarında atlanır.
///
///     MACRAR_SCREENSHOTS=docs/screenshots swift test --filter ScreenshotGenerator
/// Ekran dışı çizim penceresi: etkin (anahtar) pencere gibi davranır; böylece kenar çubuğu/seçim soluk görünmez.
private final class OffscreenWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

@MainActor
final class ScreenshotGenerator: XCTestCase {
    var outDir: URL!
    var demo: URL!
    var model: AppModel { AppModel.shared }
    let fm = FileManager.default

    override func setUp() async throws {
        let path = ProcessInfo.processInfo.environment["MACRAR_SCREENSHOTS"] ?? ""
        try XCTSkipIf(path.isEmpty, "MACRAR_SCREENSHOTS=<klasör> verilmedi")
        outDir = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: fm.currentDirectoryPath)).standardizedFileURL
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        model.tools = TestTools.paths()
        model.vault = PasswordVault(store: InMemoryPasswordStore())
        SheetPanel.isEnabled = false
        model.hasVisibleWindow = { true }          // hızlı oturum / bağımsız pencere yolları devreye girmesin
        model.endQuickSessionTakeover()
        model.onQuickSessionEnd = {}
        UserDefaults.standard.set(false, forKey: "quickReveal")
        // Test sürecinin simgesi/sürümü yerine uygulamanın gerçek simgesi ve geçerli sürüm (build/MacRAR.app'ten) gösterilsin.
        let bundle = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("build/MacRAR.app")
        if let icon = NSImage(contentsOf: bundle.appendingPathComponent("Contents/Resources/AppIcon.icns")) {
            NSApplication.shared.applicationIconImage = icon
        }
        let plist = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        Brand.versionTextOverride = (plist?["CFBundleShortVersionString"] as? String).map { "v\($0)" }
        // Örnek klasör: yol çubuğunda kişisel bir ad görünmesin diye /Users/Shared altında.
        demo = URL(fileURLWithPath: "/Users/Shared/MacRAR-Demo", isDirectory: true)
        try? fm.removeItem(at: demo)
        try fm.createDirectory(at: demo, withIntermediateDirectories: true)
        try await makeDemoFiles()
    }

    override func tearDown() async throws {
        model.closeArchive()
        model.sheet = nil
        if let demo { try? fm.removeItem(at: demo) }
    }

    // MARK: Örnek veri

    private func write(_ text: String, _ rel: String, under base: URL) throws {
        let u = base.appendingPathComponent(rel)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
    }

    private func pack(_ name: String, _ files: [String: String], password: String? = nil, format: ArchiveFormat = .zip) async throws {
        let src = fm.temporaryDirectory.appendingPathComponent("shot-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: src) }
        for (rel, text) in files { try write(text, rel, under: src) }
        var o = CompressOptions(archive: demo.appendingPathComponent(name),
                                sources: try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil))
        o.format = format
        o.password = password
        try await model.service.add(o)
    }

    /// Tekrarlanabilir (sabit tohumlu) sözde-rastgele metin ve ikili veri: gerçekçi sıkıştırma oranları verir.
    private struct LCG { var state: UInt64
        mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 33 } }

    private func words(_ count: Int, seed: UInt64) -> String {
        let lex = ["rapor", "satış", "bölge", "marmara", "ege", "toplam", "çeyrek", "büyüme", "maliyet", "gelir", "müşteri", "ürün", "stok",
                   "hedef", "plan", "bütçe", "analiz", "özet", "sonuç", "karşılaştırma", "yıllık", "aylık", "tablo", "grafik", "dönem", "oran"]
        var g = LCG(state: seed)
        return (0..<count).map { _ in lex[Int(g.next()) % lex.count] + (g.next() % 7 == 0 ? ".\n" : " ") }.joined()
    }

    private func randomBytes(_ count: Int, seed: UInt64) -> Data {
        var g = LCG(state: seed)
        return Data((0..<count).map { _ in UInt8(truncatingIfNeeded: g.next()) })
    }

    private func makeDemoFiles() async throws {
        func put(_ rel: String, _ data: Data, in dir: URL) throws {
            let u = dir.appendingPathComponent(rel)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: u)
        }
        func zip(_ name: String, password: String? = nil, format: ArchiveFormat = .zip, files: (URL) throws -> Void) async throws {
            let src = fm.temporaryDirectory.appendingPathComponent("shot-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: src) }
            try fm.createDirectory(at: src, withIntermediateDirectories: true)
            try files(src)
            var o = CompressOptions(archive: demo.appendingPathComponent(name),
                                    sources: try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil))
            o.format = format
            o.password = password
            try await model.service.add(o)
        }
        func rapor(_ d: URL, revised: Bool) throws {
            try put("Rapor.docx.txt", Data(words(revised ? 9_000 : 8_000, seed: revised ? 11 : 10).utf8), in: d)
            try put("Satış-verileri.csv", Data(words(30_000, seed: 20).utf8), in: d)
            try put("Özet.md", Data(("# Özet\n" + words(300, seed: revised ? 31 : 30)).utf8), in: d)
            try put("grafik-1.png", randomBytes(180_000, seed: 40), in: d)
            if !revised { try put("grafik-2.png", randomBytes(240_000, seed: 41), in: d) }
            try put("Notlar.txt", Data(words(1_500, seed: 50).utf8), in: d)
            if revised { try put("Ek-bölüm.txt", Data(words(2_500, seed: 60).utf8), in: d) }
        }
        try await zip("Rapor-v1.zip") { try rapor($0, revised: false) }
        try await zip("Rapor-v2.zip") { try rapor($0, revised: true) }
        func proje(_ d: URL) throws {
            try put("src/main.swift", Data(words(2_000, seed: 70).utf8), in: d)
            try put("src/model.swift", Data(words(3_000, seed: 71).utf8), in: d)
            try put("docs/README.md", Data(("# Proje\n" + words(400, seed: 72)).utf8), in: d)
            try put("assets/logo.png", randomBytes(90_000, seed: 73), in: d)
        }
        try await zip("Proje.zip", files: proje)
        try await zip("Gizli-Belgeler.zip", password: "demo", files: proje)
        if model.tools.canWriteRAR { try await zip("Yedek.rar", format: .rar5, files: proje) }
        try put("Yeni-not.txt", Data(words(500, seed: 80).utf8), in: demo.appendingPathComponent("Eklenecek"))
        try put("Tablo.csv", Data(words(8_000, seed: 81).utf8), in: demo.appendingPathComponent("Eklenecek"))
        try put("Fotoğraf.jpg", randomBytes(350_000, seed: 82), in: demo.appendingPathComponent("Eklenecek"))
    }

    // MARK: Çizim

    /// Görünümü ekran dışı bir pencerede çizip PNG olarak yazar (2x). Ekran yakalama yoktur.
    private func render<V: View>(_ view: V, size: CGSize, name: String, settle: Double = 1.2) async throws {
        let root = view
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)
        let window = OffscreenWindow(contentRect: CGRect(origin: CGPoint(x: -5000, y: -5000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderBack(nil)
        try await Task.sleep(for: .seconds(settle))
        host.layoutSubtreeIfNeeded()
        let scale = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return XCTFail("rep") }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: outDir.appendingPathComponent(name + ".png"))
        window.orderOut(nil)
    }

    private func waitRows(_ names: [String]) async throws {
        for _ in 0..<100 {
            if Set(model.rows.map(\.name)).isSuperset(of: names) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("satırlar yüklenmedi")
    }

    // MARK: Görüntüler

    func testGenerateAll() async throws {
        // 1) Ana pencere: klasör görünümü, iki ZIP seçili (Birleştir/Karşılaştır etkin)
        model.openFolder(demo)
        try await waitRows(["Rapor-v1.zip", "Rapor-v2.zip", "Proje.zip"])
        model.selection = Set(model.rows.filter { ["Rapor-v1.zip", "Rapor-v2.zip"].contains($0.name) }.map(\.id))
        try await render(MainView(model: model), size: CGSize(width: 1120, height: 720), name: "ana-pencere-uretilen")

        // 2) Açık ZIP: CRC, sıkıştırılmış boyut, kilit simgesi
        await model.loadArchive(demo.appendingPathComponent("Rapor-v1.zip"))
        try await render(MainView(model: model), size: CGSize(width: 1120, height: 720), name: "acik-zip-uretilen")
        model.closeArchive()

        // 3) Arşivle penceresi (yeni arşiv; kaynak boyutu ve tahmini arşiv boyutu satırıyla)
        let sources = [demo.appendingPathComponent("Eklenecek")]
        let req = AddRequest(sources: sources, defaultName: "Eklenecek", defaultFolder: demo)
        try await render(AddSheet(model: model, request: req), size: CGSize(width: 540, height: 650), name: "arsivle-uretilen", settle: 2.5)

        // 4) Karşılaştır
        let a = try await model.service.list(archive: demo.appendingPathComponent("Rapor-v1.zip")).entries
        let b = try await model.service.list(archive: demo.appendingPathComponent("Rapor-v2.zip")).entries
        let cmp = CompareRequest(firstName: "Rapor-v1.zip", secondName: "Rapor-v2.zip", result: ArchiveComparison.compare(a, b))
        try await render(CompareSheet(request: cmp), size: CGSize(width: 640, height: 520), name: "karsilastir-uretilen")

        // 5) Parola yöneticisi (ipucu alanıyla)
        let vault = PasswordVault(store: InMemoryPasswordStore())
        model.vault = vault
        await vault.add(name: "Muhasebe arşivleri", password: "örnek-parola-1", hint: "2024–2026 yıl sonu yedekleri")
        await vault.add(name: "Proje belgeleri", password: "örnek-parola-2", hint: "Müşteri teslim paketleri")
        await vault.add(name: "Kişisel", password: "örnek-parola-3")
        try await render(PasswordManagerSheet(model: model), size: CGSize(width: 520, height: 430), name: "parola-yoneticisi-uretilen")
    }
}
