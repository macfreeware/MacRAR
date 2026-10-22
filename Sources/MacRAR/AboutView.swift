import SwiftUI
import AppKit
import MacRARCore

/// Uygulama ve geliştirici bilgileri.
enum AppInfo {
    static let name = "MacRAR"
    static let developer = "Rafet SAPANCI"
    static let year = "2026"
    static let repositoryURL = URL(string: "https://gitlab.com/freeware2/macrar")!
    static let license = "GPL-3.0"
    static let licenseURL = URL(string: "https://gitlab.com/freeware2/macrar/-/blob/main/LICENSE")!
    static let finderExtensionID = "local.macrar.app.FinderSync"
}

/// "MacRAR Hakkında" penceresi: kimlik, geliştirici, kısa kullanım ve sistem durumu.
struct AboutView: View {
    let model: AppModel

    private enum Tab: String, CaseIterable, Identifiable {
        case general = "Genel", usage = "Kullanım", system = "Sistem"
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .general: return "Genel"
            case .usage: return "Kullanım"
            case .system: return "Sistem"
            }
        }
    }

    @State private var tab: Tab = .general
    @State private var toolRows: [ToolRow] = []
    @State private var finderState: FinderExtensionState = .unknown

    private let version = VersionInfo()

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            Divider()
            ScrollView {
                Group {
                    switch tab {
                    case .general: general
                    case .usage: usage
                    case .system: system
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 640)
        .task { await refreshSystem() }
    }

    // MARK: Üst bölüm

    private var header: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: 96, height: 96)
            Text(AppInfo.name).font(.system(size: 28, weight: .bold))
            Text(version.display).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            Text("macOS için WinRAR tarzı arşiv yöneticisi").font(.callout).foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.fill").foregroundStyle(Color.accentColor)
                Text("Geliştirici:").foregroundStyle(.secondary)
                Text(AppInfo.developer).fontWeight(.semibold)
            }
            .font(.callout)
            .padding(.top, 6)
        }
        .padding(.top, 22).padding(.bottom, 14)
    }

    // MARK: Genel

    private var general: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("RAR, ZIP, 7Z ve TAR arşivlerini açmadan içine bakın, çıkarın, sıkıştırın; Finder'a tam entegre çalışır. Arka planda RARLAB'ın rar / unrar araçlarını ve macOS'un bsdtar'ını kullanır.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                feature("archivebox", "Arşivi çıkarmadan gezin, ara, önizle")
                feature("arrow.down.doc", "Seçili dosyaları çıkar veya Finder'a sürükle")
                feature("plus.rectangle.on.folder", "RAR5/RAR4, ZIP, 7Z, TAR; parola, parça, kurtarma kaydı")
                feature("lock.shield", "Parola yöneticisi (macOS Anahtar Zinciri)")
                feature("cursorarrow.click.2", "Finder sağ tık menüsünde simgeli MacRAR girdileri")
                feature("clock", "Zaman damgalı arşiv adları (biçimi ayarlanabilir)")
            }

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "© \(AppInfo.year) \(AppInfo.developer)").font(.callout)
                Text("MacRAR özgür yazılımdır: GNU Genel Kamu Lisansı sürüm 3 (GPL-3.0) koşullarına göre kullanabilir, değiştirebilir ve yeniden dağıtabilirsiniz. Program hiçbir garanti olmaksızın sunulur.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    Link(destination: AppInfo.repositoryURL) {
                        Label { Text(verbatim: "gitlab.com/freeware2/macrar") } icon: { Image(systemName: "link") }
                    }
                    Link(destination: AppInfo.licenseURL) {
                        Label("Lisans metni (\(AppInfo.license))", systemImage: "doc.text")
                    }
                }
                .font(.callout)
            }
        }
    }

    private func feature(_ icon: String, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(Color.accentColor)
            Text(text)
        }
    }

    // MARK: Kullanım

    private var usage: some View {
        VStack(alignment: .leading, spacing: 16) {
            tip("doc.zipper", "Arşivi açma ve gezinme",
                "Bir .rar, .zip, .7z… dosyasına çift tıklayın ya da pencereye sürükleyin. Klasörlerinde çıkarmadan gezinebilir, arayabilir ve Boşluk tuşuyla dosyaları önizleyebilirsiniz. Backspace üst klasöre döner.")
            tip("arrow.down.doc", "Çıkarma",
                "Çıkar düğmesiyle hedefi seçin. Finder'da arşive sağ tıklayıp “Buraya Çıkar” ya da “arşivadı/ klasörüne Çıkar”ı kullanabilirsiniz. Arşivdeki dosyaları doğrudan Finder'a sürükleyerek de çıkarabilirsiniz.")
            tip("plus.rectangle.on.folder", "Sıkıştırma",
                "Dosya veya klasörleri seçip Ekle'ye basın: biçim (RAR, ZIP, 7Z…), yöntem, parola ve parçalara bölme burada. Finder'da sağ tık → “ad.rar olarak Sıkıştır” veya zaman damgalı sürüm en hızlı yoldur.")
            tip("lock.fill", "Parola",
                "Şifreli arşivde parola sorulur. Parolayı kaydederseniz sonraki sefer “Kayıtlı parolalar” menüsünden seçebilirsiniz. Parolalar macOS Anahtar Zinciri'nde saklanır.")
            tip("contextualmenu.and.cursorarrow", "Finder menüsü",
                "Sağ tık menüsünde MacRAR girdilerini görmek için Sistem Ayarları → Genel → Oturum Açma Öğeleri ve Eklentiler → Eklentiler → Finder bölümünden MacRAR'ı açın. “Sistem” sekmesi durumu gösterir.")

            VStack(alignment: .leading, spacing: 6) {
                Label("Klavye kısayolları", systemImage: "keyboard").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    shortcut("⌘O", "Arşiv aç")
                    shortcut("⌥⌘E", "Dosyaları çıkar…")
                    shortcut("⌥⌘Z", "RAR'a sıkıştır (⇧ ile zaman damgalı)")
                    shortcut("⌘I", "Arşiv bilgisi")
                    shortcut("Boşluk", "Önizle")
                    shortcut("⌫", "Üst klasör / arşivi kapat")
                    shortcut("⇧⌘P", "Parola yöneticisi")
                }
            }
        }
    }

    private func tip(_ icon: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).frame(width: 28).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func shortcut(_ keys: LocalizedStringKey, _ what: LocalizedStringKey) -> some View {
        GridRow {
            Text(keys).font(.system(.callout, design: .monospaced)).padding(.horizontal, 6).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
                .gridColumnAlignment(.trailing)
            Text(what).font(.callout)
        }
    }

    // MARK: Sistem

    private var system: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Komut satırı araçları", systemImage: "terminal").font(.headline)
                if toolRows.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
                    ForEach(toolRows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: row.url != nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(row.url != nil ? .green : .red)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.name + (row.version.map { "  \($0)" } ?? "")).fontWeight(.medium)
                                Text(row.url?.path ?? row.missingHint).font(.caption).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Finder sağ tık menüsü", systemImage: "contextualmenu.and.cursorarrow").font(.headline)
                HStack(spacing: 8) {
                    Image(systemName: finderState.symbol).foregroundStyle(finderState.color)
                    Text(finderState.text)
                }
                if finderState == .disabled {
                    Text("Etkinleştirmek için Terminal'de:").font(.caption).foregroundStyle(.secondary)
                    Text("pluginkit -e use -i \(AppInfo.finderExtensionID) && killall Finder")
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Label("Ortam", systemImage: "desktopcomputer").font(.headline)
                Text("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)").font(.callout).foregroundStyle(.secondary)
                Text(Bundle.main.bundleURL.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }

            Button("Yenile") { Task { await refreshSystem() } }
        }
    }

    // MARK: Alt bilgi

    private var footer: some View {
        Text("MacRAR, RARLAB veya WinRAR ile bağlantılı değildir. Birlikte gelen unrar, RARLAB’ın kendi lisansıyla dağıtılan ücretsiz ve ayrı bir programdır; MacRAR’ın GPL lisansı onu kapsamaz. rar ücretli bir üründür ve MacRAR ile gelmez.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 20).padding(.vertical, 10)
    }

    // MARK: Veri

    struct ToolRow: Identifiable {
        let id: String
        let name: String
        let url: URL?
        let version: String?
        let missingHint: String
    }

    enum FinderExtensionState {
        case unknown, enabled, disabled, missing

        var symbol: String {
            switch self {
            case .enabled: return "checkmark.circle.fill"
            case .disabled: return "exclamationmark.triangle.fill"
            case .missing, .unknown: return "questionmark.circle.fill"
            }
        }
        var color: Color {
            switch self {
            case .enabled: return .green
            case .disabled: return .orange
            case .missing, .unknown: return .secondary
            }
        }
        var text: String {
            switch self {
            case .enabled: return String(localized: "Etkin: MacRAR girdileri sağ tık menüsünde görünür.")
            case .disabled: return String(localized: "Kapalı: sağ tık menüsünde MacRAR girdileri görünmez.")
            case .missing: return String(localized: "Eklenti kurulu değil (uygulama paketsiz çalışıyor olabilir).")
            case .unknown: return String(localized: "Durum okunamadı.")
            }
        }
    }

    private func refreshSystem() async {
        let tools = model.tools
        async let rar = row("rar", tools.rar, [], String(localized: "RAR oluşturmak için gerekli (ücretli, deneme sürümü var): Kurulum Yardımcısı’ndan kurulur"))
        async let unrar = row("unrar", tools.unrar, [], String(localized: "RAR arşivlerini açmak için, ücretsiz (MacRAR ile birlikte gelir)"))
        async let tar = row("bsdtar", tools.bsdtar, ["--version"], String(localized: "ZIP/7Z/TAR için (macOS ile gelir)"))
        toolRows = await [rar, unrar, tar]
        finderState = await Self.probeFinderExtension()
    }

    private func row(_ name: String, _ url: URL?, _ args: [String], _ hint: String) async -> ToolRow {
        let version = url == nil ? nil : await ToolProbe.version(of: url!, arguments: args)
        return ToolRow(id: name, name: name, url: url, version: version, missingHint: String(localized: "Bulunamadı.") + " " + hint)
    }

    /// `pluginkit -m` çıktısında satır başı "+" etkin, "-" kapalıdır.
    static func probeFinderExtension() async -> FinderExtensionState {
        guard let r = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/pluginkit"),
                                                   ["-mA", "-i", AppInfo.finderExtensionID]) else { return .unknown }
        return parseFinderExtensionState(r.text)
    }

    static func parseFinderExtensionState(_ text: String) -> FinderExtensionState {
        guard let line = text.split(separator: "\n").first(where: { $0.contains(AppInfo.finderExtensionID) }) else { return .missing }
        let mark = line.trimmingCharacters(in: .whitespaces).first
        if mark == "+" { return .enabled }
        if mark == "-" { return .disabled }
        return .disabled // işaretsiz: henüz seçilmemiş = etkin değil
    }
}
