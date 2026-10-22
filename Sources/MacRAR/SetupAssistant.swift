import SwiftUI
import AppKit
import MacRARCore

/// Kurulum sonrası kontrol listesi. Kurulum paketi (`.pkg`) otomatikleştirebildiği her şeyi kendisi yapar;
/// kullanıcının karar vermesi ya da sistemin onay istemesi gereken adımlar burada görünür.
enum SetupAssistant {
    /// İlk açılışta bir kez gösterilir; "Bitti" ile kapatılınca bir daha çıkmaz (Yardım menüsünden her zaman açılır).
    static let doneKey = "setupAssistantDone"

    static var needsFirstRun: Bool { !UserDefaults.standard.bool(forKey: doneKey) }
    static func markDone() { UserDefaults.standard.set(true, forKey: doneKey) }

    /// Finder eklentisini etkinleştirir (kullanıcının "Etkinleştir" tıklaması).
    static func enableFinderExtension() async -> Bool { await setFinderExtension(enabled: true) }

    /// Finder eklentisini açar/kapatır (`pluginkit -e use|ignore`). Menünün görünmesi/kaybolması için Finder'ın yeniden başlaması gerekir.
    static func setFinderExtension(enabled: Bool) async -> Bool {
        guard let r = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/pluginkit"),
                                                   ["-e", enabled ? "use" : "ignore", "-i", AppInfo.finderExtensionID]) else { return false }
        return r.exitCode == 0
    }

    /// Finder'ı yeniden başlatır (eklenti menüsünün görünmesi için gerekli).
    static func restartFinder() async {
        _ = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/killall"), ["Finder"])
    }
}

