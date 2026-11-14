import SwiftUI
import AppKit
import QuickLook
import MacRARCore

extension View {
    /// `ModifiedContent.modifier` özelliğiyle çakışmadan ViewModifier uygular.
    func with<M: ViewModifier>(_ m: M) -> some View { modifier(m) }
}

struct MainView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        chrome
            .background(MainWindowHider(model: model))
            .tint(Brand.blue)
            .onAppear {
                // İlk normal açılışta Kurulum Yardımcısı; Finder'dan başlatılan hızlı işlemlerde gösterme.
                if SetupAssistant.needsFirstRun, !SetupAssistant.consumeSkipOnce(), !model.quickSession { openWindow(id: "setup") }
            }
            .with(AppOverlayModifier(model: model))
            .with(AppSheetsModifier(model: model))
            .with(AppAlertModifier(model: model))
            .quickLookPreview($model.previewURL)
            .dropDestination(for: URL.self) { urls, _ in
                model.handleDrop(urls)
                return true
            }
    }

    /// Başlık, arama alanı ve satır yenileme tetikleyicileri.
    private var chrome: some View {
        content
            .navigationTitle("MacRAR")   // pencere başlığı her zaman uygulamayı belirtir (Finder ile karışmasın)
            .navigationSubtitle(model.windowTitle)
            .searchable(text: $model.searchText, placement: .toolbar,
                        prompt: model.isInArchive ? Text("Arşivde ara") : Text("Bu klasörde ara"))
            .onChange(of: model.searchText) { model.refreshRows() }
            .onChange(of: model.sortOrder) { model.refreshRows() }
    }

    private var content: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 150, ideal: 190, max: 260)
        } detail: {
            DetailView(model: model)
        }
    }
}

struct AppOverlayModifier: ViewModifier {
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        content
            .overlay {
                if let op = model.operation {
                    OperationOverlay(op: op) { model.dismissOperation() }
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: model.operation?.id)
    }
}

struct AppSheetsModifier: ViewModifier {
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { model.sheetInPanel ? nil : model.sheet }, set: { model.sheet = $0 })) { sheet in
            switch sheet {
            case .add(let r): AddSheet(model: model, request: r)
            case .compare(let r): CompareSheet(request: r)
            case .extract(let r): ExtractSheet(model: model, request: r)
            case .password(let r): PasswordSheet(request: r, vault: model.vault)
            case .prompt(let r): PromptSheet(request: r)
            case .info: InfoSheet(model: model)
            case .passwordManager: PasswordManagerSheet(model: model)
            }
        }
    }
}

struct AppAlertModifier: ViewModifier {
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        content.alert(model.alert?.title ?? "", isPresented: isPresented, presenting: model.alert) { info in
            if let c = info.confirm {
                Button(c.label, role: c.destructive ? .destructive : nil) { c.action() }
                ForEach(info.extras.indices, id: \.self) { i in
                    Button(info.extras[i].label) { info.extras[i].action() }
                }
                if let label = info.cancelLabel {
                    Button(label, role: .cancel) { info.onCancel?() }
                } else {
                    Button("İptal", role: .cancel) { info.onCancel?() }
                }
            } else {
                Button("Tamam") {}
            }
        } message: { info in
            Text(info.message)
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })
    }
}

// MARK: - Detay bölmesi

struct DetailView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            BrandHeader(model: model)
            ActionBar(model: model)
            Divider()
            PathBar(model: model)
            Divider()
            if !model.tools.canReadRAR || !model.tools.canWriteRAR {
                ToolsBanner(model: model)
            }
            if model.isInArchive, !model.archivedApps.isEmpty {
                ArchivedAppBanner(model: model)
                Divider()
            }
            ZStack {
                FileTableView(model: model)
                if model.isLoading {
                    ProgressView().controlSize(.large)
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                if let err = model.folderError, !model.isInArchive {
                    ContentUnavailableView("Klasör okunamadı", systemImage: "lock.slash", description: Text(err))
                }
            }
            // Tablo satır sayısı kadar yükseklik istemesin: kalan alanı doldurup kaydırılsın, üst/alt şeritler görünür kalsın.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            Divider()
            StatusBar(model: model)
        }
        .overlay(alignment: .bottom) {
            if let text = model.notice {
                Label(text, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                    .padding(.bottom, 44)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.notice)
    }
}

