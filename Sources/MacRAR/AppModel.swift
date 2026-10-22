import SwiftUI
import AppKit
import MacRARCore

/// Add/Extract sheet'lerinden gelen seçimler.
struct ExtractChoices {
    var destination: URL
    var overwrite: OverwriteMode = .overwrite
    var keepPaths = true
    var keepBroken = false
    var createSubfolder = false
    var useSelection = false
    var reveal = true
    /// true: ilerleme penceresi yalnızca işlem uzun sürerse gösterilir (Finder'dan hızlı çıkarma).
    var quiet = false
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    // MARK: Araçlar
    var tools = ToolPaths()
    var service: ArchiveService { ArchiveService(tools: tools) }

    // MARK: Gezinme
    var folderURL: URL
    var archiveURL: URL?
    var listing: ArchiveListing?
    private(set) var archiveIsZip = false
    var archivePassword: String?
    /// Açık arşivin özeti; her çizimde yeniden saymamak için arşiv yüklenirken bir kez hesaplanır.
    struct ArchiveStats: Equatable { var files = 0, folders = 0; var size: Int64 = 0, packed: Int64 = 0 }
    var archiveStats: ArchiveStats?
    /// Açık arşivde bulunulan sanal klasör ("" = kök).
    var archivePath = ""
    var isLoading = false
    var folderError: String?

    // MARK: Görünüm
    var rows: [Row] = []
    var selection = Set<Row.ID>()
    var sortOrder: [KeyPathComparator<Row>] = [KeyPathComparator(\Row.name, comparator: .localizedStandard)]
    var searchText = ""
    var showHidden: Bool

    // MARK: Parola yöneticisi
    /// Testlerde bellek içi depoyla değiştirilebilir.
    var vault = PasswordVault()
    /// Kullanıcı "kaydet" dedi; parola arşivi gerçekten açtığında (doğrulanınca) kaydedilir.
    @ObservationIgnored private var pendingVaultSave: (password: String, name: String)?

    // MARK: Hızlı oturum (Finder'dan başlatılan, pencere gerektirmeyen işlemler)
    /// Finder komutuyla, kullanıcı MacRAR'ı kullanmıyorken başlatılan oturum: pencere yalnızca gerekirse
    /// açılır ve işlem bitince uygulama kapanır.
    private(set) var quickSession = false
    @ObservationIgnored private var pendingQuickTasks = 0
    @ObservationIgnored private var uiWatcherStarted = false
    /// Hızlı oturum bitince çağrılır (uygulamada: çık). Testlerde varsayılan olarak hiçbir şey yapmaz.
    @ObservationIgnored var onQuickSessionEnd: () -> Void = {}
    /// Kullanıcının görebildiği bir ana pencere var mı (testlerde değiştirilebilir).
    @ObservationIgnored var hasVisibleWindow: () -> Bool = {
        // Finder komutuyla açılıp gizlenen ana pencere (saydam) "görünür" sayılmaz.
        NSApplication.shared.windows.contains { $0.isVisible && $0.canBecomeMain && !$0.isMiniaturized && $0.alphaValue > 0.01 }
    }

    // MARK: Pencereler
    var sheet: ActiveSheet? { didSet { sheetDidChange() } }
    /// Finder'dan gelen Ekle/Çıkar penceresi, ana pencere açılmadan bağımsız (taşınabilir) bir pencerede gösterilir.
    private(set) var sheetInPanel = false

    private func sheetDidChange() {
        switch sheet {
        case .add?, .extract?:
            // Kullanıcı uygulamayı görmüyorsa (Finder komutu): ana pencereyi açmadan bağımsız pencere. Sayfalar taşınamaz.
            if quickSession, !hasVisibleWindow(), alert == nil {
                sheetInPanel = true
                SheetPanel.shared.show(model: self)
            } else {
                sheetInPanel = false
            }
        default:
            sheetInPanel = false
        }
        if sheet == nil { SheetPanel.shared.hide() }
    }
    var operation: OperationState?
    var alert: AlertInfo?
    var previewURL: URL?
    /// Kısa süreli, engellemeyen bildirim (örn. "Parola kaydedildi").
    var notice: String?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    @ObservationIgnored private var rowsByID: [Row.ID: Row] = [:]
    @ObservationIgnored private var folderRows: [Row] = []
    @ObservationIgnored private var childrenIndex: [String: [ArchiveEntry]] = [:]
    @ObservationIgnored private var loadGeneration = 0
    /// Klasör listesi (yeniden) yüklendiğinde seçilecek dosya.
    @ObservationIgnored private var pendingSelectionURL: URL?
    @ObservationIgnored private let defaults = UserDefaults.standard

    private init() {
        let last = UserDefaults.standard.string(forKey: "lastFolder")
        var start = FileManager.default.homeDirectoryForCurrentUser
        if let last, FileManager.default.fileExists(atPath: last) { start = URL(fileURLWithPath: last) }
        folderURL = start
        showHidden = UserDefaults.standard.bool(forKey: "showHidden")
        reloadTools()
        reloadFolder()
    }

    /// rar'ı RARLAB'dan indirip MacRAR'ın klasörüne kurar (Kurulum Yardımcısı ve uyarı çubuğu ortak kullanır).
    /// `rarInstallProgress` nil değilse kurulum sürüyordur.
    var rarInstallProgress: String?
    var rarInstallMessage: String?

    func installRAR() async {
        guard rarInstallProgress == nil else { return }
        rarInstallProgress = String(localized: "Başlatılıyor…"); rarInstallMessage = nil
        defer { rarInstallProgress = nil }
        do {
            let installed = try await RARInstaller.install(progress: { text in
                Task { @MainActor in
                    if AppModel.shared.rarInstallProgress != nil { AppModel.shared.rarInstallProgress = text }
                }
            })
            reloadTools()
            rarInstallMessage = String(localized: "RAR \(installed.version) kuruldu (deneme sürümü, en çok 40 gün ücretsiz).")
        } catch {
            rarInstallMessage = String(localized: "RAR kurulamadı: \(error.localizedDescription)")
        }
    }

    func reloadTools() {
        tools = ToolPaths.detect(rarOverride: defaults.string(forKey: "rarPath"),
                                 unrarOverride: defaults.string(forKey: "unrarPath"),
                                 bsdtarOverride: defaults.string(forKey: "bsdtarPath"))
        publishFinderState()
    }

    /// Finder eklentisi, rar yokken RAR sıkıştırma girdilerini gizlemek için bu durumu okur (bkz. FinderState).
    func publishFinderState() {
        let language = AppLanguage.saved
        FinderState.writeCanCompressRAR(tools.canWriteRAR, language: language == .system ? nil : language.rawValue)
    }

    // MARK: - Türetilmiş durum

    var isInArchive: Bool { archiveURL != nil }
    var isRARArchive: Bool { listing?.engine == .rar }
    /// Açık arşiv ZIP mi (dosya başlığına bakılır; arşiv açılırken bir kez belirlenir).
    var isZipArchive: Bool { archiveIsZip && listing?.engine == .libarchive }
    /// ZIP'e ekleme/silme/yeniden adlandırma: macOS'un yerleşik bsdtar'ı yeter (rar gerekmez).
    var canModifyZip: Bool { isZipArchive && tools.bsdtar != nil }
    /// Ekleme, silme ve yeniden adlandırma: RAR (rar gerekir) ve ZIP.
    var canModifyArchive: Bool { (isRARArchive && tools.canWriteRAR) || canModifyZip }
    /// Yorum, kurtarma kaydı, kilitleme: yalnızca RAR.
    var canEditRARFeatures: Bool { isRARArchive && tools.canWriteRAR }

