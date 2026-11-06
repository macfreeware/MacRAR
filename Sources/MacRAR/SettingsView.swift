import SwiftUI
import AppKit
import MacRARCore

struct SettingsView: View {
    let model: AppModel
    @AppStorage("rarPath") private var rarPath = ""
    @AppStorage("unrarPath") private var unrarPath = ""
    @AppStorage("bsdtarPath") private var bsdtarPath = ""
    @AppStorage("stampPattern") private var stampPattern = ArchiveNaming.defaultPattern
    @AppStorage("stampSeparator") private var stampSeparator = ArchiveNaming.defaultSeparator
    @AppStorage("quickReveal") private var quickReveal = true
    @AppStorage("updateAutoCheck") private var updateAutoCheck = true
    @State private var customMode = false
    @State private var language = AppLanguage.saved

    private static let customTag = "•özel"

    var body: some View {
        TabView {
            generalTab.tabItem { Label("Genel", systemImage: "gearshape") }
            finderTab.tabItem { Label("Finder", systemImage: "contextualmenu.and.cursorarrow") }
            fileTypesTab.tabItem { Label("Dosya türleri", systemImage: "doc.zipper") }
            toolsTab.tabItem { Label("Araçlar", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 600)
        .onAppear { customMode = !ArchiveNaming.presets.contains { $0.pattern == stampPattern } }
    }

    // MARK: Genel

    private var generalTab: some View {
        Form {
            Section("Görünüm") {
                Toggle("Gizli dosyaları göster", isOn: Binding(get: { model.showHidden }, set: { _ in model.toggleHidden() }))
            }
            Section {
                LanguageChooser(language: $language)
            }
            Section {
                Button("Parola Yöneticisi…") {
                    NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
                    model.showPasswordManager()
                }
            } header: {
                Text("Parolalar")
            } footer: {
                Text("Şifreli arşivlerde kullandığınız parolaları macOS Anahtar Zinciri’nde saklayıp sonra listeden seçebilirsiniz.")
            }
            Section {
                Toggle("Güncellemeleri otomatik denetle", isOn: $updateAutoCheck)
                Button("Güncellemeleri Denetle…") { UpdateController.shared.checkFromMenu() }
            } header: {
                Text("Güncellemeler")
            } footer: {
                Text("Günde en çok bir kez GitLab’a son sürüm sorulur; bu Mac hakkında bilgi gönderilmez.")
            }
        }
        .formStyle(.grouped)
        .frame(height: language != AppLanguage.atLaunch ? 480 : 440)
    }

    // MARK: Finder

    private var finderTab: some View {
        Form {
            Section {
                Picker("Zaman damgası biçimi", selection: patternChoice) {
                    ForEach(ArchiveNaming.presets) { p in
                        Text("\(ArchiveNaming.timestamp(pattern: p.pattern))   (\(p.pattern))").tag(p.pattern)
                    }
                    Text("Özel…").tag(Self.customTag)
                }
                if customMode {
                    TextField("Desen (örn. yyyy-MM-dd_HH-mm-ss)", text: $stampPattern)
                    if !ArchiveNaming.isValid(pattern: stampPattern) {
                        Label("Geçerli bir desen girin.", systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                }
                Picker("Addan sonra ayırıcı", selection: $stampSeparator) {
                    Text("Tire ( - )").tag("-")
                    Text("Alt çizgi ( _ )").tag("_")
                    Text("Boşluk").tag(" ")
                    Text("Yok").tag("")
                }
                LabeledContent("Örnek") {
                    Text(example).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                Toggle("Bitince Finder’da göster", isOn: $quickReveal)
            } header: {
                Text("Hızlı sıkıştırma")
            } footer: {
                Text("Desen harfleri: yyyy yıl, MM ay, dd gün, HH saat, mm dakika, ss saniye.")
            }
            FinderMenuSection()
        }
        .formStyle(.grouped)
        .frame(height: 560)
    }

    // MARK: Dosya türleri

    private var fileTypesTab: some View {
        Form { DefaultAppSection() }
            .formStyle(.grouped)
            .frame(height: 560)
    }

    // MARK: Araçlar

    private var toolsTab: some View {
        Form {
            Section {
                toolRow("rar", detected: model.tools.rar, path: $rarPath,
                        note: "RAR arşivi oluşturmak ve düzenlemek için gerekir (ücretli, RARLAB).")
                toolRow("unrar", detected: model.tools.unrar, path: $unrarPath,
                        note: "RAR arşivlerini açmak için (ücretsiz, MacRAR ile birlikte gelir). Yoksa ‘rar’ kullanılır.")
                toolRow("bsdtar", detected: model.tools.bsdtar, path: $bsdtarPath,
                        note: "ZIP, 7Z, TAR.GZ gibi biçimler için (macOS ile birlikte gelir).")
            } header: {
                Text("Komut satırı araçları")
            } footer: {
                Text("Özel yol boşsa araçlar /opt/homebrew/bin, /usr/local/bin, PATH ve MacRAR’ın kendi klasöründe aranır.")
            }
            if model.tools.rar == nil {
                Section {
                    HStack(spacing: 10) {
                        Button("rar’ı RARLAB’dan indir ve kur") { Task { await model.installRAR() } }
                            .disabled(model.rarInstallProgress != nil)
                        if let progress = model.rarInstallProgress {
                            ProgressView().controlSize(.small)
                            Text(progress).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let message = model.rarInstallMessage {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("rar kurulumu")
                } footer: {
                    Text("\(ToolGuidance.rarAutoInstallNote) \(ToolGuidance.rarLicenseNote)")
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: model.tools.rar == nil ? 640 : 470)
    }

    private var patternChoice: Binding<String> {
        Binding(get: { customMode ? Self.customTag : stampPattern },
                set: { v in
                    if v == Self.customTag { customMode = true } else { customMode = false; stampPattern = v }
                })
    }

    private var example: String {
        let pattern = ArchiveNaming.isValid(pattern: stampPattern) ? stampPattern : ArchiveNaming.defaultPattern
        return ArchiveNaming.fileName(base: String(localized: "klasör"), stamp: (pattern, stampSeparator), ext: "rar")
    }

    @ViewBuilder
    private func toolRow(_ name: String, detected: URL?, path: Binding<String>, note: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: detected != nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(detected != nil ? .green : .red)
                Text(name).font(.headline)
                Text(detected?.path ?? String(localized: "bulunamadı")).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            HStack {
                TextField("Özel yol (isteğe bağlı)", text: path)
                    .onSubmit { model.reloadTools() }
                Button("Seç…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
                    if panel.runModal() == .OK, let u = panel.url { path.wrappedValue = u.path; model.reloadTools() }
                }
                Button("Algıla") { path.wrappedValue = ""; model.reloadTools() }
            }
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .onChange(of: path.wrappedValue) { model.reloadTools() }
    }
}


/// Finder sağ tık menüsü (Finder Sync eklentisi) durumu ve aç/kapat anahtarı.
struct FinderMenuSection: View {
    @State private var state: AboutView.FinderExtensionState = .unknown
    @State private var busy = false
    @State private var needsRestart = false
    @State private var message: String?

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { state == .enabled }, set: { on in Task { await apply(enabled: on) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MacRAR girdilerini sağ tık menüsünde göster")
                    Label(state.text, systemImage: state.symbol)
                        .font(.caption).foregroundStyle(state.color)
                }
            }
            .disabled(busy || state == .missing || state == .unknown)

            if needsRestart {
                HStack {
                    Text("Değişikliğin Finder’da görünmesi için Finder’ın yeniden başlaması gerekir.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Finder’ı yeniden başlat") { Task { await restartFinder() } }.disabled(busy)
                }
            }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
        } header: {
            Text("Sağ tık menüsü")
        } footer: {
            Text("Finder’da bir dosya veya klasöre sağ tıklayınca MacRAR girdileri (Arşive Ekle, Buraya Aç…) görünür. Kapatırsanız bu girdiler kaybolur; MacRAR uygulaması çalışmaya devam eder.")
        }
        .task { state = await AboutView.probeFinderExtension() }
    }

    private func apply(enabled: Bool) async {
        busy = true; defer { busy = false }
        message = nil
        let ok = await SetupAssistant.setFinderExtension(enabled: enabled)
        state = await AboutView.probeFinderExtension()
        if ok { needsRestart = true } else { message = enabled ? String(localized: "Eklenti etkinleştirilemedi.") : String(localized: "Eklenti kapatılamadı.") }
    }

    private func restartFinder() async {
        busy = true; defer { busy = false }
        await SetupAssistant.restartFinder()
        needsRestart = false
        message = String(localized: "Finder yeniden başlatıldı.")
        try? await Task.sleep(for: .seconds(1))
        state = await AboutView.probeFinderExtension()
    }
}
