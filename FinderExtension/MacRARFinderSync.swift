import Cocoa
import FinderSync

/// Finder'ın ana sağ tık menüsüne MacRAR girdilerini ekler (Windows'taki gibi).
/// Eklenti korumalı (sandbox) çalışır: dosyalara dokunmaz, yalnızca seçilen yolları uygulamaya iletir.
/// Menü içeriği `FinderIntegration` (MacRARCore ile ortak kaynak) tarafından seçime göre belirlenir.
final class MacRARFinderSync: FIFinderSync {
    /// Menü girdilerinin yanında gösterilen küçük uygulama simgesi.
    private static let icon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 16, height: 16)
        return image
    }()

    override init() {
        super.init()
        // Tüm klasörlerde menü göster
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems,
              let urls = FIFinderSyncController.default().selectedItemURLs(), !urls.isEmpty else { return nil }
        let menu = NSMenu(title: "")
        // rar kurulu değilse RAR sıkıştırma girdileri gösterilmez (durumu uygulama yazar; bkz. FinderState).
        let canRAR = FinderState.shouldOfferRARCompression()
        // Menü, uygulamada seçilen dilde (Ayarlar ▸ Genel ▸ Dil); sistem dili seçiliyse eklentinin kendi dili.
        let bundle = FinderState.readLanguage().flatMap { Bundle.main.path(forResource: $0, ofType: "lproj") }
            .flatMap(Bundle.init(path:)) ?? .main
        for item in FinderIntegration.menuItems(for: urls, canCompressRAR: canRAR, bundle: bundle) {
            let mi = NSMenuItem(title: item.title, action: #selector(run(_:)), keyEquivalent: "")
            mi.target = self
            // Finder menü öğesini eklentiye geri gönderirken `representedObject` alanını TAŞIMIYOR;
            // yalnızca `tag` ve başlık ulaşır. Bu yüzden eylem, `allCases` içindeki sırasıyla iletilir.
            mi.tag = FinderAction.allCases.firstIndex(of: item.action) ?? -1
            mi.image = Self.icon
            menu.addItem(mi)
        }
        return menu
    }

    @objc private func run(_ sender: NSMenuItem) {
        let actions = FinderAction.allCases
        guard actions.indices.contains(sender.tag) else {
            NSLog("MacRARFinder: geçersiz eylem etiketi \(sender.tag)")
            return
        }
        guard let urls = FIFinderSyncController.default().selectedItemURLs(), !urls.isEmpty else {
            NSLog("MacRARFinder: seçili öğe alınamadı")
            return
        }
        guard let token = FinderToken.read() else {
            NSLog("MacRARFinder: gizli anahtar okunamadı (MacRAR henüz açılmadı mı?)")
            return
        }
        guard let url = FinderIntegration.commandURL(action: actions[sender.tag], paths: urls.map(\.path), token: token) else {
            NSLog("MacRARFinder: komut URL'si üretilemedi")
            return
        }
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { NSLog("MacRARFinder: uygulama açılamadı: \(error.localizedDescription)") }
        }
    }
}