struct ToolsBanner: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            // Metin en çok iki satır olur; dar genişlikte harf harf kırılıp düzeni şişirmesin.
            Text(model.rarInstallMessage ?? message)
                .font(.callout)
                .lineLimit(2)
                .minimumScaleFactor(0.9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            if let progress = model.rarInstallProgress {
                ProgressView().controlSize(.small)
                Text(progress).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            } else {
                Button("RAR’ı indir ve kur") { Task { await model.installRAR() } }
                    .buttonStyle(.borderedProminent).controlSize(.small).fixedSize()
                // Sarı/zeytin zeminde vurgu mavisi okunmuyordu: düz stil + kendi rengi.
                SettingsLink {
                    Text("Ayarlar…")
                        .font(.callout)
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain).fixedSize()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 36, maxHeight: 52)
        .background(.yellow.opacity(0.15))
    }

    private var message: String {
        if !model.tools.canReadRAR {
            return String(localized: "RAR arşivleri açılamıyor: unrar bulunamadı. ‘RAR’ı indir ve kur’ ile RARLAB’ın resmi araçlarını kurun. ZIP/7Z/TAR çalışır.")
        }
        return String(localized: "‘rar’ kurulu değil: RAR arşivleri açılabilir ama oluşturulamaz ve düzenlenemez. ZIP/7Z/TAR çalışır.")
    }
}

// MARK: - Eylem çubuğu (WinRAR tarzı büyük düğmeler)

struct ActionBar: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 2) {
            ToolButton(title: "Ekle", systemImage: "plus.rectangle.on.folder.fill", enabled: model.canAdd,
                       help: model.isInArchive ? "Arşive dosya ekle" : "Seçili dosyalardan arşiv oluştur (seçim yoksa dosya seçici açılır)") { model.showAdd() }
            ToolButton(title: "Çıkar", systemImage: "arrow.down.doc.fill", enabled: model.canExtract,
                       help: "Dosyaları bir klasöre çıkar") { model.showExtract() }
            ToolButton(title: "Sına", systemImage: "checkmark.shield.fill", enabled: model.canTest,
                       help: "Arşivdeki dosyaların bütünlüğünü denetle") { Task { await model.runTest() } }
            ToolButton(title: "Görüntüle", systemImage: "eye.fill", enabled: model.canView,
                       help: "Seçili dosyayı önizle (Boşluk)") { model.quickLook() }
            ToolButton(title: "Sil", systemImage: "trash.fill", enabled: model.canDelete,
                       help: model.isInArchive ? "Seçili öğeleri arşivden sil" : "Seçili öğeleri Çöp Kutusu’na taşı") { model.confirmDelete() }
            Divider().frame(height: 36).padding(.horizontal, 6)
            ToolButton(title: "Bilgi", systemImage: "info.circle.fill", enabled: model.canInfo,
                       help: "Arşiv bilgilerini göster") { model.showInfo() }
            ToolButton(title: "Onar", systemImage: "wrench.and.screwdriver.fill", enabled: model.canRepair,
                       help: "Bozuk RAR arşivini onar") { Task { await model.runRepair() } }
            if !model.isInArchive {
                Divider().frame(height: 36).padding(.horizontal, 6)
                ToolButton(title: "Birleştir", systemImage: "arrow.triangle.merge", enabled: model.canMerge,
                           help: "Seçili arşivleri (2 veya daha fazla) tek yeni arşivde birleştir") { model.beginMerge() }
                ToolButton(title: "Karşılaştır", systemImage: "arrow.left.arrow.right.square.fill", enabled: model.canCompare,
                           help: "Seçili iki arşivin içeriğini karşılaştır") { model.showCompare() }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .background(Brand.indigo.opacity(model.isInArchive ? 0.10 : 0.04))
    }
}

struct ToolButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var enabled = true
    var help: LocalizedStringKey = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 22))
                    .symbolRenderingMode(.hierarchical)
                    .frame(height: 26)
                Text(title).font(.caption)
            }
            .frame(width: 66, height: 52)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering && enabled ? Brand.blue.opacity(0.14) : .clear))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()   // ilk düğmede görünen mavi odak halkası arayüzü bozuyordu
        .foregroundStyle(enabled ? Brand.blue : Color.secondary.opacity(0.5))
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Yol çubuğu

