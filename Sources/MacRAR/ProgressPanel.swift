import SwiftUI
import AppKit
import MacRARCore

/// Finder sağ tık menüsünden başlatılan sıkıştırma/çıkarma işlemlerinde, ana pencere AÇILMADAN gösterilen küçük ilerleme paneli.
/// Parola, diyalog veya uyarı gerekirse ana pencere açılır ve panel kapanır (bkz. `AppModel.watchUI`).
@MainActor
final class ProgressPanel: NSObject, NSWindowDelegate {
    static let shared = ProgressPanel()
    private var panel: NSPanel?
    private weak var model: AppModel?

    func show(model: AppModel) {
        self.model = model
        if let panel, panel.isVisible { return }
        let hosting = NSHostingController(rootView: ProgressPanelView(model: model))
        hosting.sizingOptions = [.preferredContentSize]   // içerik büyüyünce (ayrıntılar açılınca) pencere de uyar
        let p = NSPanel(contentViewController: hosting)
        p.styleMask = [.titled, .closable, .fullSizeContentView]
        p.title = "MacRAR"                       // Mission Control/pencere listesi için; başlık metni bantta zaten var
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
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
        guard let panel, panel.isVisible else { return }
        panel.delegate = nil          // kendiliğinden kapanışta iptal tetiklenmesin
        panel.orderOut(nil)
        self.panel = nil
    }

    /// Kullanıcı paneli kapatma düğmesiyle kapatırsa süren işlem iptal edilir.
    func windowWillClose(_ notification: Notification) {
        panel = nil
        model?.dismissOperation()
    }
}

private struct ProgressPanelView: View {
    let model: AppModel

    static func badge(for phase: OperationState.Phase?) -> LocalizedStringKey {
        switch phase {
        case .none, .running?: return "İŞLEM SÜRÜYOR"
        case .finished?: return "TAMAMLANDI"
        case .failed?: return "HATA"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            CompactBrandBar(badge: Self.badge(for: model.operation?.phase), leadingInset: 78)
            Group {
                if let op = model.operation {
                    OperationCard(op: op) { model.dismissOperation() }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 2)
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .ignoresSafeArea()
    }
}

/// Ana penceredeki marka bandının küçük hâli: Finder'dan başlatılan işlemin/pencerenin MacRAR'a ait olduğunu gösterir.
/// `leadingInset`: başlık çubuğu saydam pencerelerde (ilerleme paneli) kapatma düğmeleri bandın üstünde durur; sola boşluk bırakılır.
struct CompactBrandBar: View {
    var badge: LocalizedStringKey
    var leadingInset: CGFloat = 14

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: 30, height: 30)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            VStack(alignment: .leading, spacing: 0) {
                Text("MacRAR")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Text("ARŞİV YÖNETİCİSİ")
                    .font(.system(size: 7.5, weight: .semibold)).tracking(1.8)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 8)
            Text(badge)
                .font(.system(size: 9, weight: .bold)).tracking(1.2)
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(.white.opacity(0.16)))
        }
        .padding(.leading, leadingInset).padding(.trailing, 14)
        .frame(height: 44)
        .background(Brand.archiveGradient)
        .overlay(alignment: .bottom) { SpineBar(height: 2) }
    }
}
