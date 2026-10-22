import SwiftUI
import AppKit

private struct PanelCloseKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }

extension EnvironmentValues {
    /// Sayfa (sheet) yerine bağımsız pencerede gösterilen diyalogların kapatma eylemi; sayfada nil (sistem `dismiss` kullanılır).
    var panelClose: (() -> Void)? {
        get { self[PanelCloseKey.self] }
        set { self[PanelCloseKey.self] = newValue }
    }
}

/// Finder sağ tık menüsünden gelen "Arşive Ekle…" / "Dosyaları Çıkar…" diyaloglarını, ana pencere AÇILMADAN, taşınabilir
/// bağımsız bir pencerede gösterir (macOS sayfaları — sheet — taşınamaz). Pencerenin üstünde marka bandı bulunur.
@MainActor
final class SheetPanel: NSObject, NSWindowDelegate {
    static let shared = SheetPanel()
    /// Testlerde gerçek pencere açılmasın diye kapatılabilir.
    static var isEnabled = true
    private var panel: NSPanel?
    private weak var model: AppModel?

    func show(model: AppModel) {
        self.model = model
        guard Self.isEnabled else { return }
        if let panel, panel.isVisible { return }
        let hosting = NSHostingController(rootView: PanelSheetContent(model: model) { [weak self] in self?.userClosed() })
        hosting.sizingOptions = [.preferredContentSize]
        let p = NSPanel(contentViewController: hosting)
        p.styleMask = [.titled, .closable, .fullSizeContentView]
        p.title = "MacRAR"
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true     // başlık çubuğundan ve boş alanlardan sürüklenebilir
        p.level = .floating
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

    /// İptal/Kapat düğmesi ya da kapatma düğmesi: diyalog bırakılır.
    private func userClosed() {
        let m = model
        hide()
        m?.sheet = nil
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        model?.sheet = nil
    }
}

private struct PanelSheetContent: View {
    let model: AppModel
    let close: () -> Void

    var body: some View {
        Group {
            switch model.sheet {
            case .add(let request)?: AddSheet(model: model, request: request)
            case .extract(let request)?: ExtractSheet(model: model, request: request)
            default: EmptyView()
            }
        }
        .environment(\.panelClose, close)
        .ignoresSafeArea()
    }
}