    var windowTitle: String {
        if let a = archiveURL { return a.lastPathComponent }
        return folderURL.lastPathComponent.isEmpty ? "/" : folderURL.lastPathComponent
    }

    var selectedRows: [Row] {
        selection.compactMap { rowsByID[$0] }
    }

    var selectedFileURLs: [URL] { selectedRows.compactMap(\.url) }
    var selectedArchiveFiles: [URL] { selectedRows.filter(\.isArchiveFile).compactMap(\.url) }
    /// Seçili arşivler, listedeki görünüm sırasıyla (birleştirme/karşılaştırma için tutarlı sıra).
    var selectedArchiveFilesInOrder: [URL] {
        rows.filter { selection.contains($0.id) && $0.isArchiveFile }.compactMap(\.url)
    }

    /// Klasör kipinde seçim yoksa "Ekle" bir dosya seçici açar, bu yüzden her zaman etkindir.
    var canAdd: Bool { isInArchive ? canModifyArchive : true }
    var canExtract: Bool { isInArchive || !selectedArchiveFiles.isEmpty }
    /// Sınama: RAR ve (bsdtar ile) ZIP/7Z/TAR; klasör kipinde birden çok arşiv seçilebilir.
    var canTest: Bool {
        if isInArchive { return true }
        return !selectedArchiveFiles.isEmpty
    }
    var canMerge: Bool { !isInArchive && selectedArchiveFiles.count >= 2 }
    var canCompare: Bool { !isInArchive && selectedArchiveFiles.count == 2 }
    var canView: Bool { selectedRows.contains { !$0.isDirectory } }
    var canDelete: Bool { isInArchive ? (canModifyArchive && !selection.isEmpty) : !selection.isEmpty }
    var canInfo: Bool { isInArchive || selectedArchiveFiles.count == 1 }
    var canRepair: Bool {
        if isInArchive { return isRARArchive && tools.canWriteRAR }
        return tools.canWriteRAR && selectedArchiveFiles.count == 1
    }

    // MARK: - Klasör gezintisi

    func openFolder(_ url: URL) {
        if archiveURL != nil { clearArchiveState() }
        folderURL = url
        defaults.set(url.path, forKey: "lastFolder")
        selection = []
        searchText = ""
        reloadFolder()
    }

    func reloadFolder() {
        loadGeneration += 1
        let gen = loadGeneration
        let url = folderURL
        let hidden = showHidden
        Task {
            let result: Result<[FolderItem], Error> = await Task.detached {
                Result { try FolderLoader.load(url, showHidden: hidden) }
            }.value
            guard gen == loadGeneration else { return }
            switch result {
            case .success(let items):
                folderRows = items.map(Row.init(folderItem:))
                folderError = nil
            case .failure(let e):
                folderRows = []
                folderError = e.localizedDescription
            }
            refreshRows()
            applyPendingSelection()
        }
    }

    /// Açık arşivi veya klasörü yeniden okur.
    func reloadCurrent() {
        if isInArchive { Task { await reloadArchive() } } else { reloadFolder() }
    }

    /// Dosyayı (sembolik bağlantılar çözülerek) klasör listesinde seçer; liste henüz yüklenmediyse
    /// yükleme bitince seçer.
    func selectFile(_ url: URL) {
        pendingSelectionURL = url
        applyPendingSelection()
    }

    private func applyPendingSelection() {
        guard let url = pendingSelectionURL, !isInArchive else { return }
        let target = url.resolvingSymlinksInPath().path
        if let row = folderRows.first(where: { $0.url?.resolvingSymlinksInPath().path == target }) {
            selection = [row.id]
            pendingSelectionURL = nil
        }
    }

    func toggleHidden() {
        showHidden.toggle()
        defaults.set(showHidden, forKey: "showHidden")
        reloadFolder()
    }

    func goUp() {
        if isInArchive {
            if archivePath.isEmpty {
                closeArchive()
            } else {
                enterArchivePath(Self.parent(of: archivePath))
            }
            return
        }
        let parent = folderURL.deletingLastPathComponent()
        if parent.path != folderURL.path { openFolder(parent) }
    }

    func enterArchivePath(_ path: String) {
        archivePath = path
        selection = []
        searchText = ""
        refreshRows()
    }

    private static func parent(of path: String) -> String {
        if let i = path.lastIndex(of: "/") { return String(path[..<i]) }
        return ""
    }

    // MARK: - Arşiv açma / kapama

    func openArchive(_ url: URL) {
        Task { await loadArchive(url) }
    }

