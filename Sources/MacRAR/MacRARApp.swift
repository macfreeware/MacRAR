import SwiftUI
import AppKit
import MacRARCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Dock simgesine tıklanınca (gizli pencere varsa) ana pencere gösterilir ve oturum kullanıcıya devredilir.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if AppModel.shared.launchedByFinderCommand || !AppModel.shared.hasVisibleWindow() {
            AppModel.shared.endQuickSessionTakeover()
            AppModel.shared.revealMainWindows()
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLanguage.atLaunch = .saved
        // Finder'dan başlatılan hızlı işlemler: pencere yalnızca gerekirse açılır, iş bitince uygulama kapanır.
        // Finder eklentisiyle paylaşılan, kuruluma özgü gizli anahtarı (yoksa) üret.
        do { try FinderToken.ensureExists() } catch { NSLog("MacRAR: Finder anahtarı oluşturulamadı: \(error.localizedDescription)") }
        AppModel.shared.publishFinderState()   // klasör artık var: Finder menüsü rar durumunu okuyabilsin
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            // Kullanıcı rar'ı başka yoldan kurduysa/kaldırdıysa menü doğru kalsın.
            MainActor.assumeIsolated { AppModel.shared.reloadTools() }
        }
        AppModel.shared.onQuickSessionEnd = { NSApp.terminate(nil) }
        AppModel.shared.startUIWatcher()
        UpdateController.shared.startAutomaticChecks()
        // Alt süreçlere yazarken kapanan boru uygulamayı düşürmesin.
        signal(SIGPIPE, SIG_IGN)
        // `swift run` ile paketlenmeden başlatılsa da normal bir uygulama gibi davran.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        ArchiveService.cleanTemporaryFiles()
    }
}

@main
struct MacRARApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        #if DEBUG
        Updater.runSelfTestIfRequested()
        #endif
    }

    var body: some Scene {
        // Tek pencere: arşiv dosyasıyla açılışta da ikinci bir pencere oluşmaz.
        Window("MacRAR", id: "main") {
            MainView(model: .shared)
                .frame(minWidth: 880, minHeight: 540)
                .onOpenURL { url in
                    if url.scheme == FinderIntegration.scheme { AppModel.shared.handleFinderURL(url) }
                    else { AppModel.shared.handleOpen([url]) }
                }
        }
        .defaultSize(width: 1120, height: 720)
        .commands { AppCommands(model: .shared) }

        // "MacRAR Hakkında": uygulama menüsünden açılır; açılışta gösterilmez.
        Window("MacRAR Hakkında", id: "about") {
            AboutView(model: .shared)
        }
        .defaultLaunchBehavior(.suppressed)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        // "Kurulum Yardımcısı": ilk açılışta ve Yardım menüsünden; açılışta kendiliğinden gösterilmez.
        Window("MacRAR Kurulum Yardımcısı", id: "setup") {
            SetupAssistantView(model: .shared)
        }
        .defaultLaunchBehavior(.suppressed)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        // "MacRAR'ı Kaldır": Yardım menüsünden; açılışta gösterilmez.
        Window("MacRAR’ı Kaldır", id: "uninstall") {
            AppRemovalView()
        }
        .defaultLaunchBehavior(.suppressed)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView(model: .shared)
        }
    }
}

/// Uygulama menüsündeki "MacRAR Hakkında" girdisi.
struct AboutCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("MacRAR Hakkında") {
            openWindow(id: "about")
            NSApplication.shared.activate()
        }
    }
}

/// Yardım menüsündeki "Kurulum Yardımcısı…" girdisi.
struct SetupCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Kurulum Yardımcısı…") {
            openWindow(id: "setup")
            NSApplication.shared.activate()
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            AboutCommand()
            Button("Güncellemeleri Denetle…") { UpdateController.shared.checkFromMenu() }
        }
        CommandGroup(after: .help) {
            SetupCommand()
            Divider()
            UninstallCommand()
        }
        CommandGroup(replacing: .newItem) {
            Button("Arşiv Aç…") { model.promptOpenArchive() }
                .keyboardShortcut("o")
            Button("Klasör Aç…") { model.promptOpenFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Arşivi Kapat") { model.closeArchive() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(!model.isInArchive)
        }

        CommandMenu("Komutlar") {
            Button("Parola Yöneticisi…") { model.showPasswordManager() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            Button("Arşive Ekle…") { model.showAdd() }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(!model.canAdd)
            Button("Buraya Çıkar (arşivin klasörüne)") { model.quickExtract(model.selectedArchiveFiles, intoSubfolder: false) }
                .disabled(model.isInArchive || model.selectedArchiveFiles.isEmpty)
            Divider()
            Button("RAR’a Sıkıştır (ad.rar)") { model.quickCompress(model.selectedFileURLs, timestamped: false) }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(model.isInArchive || model.selectedFileURLs.isEmpty)
            Button("RAR’a Sıkıştır (zaman damgalı)") { model.quickCompress(model.selectedFileURLs, timestamped: true) }
                .keyboardShortcut("z", modifiers: [.command, .option, .shift])
                .disabled(model.isInArchive || model.selectedFileURLs.isEmpty)
            Button("ZIP’e Sıkıştır (ad.zip)") { model.quickCompress(model.selectedFileURLs, timestamped: false, format: .zip) }
                .disabled(model.isInArchive || model.selectedFileURLs.isEmpty)
            Button("ZIP’e Sıkıştır (zaman damgalı)") { model.quickCompress(model.selectedFileURLs, timestamped: true, format: .zip) }
                .disabled(model.isInArchive || model.selectedFileURLs.isEmpty)
            Divider()
            Button("Dosyaları Çıkar…") { model.showExtract() }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(!model.canExtract)
            Button("Buraya Çıkar") { Task { await model.extractHereQuick() } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!model.canExtract)
            Divider()
            Button("Arşivleri Birleştir…") { model.beginMerge() }
                .disabled(!model.canMerge)
            Button("Arşivleri Karşılaştır…") { model.showCompare() }
                .disabled(!model.canCompare)
            Divider()
            Button("Arşivi Sına") { Task { await model.runTest() } }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(!model.canTest)
            Button("Önizle") { model.quickLook() }
                .disabled(!model.canView)
            Button("Sil") { model.confirmDelete() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!model.canDelete)
            Button("Yeniden Adlandır…") { model.promptRename() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(!(model.isInArchive && model.canModifyArchive && model.selection.count == 1))
            Divider()
            Button("Arşiv Bilgisi") { model.showInfo() }
                .keyboardShortcut("i")
                .disabled(!model.canInfo)
            Button("Yorum Ekle/Değiştir…") { model.promptComment() }
                .disabled(!(model.isInArchive && model.canEditRARFeatures))
            Button("Kurtarma Kaydı Ekle…") { model.promptRecoveryRecord() }
                .disabled(!(model.isInArchive && model.canEditRARFeatures))
            Button("Arşivi Kilitle…") { model.confirmLock() }
                .disabled(!(model.isInArchive && model.canEditRARFeatures))
            Button("Arşivi Onar") { Task { await model.runRepair() } }
                .disabled(!model.canRepair)
        }

        CommandGroup(after: .toolbar) {
            Button("Üst Klasör") { model.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Yenile") { model.reloadCurrent() }
                .keyboardShortcut("r")
            Button(model.showHidden ? "Gizli Dosyaları Gizle" : "Gizli Dosyaları Göster") { model.toggleHidden() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .undoRedo) {}
        CommandGroup(after: .pasteboard) {
            Button("Tümünü Seç") { model.selectAll() }.keyboardShortcut("a")
        }
    }
}
