import SwiftUI

/// Arayüz dili (Ayarlar ▸ Genel ▸ Dil). Seçim `AppleLanguages` ile bir sonraki açılışta geçerli olur.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, tr, en
    var id: String { rawValue }

    static let defaultsKey = "language"

    var title: LocalizedStringKey {
        switch self {
        case .system: return "Sistem dili"
        case .tr: return "Türkçe"
        case .en: return "English"
        }
    }

    var flag: String {
        switch self {
        case .system: return "🌐"
        case .tr: return "🇹🇷"
        case .en: return "🇬🇧"
        }
    }

    /// Bu seçimle açıldığında MacRAR'ın kullanacağı çeviri: yeniden başlat notu geçilen dilde yazılsın diye.
    var bundle: Bundle {
        var preferences = [rawValue]
        if self == .system {
            preferences = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String] ?? []
        }
        let code = Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: preferences).first
        return code.flatMap { Bundle.main.path(forResource: $0, ofType: "lproj") }.flatMap(Bundle.init(path:)) ?? .main
    }

    /// Seçimi, Bundle'ın bir sonraki açılışta okuyacağı yere yazar.
    func save() {
        let d = UserDefaults.standard
        d.set(rawValue, forKey: Self.defaultsKey)
        if self == .system { d.removeObject(forKey: "AppleLanguages") } else { d.set([rawValue], forKey: "AppleLanguages") }
    }

    static var saved: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system
    }

    /// Çalışan uygulamada geçerli olan seçim (açılışta bir kez okunur).
    nonisolated(unsafe) static var atLaunch = AppLanguage.system
}