struct SetupAssistantView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var finder: AboutView.FinderExtensionState = .unknown
    @State private var rarOK = false
    @State private var unrarOK = false
    @State private var unarOK = false
    @State private var defaultsOK = false
    @State private var message: String?
    @State private var busy = false

    private var installed: Bool { DefaultApps.isInstalledInApplications() }
    private var allGood: Bool { (rarOK || unrarOK || unarOK) && finder == .enabled && defaultsOK && installed }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    toolsStep
                    finderStep
                    defaultsStep
                    if !installed { locationStep }
                    if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 580, height: 700)
        .task { await refresh() }
    }

    // MARK: Bölümler

    private var header: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text("MacRAR'a hoş geldiniz").font(.system(size: 22, weight: .bold))
            Text(allGood ? "Her şey hazır. Keyifli kullanımlar!" : "Birkaç adımda her şeyi hazırlayalım.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(.vertical, 16)
    }

    private var toolsStep: some View {
        let installing = model.rarInstallProgress != nil
        return step(ok: rarOK && unrarOK, warn: !(rarOK || unrarOK || unarOK), title: "RAR araçları",
             detail: rarOK && unrarOK ? "rar ve unrar hazır: RAR arşivlerini açabilir ve oluşturabilirsiniz."
                 : unrarOK ? "unrar hazır (MacRAR ile birlikte gelir): RAR arşivlerini açabilirsiniz. RAR oluşturmak için RARLAB’ın rar aracı gerekir."
                 : unarOK ? "RAR arşivleri unar ile açılıyor (salt okunur). RAR oluşturmak ve düzenlemek için RARLAB’ın rar aracı gerekir."
                 : "rar / unrar bulunamadı. RAR arşivleri için gereklidir (ZIP, 7Z ve TAR bunlarsız da çalışır).") {
            if !(rarOK && unrarOK) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Button(rarOK ? "RAR araçlarını RARLAB’dan indir ve kur" : "rar’ı RARLAB’dan indir ve kur") { Task { await installRAR() } }
                            .disabled(installing)
                        if let progress = model.rarInstallProgress {
                            ProgressView().controlSize(.small)
                            Text(progress).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(ToolGuidance.rarAutoInstallNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(ToolGuidance.rarLicenseNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup("Elle kurmak isterseniz") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(ToolGuidance.rarInstallSteps).font(.callout).fixedSize(horizontal: false, vertical: true)
                            Link("RARLAB indirme sayfasını aç (\(ToolGuidance.rarlabDownloadText))", destination: ToolGuidance.rarlabDownloadURL)
                                .font(.callout).focusEffectDisabled()
                        }
                        .padding(.top, 4)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private var finderStep: some View {
        step(ok: finder == .enabled, warn: finder != .enabled, title: "Finder sağ tık menüsü",
             detail: finder == .enabled ? "Etkin: Finder'da sağ tıklayınca MacRAR girdileri görünür."
                 : finder == .missing ? "Eklenti bulunamadı (uygulama paketsiz çalışıyor olabilir)."
                 : "Kapalı: MacRAR girdileri sağ tık menüsünde görünmez.") {
            HStack {
                if finder == .disabled || finder == .unknown {
                    Button("Etkinleştir") { Task { await enableFinder() } }.disabled(busy)
                }
                Button("Finder'ı yeniden başlat") { Task { await restartFinder() } }.disabled(busy)
                    .help("Menü görünmüyorsa Finder'ın bir kez yeniden başlaması gerekir")
            }
        }
    }

    private var defaultsStep: some View {
        step(ok: defaultsOK, warn: false, title: "Varsayılan uygulama",
             detail: defaultsOK ? "RAR ve 7Z arşivleri MacRAR ile açılır."
                 : "İsteğe bağlı: arşive çift tıklayınca MacRAR açılsın (macOS onay isteyecektir).") {
            if !defaultsOK {
                Button("RAR ve 7Z için MacRAR'ı varsayılan yap") { Task { await makeDefaults() } }
                    .disabled(busy || !installed)
            }
        }
    }

    private var locationStep: some View {
        step(ok: false, warn: true, title: "Uygulamalar klasörü",
             detail: "MacRAR Uygulamalar klasöründe değil (\(Bundle.main.bundleURL.deletingLastPathComponent().path)). Varsayılan uygulama ve Finder menüsü için onu Uygulamalar klasörüne taşıyın.") { EmptyView() }
    }

    private var footer: some View {
        HStack {
            Button("Yenile") { Task { await refresh() } }
            Spacer()
            Button("Daha sonra") { dismiss() }
            Button("Bitti") { SetupAssistant.markDone(); dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    // MARK: Satır bileşeni

    private func step<Extra: View>(ok: Bool, warn: Bool, title: LocalizedStringKey, detail: LocalizedStringKey,
                                   @ViewBuilder extra: () -> Extra) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : (warn ? "exclamationmark.triangle.fill" : "circle"))
                .font(.title2).foregroundStyle(ok ? Color.green : (warn ? Color.orange : Color.secondary))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                extra()
            }
        }
    }

    // MARK: Eylemler

    private func refresh() async {
        let t = model.tools
        rarOK = t.rar != nil
        unrarOK = t.unrar != nil
        unarOK = t.canReadRARWithUnar
        finder = await AboutView.probeFinderExtension()
        defaultsOK = DefaultApps.kinds.filter(\.primary).allSatisfy { DefaultApps.current(for: $0).isMacRAR }
    }

    private func installRAR() async {
        await model.installRAR()
        message = model.rarInstallMessage
        await refresh()
    }

    private func enableFinder() async {
        busy = true; defer { busy = false }
        let ok = await SetupAssistant.enableFinderExtension()
        message = ok ? String(localized: "Eklenti etkinleştirildi. Menünün görünmesi için Finder'ı yeniden başlatın.") : String(localized: "Eklenti etkinleştirilemedi.")
        await refresh()
    }

    private func restartFinder() async {
        busy = true; defer { busy = false }
        await SetupAssistant.restartFinder()
        message = String(localized: "Finder yeniden başlatıldı. Bir dosyaya sağ tıklayıp MacRAR girdilerine bakın.")
        try? await Task.sleep(for: .seconds(1))
        await refresh()
    }

    private func makeDefaults() async {
        busy = true; defer { busy = false }
        for kind in DefaultApps.kinds where kind.primary && !DefaultApps.current(for: kind).isMacRAR {
            do { try await DefaultApps.makeDefault(kind) }
            catch { message = String(localized: "Değiştirilemedi (.\(kind.ext)): \(error.localizedDescription)"); await refresh(); return }
        }
        message = nil
        await refresh()
    }
}
