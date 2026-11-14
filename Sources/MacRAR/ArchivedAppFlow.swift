import SwiftUI
import UniformTypeIdentifiers
import AppKit
import MacRARCore

/// Arşivdeki bir uygulamanın `Info.plist`'ten okunan adı, sürümü ve simgesi.
struct ArchivedAppDetails {
    let info: AppBundleInfo
    let icon: NSImage?
}

/// Arşivdeki Mac uygulamaları: tanınan uygulama için bilgi çubuğu, çıkarma ve Uygulamalar klasörüne kurma.
extension AppModel {
    private static let detailLimit = 8

    func archivedApp(for row: Row) -> ArchivedApp? {
        guard isInArchive, row.isDirectory else { return nil }
        return archivedApps.first { $0.path == row.archivePath }
    }

    func archivedAppIcon(for row: Row) -> NSImage? {
        guard let app = archivedApp(for: row) else { return nil }
        return archivedAppDetails[app.path]?.icon ?? Icons.applicationIcon()
    }

    func displayName(of app: ArchivedApp) -> String {
        archivedAppDetails[app.path]?.info.name ?? app.name
    }

    /// Liste değişince çağrılır. Ad, sürüm ve simge için yalnızca iki küçük dosya geçici klasöre çıkarılır;
    /// parola henüz bilinmiyorsa sorulmaz, çubuk dosya adıyla görünür.
    func refreshArchivedApps() {
        guard let archive = archiveURL, let entries = listing?.entries else {
            archivedApps = []
            archivedAppDetails = [:]
            return
        }
        archivedApps = ArchivedApps.find(in: entries)
        archivedAppDetails = [:]
        let svc = service
        let password = archivePassword
        for app in archivedApps.prefix(Self.detailLimit) {
            guard let plist = entries.first(where: { $0.path == app.plistPath }), !plist.isEncrypted || password != nil else { continue }
            Task {
                guard let url = try? await svc.extractForPreview(archive: archive, entry: plist, password: password),
                      let data = try? Data(contentsOf: url), let info = AppBundleInfo(plist: data) else { return }
                var icon: NSImage?
                if let file = info.iconFileName, let entry = entries.first(where: { $0.path == app.resourcePath(file) }),
                   let iconURL = try? await svc.extractForPreview(archive: archive, entry: entry, password: password) {
                    icon = NSImage(contentsOf: iconURL)
                }
                guard archiveURL == archive, archivedApps.contains(app) else { return }
                archivedAppDetails[app.path] = ArchivedAppDetails(info: info, icon: icon)
            }
        }
    }

    /// Satıra çift tıklama: klasöre girmek yerine ne yapılacağı sorulur.
    func askArchivedAppAction(_ app: ArchivedApp) {
        alert = AlertInfo(title: displayName(of: app),
                          message: String(localized: "Bu öğe bir Mac uygulaması. Ne yapmak istersiniz?"),
                          confirm: .init(label: String(localized: "Uygulamalar’a Kur"), destructive: false) { [weak self] in
                              Task { await self?.installArchivedApp(app) }
                          },
                          extras: [.init(label: String(localized: "Çıkar"), destructive: false) { [weak self] in
                                       Task { await self?.extractArchivedApp(app) }
                                   },
                                   .init(label: String(localized: "İçeriğe Bak"), destructive: false) { [weak self] in
                                       self?.enterArchivePath(app.path)
                                   }])
    }

    /// Yalnızca uygulamayı geçici klasöre çıkarır, karantina işaretini taşır ve denetler. Hata işlem penceresinde gösterilir.
    private func prepare(_ app: ArchivedApp) async -> (inspected: AppInstaller.Inspected, work: URL)? {
        guard let archive = archiveURL, let listing else { return nil }
        let svc = service
        let selection = ArchiveSelection.expand([ArchiveEntry(path: app.path, isDirectory: true, size: 0)], in: listing.entries)
        let work = ArchiveService.temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let options = ExtractOptions(destination: work, overwrite: .overwrite, keepPaths: true)
        let engine = listing.engine
        let unpacked = work.appendingPathComponent(app.path, isDirectory: true)
        let inspected: AppInstaller.Inspected? = await performWithPassword(
            archive: archive,
            title: String(localized: "Çıkarılıyor: \(app.fileName)"),
            initialPassword: archivePassword,
            makeTracker: {
                ProgressTracker.forExtraction(entries: selection, destination: work, flatten: false,
                                              engine: engine, style: svc.progressStyle(for: engine))
            },
            work: { password, tracker in
                try await svc.extract(archive: archive, selection: selection, options: options, password: password, tracker: tracker)
                AppInstaller.applyQuarantine(from: archive, to: unpacked)
                return try await AppInstaller.inspect(unpacked)
            })
        guard let inspected else {
            try? FileManager.default.removeItem(at: work)
            return nil
        }
        return (inspected, work)
    }

