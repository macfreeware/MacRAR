import SwiftUI
import AppKit
import MacRARCore

/// GitLab'dan kendini güncellemenin arayüz akışı: denetleme, sorma, kurma ve yeniden açılma.
/// Pencere kipsizdir (modal değil): Finder'dan gelen bir komut, kullanıcı karar verene dek bekletilmez.
@MainActor
@Observable
final class UpdateController {
    static let shared = UpdateController()

    enum Phase: Equatable {
        case idle
        case offer(UpdateRelease)
        case working(String)
        case message(title: String, detail: String, page: URL?)
    }

    private(set) var phase = Phase.idle
    /// Hakkında penceresinde düğmenin altında yazan sonuç.
    var aboutResult: String?
    private(set) var isChecking = false

    @ObservationIgnored private var installTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Key {
        static let autoCheck = "updateAutoCheck"
        static let lastCheck = "updateLastCheck"
        static let skipped = "updateSkippedVersion"
    }

    private var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    private var isTurkish: Bool { Bundle.main.preferredLocalizations.first == "tr" }

    func whatsNew(in release: UpdateRelease) -> String { UpdateInfo.whatsNew(in: release.notes, turkish: isTurkish) }
    var canInstallHere: Bool { Updater.canReplaceApp(at: Bundle.main.bundleURL) }

    // MARK: Denetleme

    /// Açılıştan biraz sonra ve saatte bir bakar; asıl sıklığı `checkAutomatically` belirler. Uygulama günlerce açık kalabilir.
    func startAutomaticChecks() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        #if DEBUG
        guard Updater.testURL != nil else { return }
        #endif
        Task {
            try? await Task.sleep(for: .seconds(6))
            checkAutomatically()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAutomatically() }
        }
    }

    /// Ayar açıksa ve son denetimden bir gün geçtiyse sessizce bakar; yalnızca yeni sürüm varsa sorar.
    /// Finder'dan başlatılan penceresiz işlerde ve iş sürerken bakılmaz: sonraki saate kalır.
    func checkAutomatically() {
        let model = AppModel.shared
        guard defaults.object(forKey: Key.autoCheck) as? Bool ?? true,
              phase == .idle, !isChecking, model.isIdleForUpdate,
              !model.launchedByFinderCommand, model.hasVisibleWindow() else { return }
        let last = Date(timeIntervalSince1970: defaults.double(forKey: Key.lastCheck))
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        Task {
            guard case .newer(let release) = await check(), defaults.string(forKey: Key.skipped) != release.version else { return }
            if phase == .idle, !model.quickSession { show(.offer(release)) }
        }
    }

    enum Outcome { case upToDate, newer(UpdateRelease), failed(String) }

    private func check() async -> Outcome {
        isChecking = true
        defer { isChecking = false }
        do {
            let release = try await Updater.fetchLatest()
            defaults.set(Date().timeIntervalSince1970, forKey: Key.lastCheck)
            return UpdateInfo.isNewer(release.version, than: currentVersion) ? .newer(release) : .upToDate
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Menü ve Ayarlar: sonuç her durumda söylenir.
    func checkFromMenu() {
        if case .working = phase { return UpdatePanel.shared.show(controller: self) }
        guard !isChecking else { return }
        Task {
            switch await check() {
            case .newer(let release): show(.offer(release))
            case .upToDate:
                show(.message(title: String(localized: "MacRAR güncel."),
                              detail: String(localized: "Kullandığınız sürüm (\(currentVersion)) en son sürüm."), page: nil))
            case .failed(let message):
                show(.message(title: String(localized: "Güncellemeler denetlenemedi."), detail: message, page: nil))
            }
        }
    }

    /// Hakkında: sonuç pencerenin içinde yazar; yeni sürüm varsa true döner ve güncelleme penceresi açılır.
    func checkFromAbout() async -> Bool {
        guard !isChecking else { return false }
        aboutResult = nil
        switch await check() {
        case .newer(let release):
            show(.offer(release))
            return true
        case .upToDate:
            aboutResult = String(localized: "MacRAR güncel (\(currentVersion)).")
        case .failed(let message):
            aboutResult = String(localized: "Güncellemeler denetlenemedi.") + " " + message
        }
        return false
    }

    // MARK: Pencere

    private func show(_ next: Phase) {
        if case .working = phase { return }
        phase = next
        UpdatePanel.shared.show(controller: self)
    }

    func later() { close() }

    func skip(_ release: UpdateRelease) {
        defaults.set(release.version, forKey: Key.skipped)
        close()
    }

    func openPage(_ url: URL) {
        NSWorkspace.shared.open(url)
        close()
    }

    func close() {
        installTask?.cancel()
        phase = .idle
        UpdatePanel.shared.hide()
    }

    /// Kullanıcı pencereyi kapatma düğmesiyle kapattı.
    func panelClosed() {
        installTask?.cancel()
        phase = .idle
    }

    // MARK: Kurma

    func install(_ release: UpdateRelease) {
        guard AppModel.shared.isIdleForUpdate else { return }
        phase = .working(String(localized: "Sürüm \(release.version) indiriliyor ve doğrulanıyor…"))
        installTask = Task { [weak self] in
            let app = Bundle.main.bundleURL
            do {
                let prepared = try await Updater.prepare(release, replacing: app, bundleID: Bundle.main.bundleIdentifier ?? "")
                defer { prepared.discard() }
                // İndirme sırasında yeni bir iş başladıysa bitmesi beklenir; değiştirme bu kontrolle aynı anda yapılır.
                if !AppModel.shared.isIdleForUpdate {
                    self?.phase = .working(String(localized: "Süren işin bitmesi bekleniyor…"))
                    while !AppModel.shared.isIdleForUpdate { try await Task.sleep(for: .milliseconds(300)) }
                }
                try Task.checkCancellation()
                let extensionWasOn = await AboutView.probeFinderExtension() == .enabled
                guard AppModel.shared.isIdleForUpdate else { throw CancellationError() }
                try Updater.replace(appAt: app, with: prepared)
                prepared.discard()
                self?.relaunch(app: app, refreshingExtension: extensionWasOn)
            } catch {
                self?.installFailed(error, release: release)
            }
        }
    }

    private func installFailed(_ error: Error, release: UpdateRelease) {
        if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return close() }
        phase = .idle
        show(.message(title: String(localized: "Güncelleme kurulamadı."),
                      detail: error.localizedDescription + "\n\n" + String(localized: "İsterseniz yeni sürümü indirme sayfasından elle kurabilirsiniz."),
                      page: release.page))
    }

    /// Uygulama kapanınca yeni paketi sisteme tanıtan ve açan küçük bir kabuk işi bırakır, sonra kapanır.
    private func relaunch(app: URL, refreshingExtension: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", UpdateInfo.relaunchScript(processID: ProcessInfo.processInfo.processIdentifier),
                       app.path, refreshingExtension ? "1" : "0"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        UpdatePanel.shared.hide()
        NSApp.terminate(nil)
    }
}

