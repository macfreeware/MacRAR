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

/// Bayraklı dil seçici ve (dil değiştiyse) seçilen dilde "yeniden başlat" satırı. Ayarlar ▸ Genel ve Kurulum Yardımcısı ortak kullanır.
struct LanguageChooser: View {
    @Binding var language: AppLanguage

    var body: some View {
        Picker("Dil", selection: $language) {
            ForEach(AppLanguage.allCases) { (Text(verbatim: "\($0.flag)  ") + Text($0.title)).tag($0) }
        }
        .onChange(of: language) { _, new in
            new.save()
            AppModel.shared.publishFinderState()   // Finder menüsü de seçilen dili kullansın
        }
        if language != AppLanguage.atLaunch {
            // Seçilen dilde: okuyamadığı bir dilden çıkan kullanıcı da düğmeyi bulabilsin.
            let next = language.bundle
            HStack {
                Text(String(localized: "Yeni dil MacRAR yeniden açıldığında geçerli olur.", bundle: next))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "Şimdi Yeniden Başlat", bundle: next)) { Self.relaunch() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