    /// Arşivin yanına çıkarır; aynı ada sahip bir şeyin üzerine yazmaz.
    func extractArchivedApp(_ app: ArchivedApp) async {
        guard let archive = archiveURL, let prepared = await prepare(app) else { return }
        defer { try? FileManager.default.removeItem(at: prepared.work) }
        let destination = AppInstaller.uniqueDestination(for: app.fileName, in: archive.deletingLastPathComponent())
        do {
            try FileManager.default.moveItem(at: prepared.inspected.url, to: destination)
        } catch {
            alert = AlertInfo(title: String(localized: "Uygulama çıkarılamadı"), message: error.localizedDescription)
            return
        }
        revealInFinder([destination])
        showNotice(String(localized: "“\(destination.lastPathComponent)” çıkarıldı"))
    }

    func installArchivedApp(_ app: ArchivedApp) async {
        guard let prepared = await prepare(app) else { return }
        await finishInstall(prepared.inspected, fileName: app.fileName, fallbackName: app.name, work: prepared.work)
    }

    // MARK: Uygulamalar'a sürükleyip bırakma

    /// Arşivden sürüklenen öğe kenar çubuğundaki Uygulamalar'a bırakıldı. Öğe uygulamanın kendisi ya da onu içeren
    /// tek üst klasör olabilir; kurma, Uygulamalar'a Kur düğmesiyle aynı yoldan gider.
    func handleDropOnApplications(_ refs: [ArchiveItemRef]) -> Bool {
        guard refs.count == 1, let archive = archiveURL, refs[0].archivePath == archive.path else { return false }
        let path = refs[0].entryPath
        let matches = archivedApps.filter { $0.path == path || $0.path.hasPrefix(path + "/") }
        guard matches.count == 1 else { return false }
        Task { await installArchivedApp(matches[0]) }
        return true
    }

    static let applicationsDropTypes: [UTType] = [.macrarArchiveItem, .folder, .data]