/// Güncelleme penceresi; diğer bağımsız pencereler gibi (bkz. `SheetPanel`) ana pencereden ayrıdır.
@MainActor
final class UpdatePanel: NSObject, NSWindowDelegate {
    static let shared = UpdatePanel()
    private var panel: NSPanel?
    private weak var controller: UpdateController?

    func show(controller: UpdateController) {
        self.controller = controller
        if let panel, panel.isVisible { panel.makeKeyAndOrderFront(nil); return }
        let hosting = NSHostingController(rootView: UpdatePanelView(controller: controller, model: .shared))
        hosting.sizingOptions = [.preferredContentSize]
        let p = NSPanel(contentViewController: hosting)
        p.styleMask = [.titled, .closable]
        p.title = "MacRAR"
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        p.delegate = self
        p.center()
        panel = p
        p.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }

    func hide() {
        guard let panel else { return }
        panel.delegate = nil
        panel.orderOut(nil)
        self.panel = nil
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        controller?.panelClosed()
    }
}

private struct UpdatePanelView: View {
    let controller: UpdateController
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch controller.phase {
            case .offer(let release): offer(release)
            case .working(let status): working(status)
            case .message(let title, let detail, let page): message(title, detail, page)
            case .idle: EmptyView()
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func offer(_ release: UpdateRelease) -> some View {
        Group {
            Text("MacRAR \(release.version) hazır").font(.headline)
            Text("Kullandığınız sürüm: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"). Güncelleme indirilir, doğrulanır ve MacRAR yeniden açılır. Kayıtlı parolalar, ayarlar ve rar aracı yerinde kalır; macOS parolalar için izni yeniden sorabilir.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            let notes = controller.whatsNew(in: release)
            if !notes.isEmpty {
                ScrollView {
                    Text(notes).font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .frame(height: 170)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
            }
            let direct = controller.canInstallHere && release.archive != nil && release.checksum != nil
            if direct, !model.isIdleForUpdate {
                Label("Süren iş ya da açık pencere bitince güncellenebilir.", systemImage: "hourglass")
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Button("Bu Sürümü Atla") { controller.skip(release) }
                Spacer()
                Button("Sonra") { controller.later() }.keyboardShortcut(.cancelAction)
                if direct {
                    Button("Şimdi Güncelle") { controller.install(release) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.isIdleForUpdate)
                } else {
                    Button("İndirme Sayfasını Aç") { controller.openPage(release.page) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func working(_ status: String) -> some View {
        Group {
            Text("MacRAR güncelleniyor").font(.headline)
            ProgressView().progressViewStyle(.linear)
            Text(status).font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Vazgeç") { controller.close() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    private func message(_ title: String, _ detail: String, _ page: URL?) -> some View {
        Group {
            Text(verbatim: title).font(.headline)
            Text(verbatim: detail).font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if let page {
                    Button("İndirme Sayfasını Aç") { controller.openPage(page) }
                }
                Button("Tamam") { controller.close() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}