struct PathBar: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Button { model.goUp() } label: { Image(systemName: "chevron.up") }
                .help(model.isInArchive && model.archivePath.isEmpty ? Text("Arşivi kapat") : Text("Üst klasör (⌘↑)"))
                .disabled(!model.isInArchive && model.folderURL.path == "/")
            Button { model.reloadCurrent() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Yenile (⌘R)")

            // Sığıyorsa sola yaslı; sığmıyorsa kaydırılır ve yolun sonu görünür.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 2) { crumbs }.padding(.horizontal, 4)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) { crumbs }.padding(.horizontal, 4)
                }
                .defaultScrollAnchor(.trailing)
            }

            Spacer(minLength: 0)
            if let info = model.listing?.info { ArchiveChips(info: info, engine: model.listing?.engine) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Brand.indigo.opacity(model.isInArchive ? 0.07 : 0))
    }

    @ViewBuilder private var crumbs: some View {
        if model.isInArchive, let archive = model.archiveURL {
            Button {
                model.enterArchivePath("")
            } label: {
                Label { Text(archive.lastPathComponent) } icon: { Image(nsImage: Icons.archiveIcon()).resizable().frame(width: 16, height: 16) }
            }
            .buttonStyle(.plain).fontWeight(.medium)
            let parts = model.archivePath.split(separator: "/").map(String.init)
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                Button(part) { model.enterArchivePath(parts[0...i].joined(separator: "/")) }.buttonStyle(.plain)
            }
        } else {
            let comps = model.folderURL.pathComponents
            ForEach(Array(comps.enumerated()), id: \.offset) { i, part in
                if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                Button(part == "/" ? "Macintosh HD" : part) {
                    let path = i == 0 ? "/" : "/" + comps[1...i].joined(separator: "/")
                    model.openFolder(URL(fileURLWithPath: path))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ArchiveChips: View {
    let info: ArchiveInfo
    let engine: ArchiveEngine?

    var body: some View {
        HStack(spacing: 4) {
            chip(info.formatName.isEmpty ? String(localized: "Arşiv") : info.formatName)
            if info.isSolid { chip(String(localized: "Katı")) }
            if info.hasEncryptedHeaders { chip(String(localized: "Adlar şifreli"), icon: "lock.fill") }
            if info.hasRecoveryRecord { chip(String(localized: "Kurtarma kaydı"), icon: "cross.case.fill") }
            if info.isVolume { chip(String(localized: "Çok parçalı"), icon: "square.stack.3d.up.fill") }
            if info.isLocked { chip(String(localized: "Kilitli"), icon: "lock.shield.fill") }
            if engine == .libarchive { chip(String(localized: "Salt okunur"), icon: "pencil.slash") }
        }
    }

    private func chip(_ text: String, icon: String? = nil) -> some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 9)) }
            Text(text).font(.caption2)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}

// MARK: - Durum çubuğu

struct StatusBar: View {
    let model: AppModel

    var body: some View {
        HStack {
            Image(systemName: model.isInArchive ? "archivebox" : "folder").foregroundStyle(.secondary)
            Text(leftText)
            Spacer()
            if let l = model.archiveStats {
                Text(archiveText(l)).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(.bar)
    }

    private func archiveText(_ l: AppModel.ArchiveStats) -> String {
        var text = String(localized: "Arşiv: \(l.files) dosya, \(l.folders) klasör · \(Format.bytes(l.size))")
        if l.packed > 0 { text += " → " + Format.bytes(l.packed) }
        if l.size > 0 && l.packed > 0 {
            let ratio = Int((Double(l.packed) / Double(l.size) * 100).rounded())
            text += " (" + String(localized: "%\(ratio)") + ")"
        }
        return text
    }

    private var leftText: String {
        let selected = model.selectedRows
        let pool = selected.isEmpty ? model.rows : selected
        let dirs = pool.filter(\.isDirectory).count
        let files = pool.count - dirs
        let size = pool.reduce(Int64(0)) { $0 + $1.sizeValue }
        var parts: [String] = []
        if dirs > 0 { parts.append(String(localized: "\(dirs) klasör")) }
        if files > 0 { parts.append(String(localized: "\(files) dosya")) }
        if parts.isEmpty { parts.append(String(localized: "Boş")) }
        let prefix = selected.isEmpty ? String(localized: "Toplam") : String(localized: "Seçili")
        let sizeText = files > 0 ? ", " + Format.bytes(size) : ""
        return "\(prefix): " + parts.joined(separator: ", ") + sizeText
    }
}

// MARK: - Kenar çubuğu

struct Place: Identifiable, Hashable {
    let title: String
    let icon: String
    let url: URL
    var id: URL { url }
}

struct SidebarView: View {
    @Bindable var model: AppModel

    private var places: [Place] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        func dir(_ d: FileManager.SearchPathDirectory) -> URL? { fm.urls(for: d, in: .userDomainMask).first }
        return [
            Place(title: String(localized: "Ana Klasör"), icon: "house", url: home),
            dir(.desktopDirectory).map { Place(title: String(localized: "Masaüstü"), icon: "menubar.dock.rectangle", url: $0) },
            dir(.documentDirectory).map { Place(title: String(localized: "Belgeler"), icon: "doc", url: $0) },
            dir(.downloadsDirectory).map { Place(title: String(localized: "İndirilenler"), icon: "arrow.down.circle", url: $0) },
            Place(title: String(localized: "Uygulamalar"), icon: "square.grid.2x2", url: URL(fileURLWithPath: "/Applications")),
        ].compactMap { $0 }
    }

    private var volumes: [Place] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey],
                                                          options: [.skipHiddenVolumes]) ?? []
        return urls.map { u in
            let name = (try? u.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? u.lastPathComponent
            return Place(title: name, icon: u.path == "/" ? "internaldrive" : "externaldrive", url: u)
        }
    }

    var body: some View {
        List(selection: Binding<URL?>(
            get: { model.isInArchive ? nil : model.folderURL },
            set: { if let u = $0 { model.openFolder(u) } })) {
            Section("Yerler") {
                ForEach(places) { p in
                    if p.url.path == "/Applications" {
                        ApplicationsPlace(place: p, model: model).tag(p.url)
                    } else {
                        Label(p.title, systemImage: p.icon).tag(p.url)
                    }
                }
            }
            Section("Aygıtlar") {
                ForEach(volumes) { p in Label(p.title, systemImage: p.icon).tag(p.url) }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { SidebarBrand() }
    }
}

/// Kenar çubuğundaki Uygulamalar: arşivdeki bir uygulama buraya sürüklenip bırakılınca kurulur.
private struct ApplicationsPlace: View {
    let place: Place
    let model: AppModel
    @State private var targeted = false

    var body: some View {
        Label(place.title, systemImage: place.icon)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(targeted ? 0.3 : 0)))
            // Düşük seviyede: içerik eşzamansız okunur, ana iş parçacığı sürüklenen dosyanın çıkarılmasını beklemez.
            .onDrop(of: AppModel.applicationsDropTypes, isTargeted: Binding(
                get: { targeted },
                set: { targeted = $0 && model.isInArchive && !model.archivedApps.isEmpty })) { providers in
                model.handleApplicationsDrop(providers)
            }
            .help(model.isInArchive && !model.archivedApps.isEmpty
                  ? Text("Arşivdeki uygulamayı kurmak için buraya sürükleyin") : Text(verbatim: ""))
    }
}