    /// Kenar çubuğundaki Uygulamalar'a bırakılanlar. Önce MacRAR'ın kaydı aranır; yoksa macOS'un verdiği dosyanın adı
    /// son sürüklemeyle eşlenir. İçerik eşzamansız okunur.
    func handleApplicationsDrop(_ providers: [NSItemProvider]) -> Bool {
        guard providers.count == 1, isInArchive, !archivedApps.isEmpty else { return false }
        let provider = providers[0]
        let refType = UTType.macrarArchiveItem.identifier
        if provider.hasItemConformingToTypeIdentifier(refType) {
            provider.loadDataRepresentation(forTypeIdentifier: refType) { data, _ in
                guard let data, let ref = try? JSONDecoder().decode(ArchiveItemRef.self, from: data) else { return }
                Task { @MainActor in _ = AppModel.shared.handleDropOnApplications([ref]) }
            }
            return true
        }
        guard let type = provider.registeredTypeIdentifiers.first(where: {
            UTType($0).map { $0.conforms(to: .folder) || $0.conforms(to: .data) } ?? false
        }) else { return false }
        provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
            guard let name = url?.lastPathComponent else { return }
            Task { @MainActor in AppModel.shared.handleDroppedFileNamed(name) }
        }
        return true
    }

    /// Kayıt gelmediyse: bırakılan dosyanın adı son sürüklenen satırla eşleşiyorsa o satırın uygulaması kurulur.
    func handleDroppedFileNamed(_ name: String) {
        guard let archive = archiveURL, let drag = DragRecord.shared.latest, drag.archive == archive,
              Date().timeIntervalSince(drag.at) < 300,
              name.precomposedStringWithCanonicalMapping == (drag.rootPath as NSString).lastPathComponent.precomposedStringWithCanonicalMapping
        else { return }
        _ = handleDropOnApplications([ArchiveItemRef(archivePath: archive.path, entryPath: drag.rootPath)])
    }

    /// Bırakılan öğe arşivden mi sürüklendi (pencereye geri bırakıldığında arşive eklenmesin)? macOS kopyayı başka bir
    /// yerde verebildiği için son sürüklemeyle ad ve zamana göre de eşlenir.
    func isFromArchiveDrag(_ url: URL) -> Bool {
        let root = ArchiveService.temporaryRoot.resolvingSymlinksInPath().pathComponents
        if Array(url.resolvingSymlinksInPath().pathComponents.prefix(root.count)) == root { return true }
        guard let drag = DragRecord.shared.latest, drag.archive == archiveURL, Date().timeIntervalSince(drag.at) < 300 else { return false }
        return url.lastPathComponent.precomposedStringWithCanonicalMapping == drag.url.lastPathComponent.precomposedStringWithCanonicalMapping
    }

    /// Denetlenmiş uygulama için ortak kurma adımları: gerekiyorsa sorar, sonra yerine koyar.
    private func finishInstall(_ inspected: AppInstaller.Inspected, fileName: String, fallbackName: String, work: URL) async {
        let name = inspected.info.name ?? fallbackName
        func discard() { try? FileManager.default.removeItem(at: work) }

        if inspected.info.identifier == Bundle.main.bundleIdentifier {
            discard()
            alert = AlertInfo(title: String(localized: "MacRAR kendini bu yolla kuramaz"),
                              message: String(localized: "MacRAR’ı güncellemek için MacRAR menüsünden Güncellemeleri Denetle… komutunu kullanın."))
            return
        }

        let destination = applicationsFolder.appendingPathComponent(fileName, isDirectory: true)
        let exists = FileManager.default.fileExists(atPath: destination.path)
        let existing = (try? Data(contentsOf: destination.appendingPathComponent("Contents/Info.plist"))).flatMap(AppBundleInfo.init(plist:))
        if exists {
            let running = NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.standardizedFileURL == destination.standardizedFileURL }
            if running {
                discard()
                alert = AlertInfo(title: String(localized: "\(name) açık"),
                                  message: String(localized: "Kurmadan önce uygulamayı kapatın, sonra yeniden deneyin."))
                return
            }
        }

        var questions: [String] = []
        if let existing {
            let old = existing.version ?? "?"
            questions.append(String(localized: "Uygulamalar klasöründe sürüm \(old) var; \(inspected.info.version ?? "?") ile değiştirilecek. Eski kopya Çöp Sepeti’ne taşınır."))
            if existing.identifier != inspected.info.identifier {
                questions.append(String(localized: "Dikkat: Var olan uygulama aynı adda ama farklı bir uygulama."))
            }
        } else if exists {
            questions.append(String(localized: "Uygulamalar klasöründe aynı adda bir öğe var. Çöp Sepeti’ne taşınacak."))
        }
        if inspected.signature == .unsigned {
            questions.append(String(localized: "Bu uygulama imzasız; kaynağına güveniyorsanız kurun."))
        }

        if questions.isEmpty {
            await place(inspected, at: destination, name: name, work: work)
        } else {
            alert = AlertInfo(title: String(localized: "\(name) kurulsun mu?"), message: questions.joined(separator: "\n\n"),
                              confirm: .init(label: String(localized: "Kur"), destructive: false) { [weak self] in
                                  Task { await self?.place(inspected, at: destination, name: name, work: work) }
                              },
                              onCancel: discard)
        }
    }

    private func place(_ inspected: AppInstaller.Inspected, at destination: URL, name: String, work: URL) async {
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            try await AppInstaller.install(inspected.url, at: destination)
        } catch is CancellationError {
            return
        } catch {
            alert = AlertInfo(title: String(localized: "\(name) kurulamadı"), message: error.localizedDescription)
            return
        }
        alert = AlertInfo(title: String(localized: "\(name) kuruldu"),
                          message: String(localized: "Uygulama Uygulamalar klasörüne kondu. İnternetten indirildiyse macOS ilk açılışta onay isteyebilir."),
                          confirm: .init(label: String(localized: "Aç"), destructive: false) { NSWorkspace.shared.open(destination) },
                          extras: [.init(label: String(localized: "Finder’da Göster"), destructive: false) {
                              self.revealInFinder([destination])
                          }],
                          cancelLabel: String(localized: "Kapat"))
    }
}

/// Arşivde uygulama varsa dosya listesinin üstünde görünür.
struct ArchivedAppBanner: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            if model.archivedApps.count == 1, let app = model.archivedApps.first {
                Image(nsImage: model.archivedAppDetails[app.path]?.icon ?? Icons.applicationIcon())
                    .resizable().frame(width: 24, height: 24)
                Text("Bu arşiv bir Mac uygulaması içeriyor: \(title(of: app))")
                    .font(.callout).lineLimit(2).minimumScaleFactor(0.9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                Button("Çıkar") { Task { await model.extractArchivedApp(app) } }
                    .controlSize(.small).fixedSize()
                    .disabled(model.operation != nil)
                Button("Uygulamalar’a Kur") { Task { await model.installArchivedApp(app) } }
                    .buttonStyle(.borderedProminent).controlSize(.small).fixedSize()
                    .disabled(model.operation != nil)
            } else {
                Image(nsImage: Icons.applicationIcon()).resizable().frame(width: 24, height: 24)
                Text("Bu arşivde \(model.archivedApps.count) Mac uygulaması var. Kurmak ya da çıkarmak için listeden birine çift tıklayın ya da Uygulamalar’a sürükleyin.")
                    .font(.callout).lineLimit(2).minimumScaleFactor(0.9)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 36, maxHeight: 52)
        .background(Color.accentColor.opacity(0.12))
    }

    private func title(of app: ArchivedApp) -> String {
        let name = model.displayName(of: app)
        guard let version = model.archivedAppDetails[app.path]?.info.version else { return name }
        return "\(name) \(version)"
    }
}