    /// Arşivi okuyup oturumu başlatır (gerekirse parola sorar).
    func loadArchive(_ url: URL) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let (l, pw) = try await listWithPassword(url)
            archiveURL = url
            listing = l
            archiveIsZip = ArchiveService.isZIP(url)
            archivePassword = pw
            archivePath = ""
            folderURL = url.deletingLastPathComponent()
            defaults.set(folderURL.path, forKey: "lastFolder")
            buildIndex()
            selection = []
            searchText = ""
            refreshRows()
            reloadFolder()
        } catch ArchiveError.cancelled {
        } catch {
            alert = AlertInfo(title: String(localized: "“\(url.lastPathComponent)” açılamadı"), message: error.localizedDescription)
        }
    }

    func closeArchive() {
        let was = archiveURL
        clearArchiveState()
        selection = []
        refreshRows()
        if let was { selectFile(was) }
    }

    private func clearArchiveState() {
        archiveURL = nil
        listing = nil
        archiveIsZip = false
        archiveStats = nil
        archivePassword = nil
        archivePath = ""
        childrenIndex = [:]
        searchText = ""
    }

    /// Arşivi diskten yeniden okur (düzenleme işlemlerinden sonra), bulunulan klasörü korur.
    func reloadArchive() async {
        guard let url = archiveURL else { return }
        do {
            let l = try await service.list(archive: url, password: archivePassword)
            listing = l
            buildIndex()
            if !archivePath.isEmpty, childrenIndex[archivePath] == nil { archivePath = "" }
            refreshRows()
        } catch {
            alert = AlertInfo(title: String(localized: "Arşiv yenilenemedi"), message: error.localizedDescription)
        }
    }

    private func buildIndex() {
        guard let entries = listing?.entries else { childrenIndex = [:]; archiveStats = nil; return }
        var stats = ArchiveStats()
        for e in entries {
            if e.isDirectory { stats.folders += 1 } else { stats.files += 1; stats.size += e.size }
            stats.packed += e.packedSize ?? 0
        }
        archiveStats = stats
        var children: [String: [ArchiveEntry]] = [:]
        var known = Set<String>()
        known.reserveCapacity(entries.count)
        for e in entries { known.insert(e.path) }
        for e in entries {
            children[e.parentPath, default: []].append(e)
            // Arşivde açıkça kayıtlı olmayan üst klasörleri sentezle
            var p = e.parentPath
            while !p.isEmpty, !known.contains(p) {
                known.insert(p)
                let synthesized = ArchiveEntry(path: p, isDirectory: true, size: 0)
                children[Self.parent(of: p), default: []].append(synthesized)
                p = Self.parent(of: p)
            }
        }
        childrenIndex = children
    }

    // MARK: - Satır listesi

    func refreshRows() {
        var base: [Row]
        if isInArchive, let listing {
            if searchText.isEmpty {
                base = (childrenIndex[archivePath] ?? []).map(Row.init(entry:))
            } else {
                base = listing.entries.filter { Self.matches($0.name, searchText) }.map(Row.init(entry:))
            }
        } else {
            base = searchText.isEmpty ? folderRows : folderRows.filter { Self.matches($0.name, searchText) }
        }
        // Yinelenen kimlikleri ele (aynı adlı birden çok girdi içeren arşivler)
        var seen = Set<Row.ID>()
        base = base.filter { seen.insert($0.id).inserted }

        let sorted = base.sorted(using: sortOrder)
        let dirs = sorted.filter(\.isDirectory)
        let files = sorted.filter { !$0.isDirectory }
        rows = dirs + files
        rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        selection = selection.filter { rowsByID[$0] != nil }
    }

    /// Büyük/küçük harf ve aksan duyarsız arama. Türkçe "İ"/"i" ve "é"/"e" gibi farklar eşleşir.
    /// (Yerel ayara bağlı `localizedStandardContains` Türkçe "İ" ile "i"yi eşleştirmiyordu.)
    static func matches(_ name: String, _ query: String) -> Bool {
        name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    // MARK: - Satır açma

    func openRows(_ ids: Set<Row.ID>) {
        guard let row = ids.compactMap({ rowsByID[$0] }).first else { return }
        open(row)
    }

    func open(_ row: Row) {
        if isInArchive {
            if row.isDirectory { enterArchivePath(row.archivePath) } else { openEntry(row, quickLook: false) }
        } else if let url = row.url {
            if row.isDirectory, url.pathExtension.lowercased() != "app" {
                openFolder(url)
            } else if row.isArchiveFile {
                openArchive(url)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Finder'dan "birlikte aç", Dock'a bırakma veya komut satırı argümanı.
    func handleOpen(_ urls: [URL]) {
        guard let first = urls.first else { return }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir)
        if isDir.boolValue {
            openFolder(first)
        } else if urls.count == 1, ArchiveTypes.isArchive(first) || ArchiveService.engine(for: first) == .rar {
            openArchive(first)
        } else {
            openAddSheet(sources: urls)
        }
    }

    /// Pencereye sürükle-bırak.
    func handleDrop(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if isInArchive {
            if canModifyArchive { openAddSheet(sources: urls) }
            else { alert = AlertInfo(title: String(localized: "Arşive eklenemiyor"), message: String(localized: "Bu arşiv biçimine (yalnızca RAR ve ZIP) dosya eklenemez ya da RAR için ‘rar’ aracı bulunamadı.")) }
        } else {
            handleOpen(urls)
        }
    }

    // MARK: - Parola akışı

    /// Parola isteme penceresini gösterir; iptalde nil döner. Kullanıcı "kaydet" seçtiyse parola,
    /// doğrulanınca (`passwordVerified`) parola yöneticisine eklenir; yanlış parola kaydedilmez.
    func askPassword(archive: URL, wrong: Bool) async -> String? {
        var request: PasswordRequest?
        let pw: String? = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let req = PasswordRequest(archiveName: archive.lastPathComponent, wrong: wrong) { cont.resume(returning: $0) }
            request = req
            sheet = .password(req)
        }
        if let pw, let name = request?.saveName, !name.isEmpty { pendingVaultSave = (pw, name) } else { pendingVaultSave = nil }
        return pw
    }

    /// Finder'dan gelen bir komut başlarken çağrılır. Kullanıcı uygulamayı o an kullanmıyorsa
    /// (görünür pencere yok) bir "hızlı oturum" başlatır.
    func beginQuickCommand() {
        if pendingQuickTasks == 0, !quickSession, !hasVisibleWindow() { quickSession = true }
    }

    /// Hızlı oturumdaki bir arka plan işini sayar; bitince oturum sonlanabilir mi diye bakılır.
    func trackQuickTask<T>(_ work: () async -> T) async -> T {
        pendingQuickTasks += 1
        let result = await work()
        pendingQuickTasks -= 1
        scheduleQuickSessionEnd()
        return result
    }

    /// Kullanıcı bu oturumu devraldı (örn. arşivi MacRAR'da açtı): artık kendiliğinden kapanma.
    func endQuickSessionTakeover() { quickSession = false }

    /// Hiçbir iş, pencere, uyarı veya açık arşiv kalmadıysa kısa bir gecikmeyle oturumu bitirir.
    /// (Gecikme, Ekle penceresi kapanıp işlemin başladığı kısa aralıkta yanlışlıkla kapanmayı önler.)
    func scheduleQuickSessionEnd() {
        guard quickSession else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard quickSession, pendingQuickTasks == 0, sheet == nil, operation == nil, alert == nil, !isInArchive
            else { return }
            quickSession = false
            onQuickSessionEnd()
        }
    }

    /// Pencere gerektiren bir durum (diyalog, ilerleme, uyarı) oluşunca pencereyi açar; bu durumlar
    /// bitince hızlı oturumu sonlandırmayı dener. Yalnızca uygulamada başlatılır.
    func startUIWatcher() {
        guard !uiWatcherStarted else { return }
        uiWatcherStarted = true
        watchUI()
    }

    private func watchUI() {
        let needsWindow = withObservationTracking {
            sheet != nil || operation != nil || alert != nil
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // onChange değişiklikten ÖNCE tetiklenir; değeri bir sonraki turda oku
                try? await Task.sleep(for: .milliseconds(50))
                if (self.sheet != nil && !self.sheetInPanel) || self.alert != nil {
                    // Parola/diyalog/uyarı ana pencerede çıkar: pencereyi göster, ilerleme panelini kapat.
                    ProgressPanel.shared.hide()
                    if !self.hasVisibleWindow() { self.bringToFront() }
                } else if self.sheetInPanel {
                    // Ekle/Çıkar penceresi bağımsız pencerede açık; ana pencereye dokunma.
                    ProgressPanel.shared.hide()
                } else if self.operation != nil {
                    // Yalnızca ilerleme: pencere yoksa (Finder komutu) küçük ilerleme paneli; varsa ana pencerenin kaplaması yeter.
                    if self.hasVisibleWindow() { ProgressPanel.shared.hide() } else { ProgressPanel.shared.show(model: self) }
                } else {
                    ProgressPanel.shared.hide()
                    self.scheduleQuickSessionEnd()
                }
                self.watchUI()
            }
        }
        _ = needsWindow
    }

    /// Finder hizmetinden gelen işlemlerde uygulamayı ve penceresini gerçekten öne getirir.
    /// `activate(ignoringOtherApps:)` macOS 14'ten beri başka bir uygulama (Finder) etkinken çoğu zaman
    /// işe yaramıyor ve pencere hiç oluşmuyor; parola penceresi görünmeden işlem sonsuza dek bekliyordu.
    /// `open -a` ile aynı yolu (LaunchServices'in "yeniden aç" olayı) kullanmak pencereyi garanti eder.
    /// Yalnızca gerçek bir `.app` paketi "yeniden açılabilir". Testlerde (xctest) ya da `swift run` ile Bundle.main
    /// bir klasörü gösterir; `openApplication` onu Finder'da açıp ekrana boş pencere getirirdi.
    nonisolated static func isReopenable(bundleURL: URL) -> Bool { bundleURL.pathExtension == "app" }

    // MARK: Finder komutuyla açılışta ana pencereyi gizleme

    /// Uygulama bir Finder (macrar://) komutuyla başlatıldı: ana pencere, kullanıcı istemedikçe (diyalog, parola, uyarı,
    /// "MacRAR'da aç") gösterilmez; yalnızca küçük bir ilerleme paneli görünür.
    var launchedByFinderCommand = false

    /// Süreç başlangıcı. Açılış nedeni (Dock/çift tıklama ya da Finder komutu) başlangıçta bilinemez: Finder komutu birkaç
    /// yüz ms içinde gelir. Bu yüzden ana pencere ilk `startupGrace` süresince gizli tutulur; komut gelirse gizli kalır,
    /// gelmezse pencere gösterilir.
    @ObservationIgnored let processStartedAt = Date()
    nonisolated static let startupGrace: TimeInterval = 1.0
    var inStartupGrace: Bool { Date().timeIntervalSince(processStartedAt) < Self.startupGrace }

    /// Finder komutu geldi: açılış bekleme süresi içindeyse bu bir "Finder'dan açılış"tır; ana pencere gizli kalır.
    func noteFinderCommandArrived() {
        if inStartupGrace { launchedByFinderCommand = true }
    }

    /// Ana pencereyi (görünmeden) gizler: saydam yapar ve fare olaylarını almaz.
    func hideMainWindow(_ window: NSWindow) {
        window.alphaValue = 0
        window.ignoresMouseEvents = true
    }

    func revealMainWindows() {
        launchedByFinderCommand = false
        for w in NSApplication.shared.windows where w.canBecomeMain {
            w.alphaValue = 1
            w.ignoresMouseEvents = false
        }
    }

    func bringToFront() {
        revealMainWindows()
        if Self.isReopenable(bundleURL: Bundle.main.bundleURL) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config)
        }
        NSApplication.shared.activate()
        for w in NSApplication.shared.windows where w.canBecomeMain {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        }
    }

    func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { notice = nil }
        }
    }

    /// Parolayı yöneticiye ekler ve sonucu kullanıcıya bildirir (başarısızlıkta uyarı gösterir).
    @discardableResult
    func saveToVault(name: String, password: String) async -> Bool {
        let existed = vault.items.contains { $0.password == password }
        let ok = await vault.add(name: name, password: password)
        if ok {
            showNotice(existed ? String(localized: "Bu parola zaten kayıtlıydı; son kullanımı güncellendi") : String(localized: "Parola “\(name)” adıyla kaydedildi"))
        } else {
            alert = AlertInfo(title: String(localized: "Parola kaydedilemedi"),
                              message: vault.errorMessage ?? String(localized: "Parola yöneticisine yazılamadı (Anahtar Zinciri erişimi reddedilmiş olabilir)."))
        }
        return ok
    }

    /// Parola arşivi gerçekten açtı: bekleyen kaydı yapar veya kayıtlı parolanın son kullanımını günceller.
    func passwordVerified(_ password: String?) {
        guard let password else { return }
        if let p = pendingVaultSave, p.password == password {
            pendingVaultSave = nil
            Task { await saveToVault(name: p.name, password: password) }
        } else {
            Task { await vault.touch(password: password) }
        }
    }

    func listWithPassword(_ url: URL, initial: String? = nil) async throws -> (ArchiveListing, String?) {
        var pw = initial
        while true {
            do {
                let l = try await service.list(archive: url, password: pw)
                passwordVerified(pw)
                return (l, pw)
            } catch ArchiveError.passwordRequired {
                guard let p = await askPassword(archive: url, wrong: false) else { throw ArchiveError.cancelled }
                pw = p
            } catch ArchiveError.wrongPassword {
                guard let p = await askPassword(archive: url, wrong: true) else { throw ArchiveError.cancelled }
                pw = p
            }
        }
    }

    // MARK: - İşlem yürütme

    private func isPasswordError(_ e: Error) -> Bool {
        if case ArchiveError.passwordRequired = e { return true }
        if case ArchiveError.wrongPassword = e { return true }
        return false
    }

    private func isCancelled(_ e: Error) -> Bool {
        if case ArchiveError.cancelled = e { return true }
        return e is CancellationError
    }

    /// İlerleme penceresiyle bir işi çalıştırır. Parola hataları ve iptal sessiz kapanır;
    /// diğer hatalar pencerede gösterilir.
    @discardableResult
    func perform<T: Sendable>(_ title: String,
                              tracker: ProgressTracker,
                              delayed: Bool = false,
                              warnings: @escaping (T) -> [String] = { _ in [] },
                              work: @escaping @Sendable () async throws -> T) async -> Result<T, Error> {
        let op = OperationState(title: title)
        if delayed {
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                if op.isRunning, operation == nil { operation = op }
            }
        } else {
            operation = op
        }

        let task = Task { try await work() }
        op.cancelAction = { task.cancel() }
        let poller = Task {
            while !Task.isCancelled {
                op.apply(tracker.drain())
                try? await Task.sleep(for: .milliseconds(80))
            }
        }

        let outcome: Result<T, Error>
        do { outcome = .success(try await task.value) } catch { outcome = .failure(error) }
        poller.cancel()
        op.apply(tracker.drain())
        op.finishedAt = Date()

        switch outcome {
        case .success(let value):
            let w = warnings(value)
            op.phase = .finished
            if w.isEmpty {
                if operation?.id == op.id { operation = nil }
            } else {
                op.warnings = w
                operation = op
            }
        case .failure(let e):
            if isPasswordError(e) || isCancelled(e) {
                op.phase = .finished
                if operation?.id == op.id { operation = nil }
            } else {
                op.phase = .failed(e.localizedDescription)
                operation = op
            }
        }
        return outcome
    }

    /// Parola gerektiğinde sorup işi yeniden deneyen sarmalayıcı. Başarısızlıkta nil döner.
    func performWithPassword<T: Sendable>(archive: URL,
                                          title: String,
                                          initialPassword: String?,
                                          delayed: Bool = false,
                                          makeTracker: () async -> ProgressTracker,
                                          warnings: @escaping (T) -> [String] = { _ in [] },
                                          work: @escaping @Sendable (String?, ProgressTracker) async throws -> T) async -> T? {
        var pw = initialPassword
        while true {
            let tracker = await makeTracker()
            let currentPW = pw
            let result = await perform(title, tracker: tracker, delayed: delayed, warnings: warnings) {
                try await work(currentPW, tracker)
            }
            switch result {
            case .success(let v):
                if archive == archiveURL, let pw { archivePassword = pw }
                passwordVerified(pw)
                return v
            case .failure(let e):
                if let ae = e as? ArchiveError, isPasswordError(ae) {
                    guard let entered = await askPassword(archive: archive, wrong: pw != nil) else { return nil }
                    pw = entered
                    continue
                }
                return nil
            }
        }
    }

    func dismissOperation() {
        guard let op = operation else { return }
        if op.isRunning { op.cancel() } else { operation = nil }
    }

    // MARK: - Ekleme

    func showAdd() {
        if isInArchive {
            guard canModifyArchive, let archive = archiveURL else { return }
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            panel.prompt = String(localized: "Ekle")
            panel.message = String(localized: "Arşive eklenecek dosya ve klasörleri seçin")
            guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
            sheet = .add(AddRequest(sources: panel.urls, defaultName: archive.deletingPathExtension().lastPathComponent,
                                    defaultFolder: archive.deletingLastPathComponent(), existingArchive: archive,
                                    pathInArchive: archivePath))
        } else if selectedFileURLs.isEmpty {
            // Seçim yok: sıkıştırılacak dosyaları seçici ile sor
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            panel.directoryURL = folderURL
            panel.prompt = String(localized: "Seç")
            panel.message = String(localized: "Arşive eklenecek dosya ve klasörleri seçin")
            guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
            openAddSheet(sources: panel.urls)
        } else {
            openAddSheet(sources: selectedFileURLs)
        }
    }

    /// Finder hizmeti: her zaman YENİ arşiv için Ekle penceresini açar (açık arşive eklemez).
    func showAddFromFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        beginQuickCommand()
        openAddSheet(sources: urls, forceNewArchive: true)
    }

    func openAddSheet(sources: [URL], forceNewArchive: Bool = false) {
        guard !sources.isEmpty else {
            alert = AlertInfo(title: String(localized: "Dosya seçilmedi"), message: String(localized: "Arşive eklemek için önce dosya veya klasör seçin."))
            return
        }
        if !forceNewArchive, isInArchive, canModifyArchive, let archive = archiveURL {
            sheet = .add(AddRequest(sources: sources, defaultName: archive.deletingPathExtension().lastPathComponent,
                                    defaultFolder: archive.deletingLastPathComponent(), existingArchive: archive,
                                    pathInArchive: archivePath))
            return
        }
        let name: String
        if sources.count == 1 {
            let s = sources[0]
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: s.path, isDirectory: &isDir)
            name = isDir.boolValue ? s.lastPathComponent : s.deletingPathExtension().lastPathComponent
        } else {
            name = sources[0].deletingLastPathComponent().lastPathComponent
        }
        let folder = sources[0].deletingLastPathComponent()
        sheet = .add(AddRequest(sources: sources, defaultName: name.isEmpty ? String(localized: "Arşiv") : name, defaultFolder: folder))
    }

    @discardableResult
    func runAdd(_ options: CompressOptions, quiet: Bool = false) async -> Bool {
        var options = options
        let existed = FileManager.default.fileExists(atPath: options.archive.path)
        let svc = service
        var askedPassword: String?
        var result: Result<OperationReport, Error>
        while true {
            let tracker = await ProgressTracker.forAdding(options)
            let attempt = options
            result = await perform(String(localized: "Ekleniyor: \(options.archive.lastPathComponent)"), tracker: tracker, delayed: quiet,
                                   warnings: { (r: OperationReport) in r.warnings }) {
                try await svc.add(attempt, tracker: tracker)
            }
            // Parolalı ZIP'e ekleme: parola yoksa/yanlışsa sorulur ve işlem yeniden denenir (RAR zaten kendi parolasını kullanır).
            if case .failure(let e) = result, options.appendToExisting, isPasswordError(e) {
                var wrong = false
                if case ArchiveError.wrongPassword = e { wrong = true }
                guard let pw = await askPassword(archive: options.archive, wrong: wrong) else { return false }
                options.password = pw
                askedPassword = pw
                continue
            }
            break
        }
        if case .success = result, let pw = askedPassword {
            passwordVerified(pw)
            if options.archive == archiveURL { archivePassword = pw }   // aynı oturumda tekrar sorulmasın
        }
        // /var ↔ /private/var farkı önek eşleşmesini bozmasın: yollar gerçek yollarıyla karşılaştırılır.
        if let root = mergeStaging,
           options.sources.contains(where: { TransferMonitor.realPath($0.path).hasPrefix(TransferMonitor.realPath(root.path) + "/") }) {
            // Birleştirme için açılan geçici içerik ekleme bitince (başarılı ya da değil) silinir.
            removeMergeStaging()
        }
        switch result {
        case .success:
            if isInArchive, options.archive == archiveURL {
                await reloadArchive()
            } else {
                if !isInArchive {
                    reloadFolder()
                    if options.archive.deletingLastPathComponent().resolvingSymlinksInPath().path
                        == folderURL.resolvingSymlinksInPath().path {
                        selectFile(options.archive)
                    }
                }
            }
            if !isInArchive, options.deleteAfter { reloadFolder() }
            return true
        case .failure(let e):
            if isCancelled(e), !existed { try? FileManager.default.removeItem(at: options.archive) }
            return false
        }
    }

    // MARK: - Finder ana sağ tık menüsü (Finder Sync eklentisi)

    /// Uygulama ile Finder eklentisi arasındaki gizli anahtar: her kurulumda ilk açılışta rastgele üretilir,
    /// `~/Library/Application Support/MacRAR/finder.token` dosyasında (0600) durur. Hiçbir sürümde ortak anahtar yoktur.
    nonisolated static var finderToken: String? { FinderToken.read() }

    /// `macrar://<eylem>?t=<anahtar>&p=<yol>…` komutunu işler. Anahtar yanlışsa sessizce yok sayılır.
    func handleFinderURL(_ url: URL, token: String? = AppModel.finderToken) {
        noteFinderCommandArrived()
        beginQuickCommand()
        // Reddedilen/boş komut uygulamayı başlatmış olabilir; görünmez ve boşta kalmasın diye oturumu bitir.
        guard let cmd = FinderIntegration.parse(url, expectedToken: token) else { scheduleQuickSessionEnd(); return }
        let files = cmd.files.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { scheduleQuickSessionEnd(); return }
        switch cmd.action {
        case .add:
            openAddSheet(sources: files, forceNewArchive: true)
        case .compress:
            quickCompress(files, timestamped: false)
        case .compressStamped:
            quickCompress(files, timestamped: true)
        case .compressZip:
            quickCompress(files, timestamped: false, format: .zip)
        case .compressZipStamped:
            quickCompress(files, timestamped: true, format: .zip)
        case .open:
            // Kullanıcı arşivi MacRAR'da görmek istiyor: pencere açık kalsın, kendiliğinden kapanma.
            endQuickSessionTakeover()
            bringToFront()
            openArchive(files[0])
        case .extractDialog:
            let archives = files.filter { ArchiveTypes.isArchive($0) || ArchiveService.engine(for: $0) == .rar }
            guard let first = archives.first else { return }
            sheet = .extract(ExtractRequest(archives: archives, selectedRows: [],
                                            defaultDestination: first.deletingLastPathComponent()))
        case .extractHere:
            quickExtract(files, intoSubfolder: false)
        case .extractFolder:
            quickExtract(files, intoSubfolder: true)
        }
    }

    // MARK: - Hızlı çıkarma (Finder hizmeti, sağ tık menüsü)

    /// Diyalog açmadan, her arşivi kendi bulunduğu klasöre çıkarır.
    /// - Parameter intoSubfolder: true ise `arşivadı/` alt klasörüne, false ise doğrudan klasörün içine.
    /// Var olan dosyaların üzerine yazılmaz: RAR'da otomatik yeniden adlandırılır, diğer biçimlerde atlanır.
    func quickExtract(_ urls: [URL], intoSubfolder: Bool) {
        let archives = urls.filter { ArchiveTypes.isArchive($0) || ArchiveService.engine(for: $0) == .rar }
        beginQuickCommand()
        guard !archives.isEmpty else {
            alert = AlertInfo(title: String(localized: "Arşiv seçilmedi"), message: String(localized: "Seçilen öğeler arşiv dosyası değil."))
            return
        }
        let reveal = defaults.object(forKey: "quickReveal") as? Bool ?? true
        Task { await trackQuickTask {
            for archive in archives {
                let dir = archive.deletingLastPathComponent()
                var c = ExtractChoices(destination: dir)
                c.createSubfolder = intoSubfolder
                c.overwrite = ArchiveService.engine(for: archive) == .rar ? .rename : .skip
                c.reveal = intoSubfolder && reveal && archives.count == 1
                c.quiet = true
                await runExtract(ExtractRequest(archives: [archive], selectedRows: [], defaultDestination: dir), choices: c)
                if operation != nil || alert != nil { break } // hata/uyarı gösteriliyorsa devam etme
            }
        } }
    }

    // MARK: - Hızlı sıkıştırma (Finder hizmeti, sağ tık menüsü)

    /// Zaman damgası ayarları (Ayarlar penceresinden).
    var stampSettings: (pattern: String, separator: String) {
        let d = UserDefaults.standard
        let pattern = d.string(forKey: "stampPattern") ?? ArchiveNaming.defaultPattern
        let sep = d.string(forKey: "stampSeparator") ?? ArchiveNaming.defaultSeparator
        return (ArchiveNaming.isValid(pattern: pattern) ? pattern : ArchiveNaming.defaultPattern, sep)
    }

    /// Diyalog açmadan: kaynağın yanına `ad.<uzantı>` veya `ad-<zaman damgası>.<uzantı>` oluşturur.
    /// `.zip` macOS'un yerleşik bsdtar'ını kullanır (rar gerekmez); RAR biçimi için `rar` gerekir.
    func quickCompress(_ urls: [URL], timestamped: Bool, format: ArchiveFormat = .rar5) {
        guard !urls.isEmpty else { return }
        beginQuickCommand()
        if format.isRAR {
            guard tools.canWriteRAR else {
                // rar yoksa ZIP'e geçmeyi öner: kullanıcı işini yine de görebilsin.
                var info = AlertInfo(title: String(localized: "RAR oluşturulamıyor"),
                                     message: String(localized: "RAR oluşturmak için RARLAB’ın ‘rar’ aracı gerekir (Yardım ▸ Kurulum Yardımcısı’ndan kurabilirsiniz). \(ToolGuidance.rarLicenseNote)"))
                if tools.bsdtar != nil {
                    info.message += " " + String(localized: "Bunun yerine ZIP olarak sıkıştırabilirsiniz.")
                    info.confirm = .init(label: String(localized: "ZIP olarak sıkıştır"), destructive: false) { [weak self] in
                        self?.quickCompress(urls, timestamped: timestamped, format: .zip)
                    }
                }
                alert = info
                return
            }
        } else if tools.bsdtar == nil {
            alert = AlertInfo(title: String(localized: "\(format.fileExtension.uppercased()) oluşturulamıyor"),
                              message: String(localized: "macOS’un ‘bsdtar’ aracı bulunamadı. Ayarlar ▸ Araçlar’dan yolunu belirtin."))
            return
        }
        let ext = format.fileExtension
        let base = ArchiveNaming.baseName(for: urls)
        let name = ArchiveNaming.fileName(base: base, stamp: timestamped ? stampSettings : nil, ext: ext)
        let dir = urls[0].deletingLastPathComponent()
        let target = ArchiveNaming.uniqueURL(in: dir, fileName: name, ext: ext)

        var o = CompressOptions(archive: target, sources: urls)
        o.format = format
        o.method = CompressionMethod(rawValue: defaults.object(forKey: "addMethod") as? Int ?? CompressionMethod.normal.rawValue) ?? .normal
        Task {
            await trackQuickTask {
                let ok = await runAdd(o, quiet: true)
                if ok, defaults.object(forKey: "quickReveal") as? Bool ?? true {
                    NSWorkspace.shared.activateFileViewerSelecting([target])
                }
            }
        }
    }

    // MARK: - Çıkarma

    func showExtract() {
        if let archive = archiveURL {
            sheet = .extract(ExtractRequest(archives: [archive], selectedRows: selectedRows,
                                            defaultDestination: archive.deletingLastPathComponent()))
        } else {
            let archives = selectedArchiveFiles
            guard let first = archives.first else { return }
            sheet = .extract(ExtractRequest(archives: archives, selectedRows: [],
                                            defaultDestination: first.deletingLastPathComponent()))
        }
    }

    /// Sihirbazsız hızlı çıkarma: arşivin yanına, arşiv adlı alt klasöre.
    func extractHereQuick() async {
        let archives = isInArchive ? [archiveURL!] : selectedArchiveFiles
        guard let first = archives.first else { return }
        let req = ExtractRequest(archives: archives, selectedRows: isInArchive ? selectedRows : [],
                                 defaultDestination: first.deletingLastPathComponent())
        var c = ExtractChoices(destination: first.deletingLastPathComponent())
        c.createSubfolder = true
        c.useSelection = isInArchive && !selection.isEmpty
        await runExtract(req, choices: c)
    }

    static func baseName(of archive: URL) -> String {
        var n = archive.deletingPathExtension().lastPathComponent
        if n.lowercased().hasSuffix(".tar") { n = String(n.dropLast(4)) }
        if let r = n.range(of: #"\.part0*1$"#, options: [.regularExpression, .caseInsensitive]) { n.removeSubrange(r) }
        return n.isEmpty ? String(localized: "Çıkarılan") : n
    }

    func runExtract(_ req: ExtractRequest, choices: ExtractChoices) async {
        let svc = service
        var lastDestination: URL?

        for archive in req.archives {
            let listing: ArchiveListing
            var password: String?
            if archive == archiveURL, let l = self.listing {
                listing = l
                password = archivePassword
            } else {
                do { (listing, password) = try await listWithPassword(archive) }
                catch ArchiveError.cancelled { return }
                catch {
                    alert = AlertInfo(title: String(localized: "“\(archive.lastPathComponent)” açılamadı"), message: error.localizedDescription)
                    return
                }
            }

            let dest = choices.createSubfolder
                ? choices.destination.appendingPathComponent(Self.baseName(of: archive), isDirectory: true)
                : choices.destination

            var selection: [ArchiveEntry]?
            if choices.useSelection, archive == archiveURL, !req.selectedRows.isEmpty {
                let chosen = req.selectedRows.map {
                    $0.entry ?? ArchiveEntry(path: $0.archivePath, isDirectory: $0.isDirectory, size: $0.sizeValue)
                }
                selection = ArchiveSelection.expand(chosen, in: listing.entries)
            }
            let trackedEntries = selection ?? listing.entries
            let opts = ExtractOptions(destination: dest, overwrite: choices.overwrite,
                                      keepPaths: choices.keepPaths, keepBroken: choices.keepBroken)
            let engine = listing.engine
            let sel = selection

            let report = await performWithPassword(
                archive: archive,
                title: String(localized: "Çıkarılıyor: \(archive.lastPathComponent)"),
                initialPassword: password,
                delayed: choices.quiet,
                makeTracker: {
                    ProgressTracker.forExtraction(entries: trackedEntries, destination: dest,
                                                  flatten: !opts.keepPaths, engine: engine,
                                                  style: svc.progressStyle(for: engine))
                },
                warnings: { (r: OperationReport) in r.warnings },
                work: { pw, tracker in
                    try await svc.extract(archive: archive, selection: sel, options: opts, password: pw, tracker: tracker)
                })
            guard report != nil else { return }

            // İndirilmiş arşivden çıkan dosyalar Gatekeeper karantinasını devralır.
            let extractedPaths = trackedEntries.map { dest.appendingPathComponent(opts.keepPaths ? $0.path : $0.name) }
            Task.detached { Quarantine.propagate(from: archive, to: extractedPaths) }
            lastDestination = dest
        }

        if choices.reveal, let d = lastDestination {
            NSWorkspace.shared.activateFileViewerSelecting([d])
        }
        if !isInArchive { reloadFolder() }
    }

    // MARK: - Sınama

    func runTest() async {
        if !isInArchive, selectedArchiveFilesInOrder.count > 1 {
            await runBatchTest(selectedArchiveFilesInOrder)
            return
        }
        let archive: URL
        if let a = archiveURL { archive = a } else if let a = selectedArchiveFiles.first { archive = a } else { return }
        var entries = listing?.entries ?? []
        var pw = archivePassword
        var engine = listing?.engine ?? .rar
        if archive != archiveURL {
            do { let (l, p) = try await listWithPassword(archive); entries = l.entries; pw = p; engine = l.engine }
            catch ArchiveError.cancelled { return }
            catch { alert = AlertInfo(title: String(localized: "Sınanamadı"), message: error.localizedDescription); return }
        }
        let ok = await testOne(archive, entries: entries, engine: engine, password: pw)
        if ok != nil {
            alert = AlertInfo(title: String(localized: "Sınama tamamlandı"), message: String(localized: "“\(archive.lastPathComponent)” arşivinde hata bulunmadı."))
        }
    }

    private func testOne(_ archive: URL, entries: [ArchiveEntry], engine: ArchiveEngine, password: String?,
                         titlePrefix: String = String(localized: "Sınanıyor")) async -> OperationReport? {
        let svc = service
        // Yüzde/ağırlık yalnızca rar çıktısından gelir; bsdtar sınaması ilerlemeyi belirsiz gösterir.
        let weights = Dictionary(entries.filter { !$0.isDirectory }.map { ($0.path, $0.size) }, uniquingKeysWith: { a, _ in a })
        let style = svc.progressStyle(for: engine)
        return await performWithPassword(
            archive: archive, title: "\(titlePrefix): \(archive.lastPathComponent)", initialPassword: password,
            makeTracker: { engine == .rar ? ProgressTracker(weights: weights, style: style) : ProgressTracker() },
            warnings: { (r: OperationReport) in r.warnings },
            work: { pw, tracker in try await svc.test(archive: archive, password: pw, tracker: tracker) })
    }

    /// Birden çok arşivi sırayla sınar; bir arşivdeki hata diğerlerini durdurmaz. Sonuç tek özet penceresinde gösterilir.
    private func runBatchTest(_ archives: [URL]) async {
        var lines: [String] = []
        var problems = 0
        for (i, archive) in archives.enumerated() {
            let prefix = String(localized: "Sınanıyor (\(i + 1)/\(archives.count))")
            let listed: ArchiveListing, pw: String?
            do { (listed, pw) = try await listWithPassword(archive) }
            catch ArchiveError.cancelled { lines.append(String(localized: "– \(archive.lastPathComponent): atlandı (parola girilmedi)")); continue }
            catch { lines.append("✗ \(archive.lastPathComponent): \(firstLine(error.localizedDescription))"); problems += 1; continue }
            if await testOne(archive, entries: listed.entries, engine: listed.engine, password: pw, titlePrefix: prefix) != nil {
                lines.append("✓ \(archive.lastPathComponent)")
            } else if case .failed(let message)? = operation?.phase {
                operation = nil   // sonraki arşive geçerken hata katmanı takılı kalmasın; özet pencerede gösterilir
                lines.append("✗ \(archive.lastPathComponent): \(firstLine(message))")
                problems += 1
            } else {
                lines.append(String(localized: "– \(archive.lastPathComponent): atlandı"))
            }
        }
        alert = AlertInfo(title: problems == 0 ? String(localized: "Sınama tamamlandı") : String(localized: "Sınama: \(problems) arşivde sorun var"),
                          message: lines.joined(separator: "\n"))
    }

    private func firstLine(_ s: String) -> String {
        s.split(separator: "\n").first.map(String.init) ?? s
    }

    // MARK: - Arşivleri birleştirme

    /// Birleştirme için açılmış geçici klasör; Ekle tamamlanınca (ya da yenisi başlayınca) silinir, uygulama kapanırken de temizlenir.
    @ObservationIgnored private var mergeStaging: URL?

    func beginMerge() {
        let archives = selectedArchiveFilesInOrder
        guard canMerge, archives.count >= 2 else { return }
        Task { await prepareMerge(archives) }
    }

    private func prepareMerge(_ archives: [URL]) async {
        var items: [(url: URL, listing: ArchiveListing, password: String?)] = []
        for a in archives {
            do { let (l, p) = try await listWithPassword(a); items.append((a, l, p)) }
            catch ArchiveError.cancelled { return }
            catch { alert = AlertInfo(title: String(localized: "“\(a.lastPathComponent)” açılamadı"), message: error.localizedDescription); return }
        }
        let conflicts = ArchiveMerge.conflicts(in: items.map { $0.listing.entries })
        guard !conflicts.isEmpty else { await extractForMerge(items); return }
        let shown = conflicts.prefix(6).joined(separator: "\n")
        let more = conflicts.count > 6 ? "\n" + String(localized: "… ve \(conflicts.count - 6) dosya daha") : ""
        alert = AlertInfo(title: String(localized: "\(conflicts.count) dosya birden çok arşivde var"),
                          message: String(localized: "Aynı yola sahip dosyalarda listedeki SON arşivin dosyası kullanılır:\n\n\(shown)\(more)"),
                          confirm: .init(label: String(localized: "Birleştirmeye Devam Et"), destructive: false) { [weak self] in
                              Task { await self?.extractForMerge(items) }
                          })
    }

    private func extractForMerge(_ items: [(url: URL, listing: ArchiveListing, password: String?)]) async {
        removeMergeStaging()
        let staging = ArchiveService.temporaryRoot.appendingPathComponent("merge-\(UUID().uuidString)", isDirectory: true)
        mergeStaging = staging
        let svc = service
        for (i, item) in items.enumerated() {
            let tracker = ProgressTracker.forExtraction(entries: item.listing.entries, destination: staging, flatten: false,
                                                        engine: item.listing.engine, style: svc.progressStyle(for: item.listing.engine))
            let result = await perform(String(localized: "Birleştirmek için açılıyor (\(i + 1)/\(items.count)): \(item.url.lastPathComponent)"),
                                       tracker: tracker, warnings: { (r: OperationReport) in r.warnings }) {
                try await svc.extract(archive: item.url, selection: nil,
                                      options: ExtractOptions(destination: staging, overwrite: .overwrite, keepPaths: true),
                                      password: item.password, tracker: tracker)
            }
            if case .failure = result { removeMergeStaging(); return }
        }
        let tops = ((try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !tops.isEmpty else {
            removeMergeStaging()
            alert = AlertInfo(title: String(localized: "Birleştirilecek içerik yok"), message: String(localized: "Seçili arşivler boş."))
            return
        }
        sheet = .add(AddRequest(sources: tops, defaultName: String(localized: "Birleşik arşiv"),
                                defaultFolder: items[0].url.deletingLastPathComponent()))
    }

    private func removeMergeStaging() {
        if let root = mergeStaging { try? FileManager.default.removeItem(at: root) }
        mergeStaging = nil
    }

    // MARK: - Arşivleri karşılaştırma

    func showCompare() {
        let archives = selectedArchiveFilesInOrder
        guard canCompare, archives.count == 2 else { return }
        Task {
            var listings: [ArchiveListing] = []
            for a in archives {
                do { listings.append(try await listWithPassword(a).0) }
                catch ArchiveError.cancelled { return }
                catch { alert = AlertInfo(title: String(localized: "“\(a.lastPathComponent)” açılamadı"), message: error.localizedDescription); return }
            }
            let result = ArchiveComparison.compare(listings[0].entries, listings[1].entries)
            sheet = .compare(CompareRequest(firstName: archives[0].lastPathComponent,
                                            secondName: archives[1].lastPathComponent, result: result))
        }
    }

    // MARK: - Görüntüleme / birlikte açma

    func quickLook() {
        if isInArchive {
            if let row = selectedRows.first(where: { !$0.isDirectory }) { openEntry(row, quickLook: true) }
        } else if let url = selectedRows.first(where: { !$0.isDirectory })?.url {
            previewURL = url
        }
    }

    func openEntry(_ row: Row, quickLook: Bool) {
        guard let archive = archiveURL, let entry = row.entry, !row.isDirectory else { return }
        let svc = service
        Task {
            let url = await performWithPassword(
                archive: archive, title: String(localized: "Açılıyor: \(entry.name)"), initialPassword: archivePassword, delayed: true,
                makeTracker: { ProgressTracker() },
                work: { pw, tracker in
                    try await svc.extractForPreview(archive: archive, entry: entry, password: pw, tracker: tracker)
                })
            guard let url else { return }
            if quickLook { previewURL = url } else { NSWorkspace.shared.open(url) }
        }
    }

    // MARK: - Silme

    func confirmDelete() {
        let rows = selectedRows
        guard !rows.isEmpty else { return }
        let what = rows.count == 1 ? "“\(rows[0].name)”" : String(localized: "\(rows.count) öğe")
        if isInArchive {
            alert = AlertInfo(title: String(localized: "Arşivden silinsin mi?"),
                              message: String(localized: "\(what) arşivden kalıcı olarak silinecek. Bu işlem geri alınamaz."),
                              confirm: .init(label: String(localized: "Sil"), destructive: true) { [weak self] in
                                  Task { await self?.runDeleteFromArchive(rows) }
                              })
        } else {
            alert = AlertInfo(title: String(localized: "Çöp Kutusu’na taşınsın mı?"),
                              message: String(localized: "\(what) Çöp Kutusu’na taşınacak."),
                              confirm: .init(label: String(localized: "Çöp Kutusu’na Taşı"), destructive: true) { [weak self] in
                                  self?.trash(rows.compactMap(\.url))
                              })
        }
    }

    private func trash(_ urls: [URL]) {
        NSWorkspace.shared.recycle(urls) { [weak self] _, error in
            Task { @MainActor in
                if let error { self?.alert = AlertInfo(title: String(localized: "Taşınamadı"), message: error.localizedDescription) }
                self?.reloadFolder()
            }
        }
    }

    private func runDeleteFromArchive(_ rows: [Row]) async {
        guard let archive = archiveURL else { return }
        let chosen = rows.map { $0.entry ?? ArchiveEntry(path: $0.archivePath, isDirectory: $0.isDirectory, size: $0.sizeValue) }
        let svc = service
        let ok = await performWithPassword(
            archive: archive, title: String(localized: "Siliniyor"), initialPassword: archivePassword,
            makeTracker: { ProgressTracker() },
            warnings: { (r: OperationReport) in r.warnings },
            work: { pw, tracker in try await svc.delete(from: archive, entries: chosen, password: pw, tracker: tracker) })
        if ok != nil { selection = []; await reloadArchive() }
    }

    // MARK: - Yeniden adlandırma / yorum / kurtarma / kilit / onarım

    func promptRename() {
        guard isInArchive, canModifyArchive, let row = selectedRows.first, selectedRows.count == 1,
              let archive = archiveURL else { return }
        let entry = row.entry ?? ArchiveEntry(path: row.archivePath, isDirectory: row.isDirectory, size: 0)
        sheet = .prompt(PromptRequest(title: String(localized: "Yeniden adlandır"), message: String(localized: "“\(row.name)” için yeni ad:"),
                                      initialText: row.name, confirmLabel: String(localized: "Yeniden Adlandır")) { [weak self] newName in
            guard let self, !newName.isEmpty, newName != row.name, !newName.contains("/") else { return }
            let parent = entry.parentPath
            let newPath = parent.isEmpty ? newName : parent + "/" + newName
            let svc = self.service
            Task {
                let ok = await self.performWithPassword(
                    archive: archive, title: String(localized: "Yeniden adlandırılıyor"), initialPassword: self.archivePassword,
                    makeTracker: { ProgressTracker() },
                    work: { pw, _ in try await svc.rename(in: archive, entry: entry, newPath: newPath, password: pw) })
                if ok != nil { await self.reloadArchive() }
            }
        })
    }

    func promptComment() {
        guard isInArchive, canEditRARFeatures, let archive = archiveURL else { return }
        sheet = .prompt(PromptRequest(title: String(localized: "Arşiv yorumu"), message: String(localized: "Yorum metni (boş bırakırsanız mevcut yorum değişmez):"),
                                      initialText: listing?.info.comment ?? "", multiline: true) { [weak self] text in
            guard let self, !text.isEmpty else { return }
            let svc = self.service
            Task {
                let ok = await self.performWithPassword(
                    archive: archive, title: String(localized: "Yorum yazılıyor"), initialPassword: self.archivePassword,
                    makeTracker: { ProgressTracker() },
                    work: { pw, _ in try await svc.setComment(archive: archive, comment: text, password: pw) })
                if ok != nil { await self.reloadArchive() }
            }
        })
    }

    func promptRecoveryRecord() {
        guard isInArchive, canEditRARFeatures, let archive = archiveURL else { return }
        sheet = .prompt(PromptRequest(title: String(localized: "Kurtarma kaydı ekle"),
                                      message: String(localized: "Arşiv boyutuna göre kurtarma kaydı yüzdesi (1–10):"),
                                      initialText: "3") { [weak self] text in
            guard let self, let percent = Int(text.trimmingCharacters(in: .whitespaces)), (1...10).contains(percent) else { return }
            let svc = self.service
            Task {
                let ok = await self.performWithPassword(
                    archive: archive, title: String(localized: "Kurtarma kaydı ekleniyor"), initialPassword: self.archivePassword,
                    makeTracker: { ProgressTracker() },
                    work: { pw, _ in try await svc.addRecoveryRecord(archive: archive, percent: percent, password: pw) })
                if ok != nil { await self.reloadArchive() }
            }
        })
    }

    func confirmLock() {
        guard isInArchive, canEditRARFeatures, let archive = archiveURL else { return }
        alert = AlertInfo(title: String(localized: "Arşiv kilitlensin mi?"),
                          message: String(localized: "Kilitli bir arşiv bir daha değiştirilemez. Bu işlem geri alınamaz."),
                          confirm: .init(label: String(localized: "Kilitle"), destructive: true) { [weak self] in
            guard let self else { return }
            let svc = self.service
            Task {
                _ = await self.performWithPassword(
                    archive: archive, title: String(localized: "Arşiv kilitleniyor"), initialPassword: self.archivePassword,
                    makeTracker: { ProgressTracker() },
                    work: { _, _ in try await svc.lock(archive: archive) })
                await self.reloadArchive()
            }
        })
    }

    func runRepair() async {
        let archive: URL
        if let a = archiveURL { archive = a } else if let a = selectedArchiveFiles.first { archive = a } else { return }
        let svc = service
        let fixed = await performWithPassword(
            archive: archive, title: String(localized: "Onarılıyor: \(archive.lastPathComponent)"), initialPassword: nil,
            makeTracker: { ProgressTracker() },
            work: { _, tracker in try await svc.repair(archive: archive, tracker: tracker) })
        if let fixed {
            alert = AlertInfo(title: String(localized: "Onarım tamamlandı"), message: String(localized: "Onarılan arşiv şu adla kaydedildi:\n\(fixed.lastPathComponent)"))
            if !isInArchive { reloadFolder(); selectFile(fixed) }
            else { NSWorkspace.shared.activateFileViewerSelecting([fixed]) }
        }
    }

    // MARK: - Bilgi

    func showPasswordManager() { sheet = .passwordManager }

    func showInfo() {
        if isInArchive { sheet = .info; return }
        guard let url = selectedArchiveFiles.first else { return }
        Task {
            await loadArchive(url)
            if isInArchive { sheet = .info }
        }
    }

    // MARK: - Yardımcı eylemler

    func revealSelectionInFinder() {
        let urls = selectedFileURLs
        if !urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        } else if let a = archiveURL {
            NSWorkspace.shared.activateFileViewerSelecting([a])
        }
    }

    func copyPathOfSelection() {
        let text: String
        if isInArchive { text = selectedRows.map(\.archivePath).joined(separator: "\n") }
        else { text = selectedFileURLs.map(\.path).joined(separator: "\n") }
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func selectAll() { selection = Set(rows.map(\.id)) }

    func promptOpenArchive() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folderURL
        panel.prompt = String(localized: "Aç")
        panel.message = String(localized: "Açılacak arşivi seçin")
        if panel.runModal() == .OK, let url = panel.url { openArchive(url) }
    }

    func promptOpenFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = folderURL
        panel.prompt = String(localized: "Aç")
        if panel.runModal() == .OK, let url = panel.url { openFolder(url) }
    }
}