// MARK: - İlerleme kaplaması

struct OperationOverlay: View {
    let op: OperationState
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea()
            OperationCard(op: op, onClose: onClose)
                .padding(20)
                .frame(width: 480)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.3), radius: 20, y: 6)
        }
    }
}

/// İlerleme kartının içeriği: ana pencerenin kaplamasında ve Finder'dan başlatılan işlemlerin küçük ilerleme panelinde ortak.
struct OperationCard: View {
    let op: OperationState
    let onClose: () -> Void
    @State private var showLog = false

    var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    icon
                    Text(op.title).font(.headline).lineLimit(2)
                }

                switch op.phase {
                case .running:
                    if let f = op.fraction {
                        ProgressView(value: f)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text(op.currentFile.isEmpty ? " " : op.currentFile)
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    HStack {
                        if let f = op.fraction { Text("%\(Int(f * 100))").monospacedDigit() }
                        Spacer()
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(Format.duration(ctx.date.timeIntervalSince(op.startedAt))).monospacedDigit()
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                case .finished:
                    if !op.warnings.isEmpty {
                        Text("İşlem tamamlandı, ancak uyarılar var:").font(.callout)
                        Text(op.warnings.joined(separator: "\n"))
                            .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    }
                case .failed(let message):
                    Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }

                if !op.log.isEmpty {
                    DisclosureGroup("Ayrıntılar", isExpanded: $showLog) {
                        ScrollView {
                            Text(op.log.joined(separator: "\n"))
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(height: 130)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
                    }
                    .font(.callout)
                }

                HStack {
                    Spacer()
                    Button(op.isRunning ? String(localized: "İptal") : String(localized: "Kapat"), action: onClose)
                        .keyboardShortcut(op.isRunning ? .cancelAction : .defaultAction)
                }
            }
    }

    @ViewBuilder private var icon: some View {
        switch op.phase {
        case .running: Image(systemName: "gearshape.2.fill").foregroundStyle(Color.accentColor)
        case .finished: Image(systemName: op.warnings.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(op.warnings.isEmpty ? .green : .orange)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}


/// Ana pencere oluşunca, uygulama Finder komutuyla başlatıldıysa pencereyi gizler (bkz. `AppModel.launchedByFinderCommand`).
struct MainWindowHider: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> NSView { HiderView(model: model) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class HiderView: NSView {
        let model: AppModel
        init(model: AppModel) { self.model = model; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, model.inStartupGrace else { return }
            // Soğuk açılış: Finder komutu gelip gelmediği anlaşılana dek pencereyi gizle, gelmediyse göster.
            model.hideMainWindow(window)
            let wait = max(0.05, AppModel.startupGrace - Date().timeIntervalSince(model.processStartedAt) + 0.05)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [model] in
                if !model.launchedByFinderCommand { model.revealMainWindows() }
            }
        }
    }
}
