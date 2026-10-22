import Foundation

/// RAR araçlarının nasıl edinileceğine dair kullanıcıya gösterilen yönlendirmeler (tek doğruluk kaynağı).
/// `bundle` alan biçimler, uygulamanın açılış dilinden farklı bir dilde göstermek içindir (Kurulum Yardımcısı'nda anında dil değişimi).
///
/// Not: Homebrew'daki `rar` paketi (cask) 2026-09-01'de macOS Gatekeeper denetiminden geçmediği için devre dışı bırakıldı
/// ve `unrar` formülü Homebrew'dan kaldırıldı; bu yüzden `brew install --cask rar` artık çalışmaz.
public enum ToolGuidance {
    public static let rarlabDownloadURL = URL(string: "https://www.rarlab.com/download.htm")!
    public static let rarlabDownloadText = "rarlab.com/download.htm"

    /// Resmi paketi nasıl kuracağı (kısa).
    public static var rarInstallSteps: String { rarInstallSteps(bundle: .main) }
    public static func rarInstallSteps(bundle: Bundle) -> String {
        String(localized: "RARLAB’ın resmi “RAR for macOS” (komut satırı) paketini \(rarlabDownloadText) adresinden indirin; açılan klasördeki rar ve unrar dosyalarını /usr/local/bin içine kopyalayın. macOS ilk çalıştırmada engellerse: Sistem Ayarları ▸ Gizlilik ve Güvenlik ▸ “Yine de Aç”.", bundle: bundle)
    }

    /// Kurulum Yardımcısı'ndaki otomatik kurulumun açıklaması.
    public static var rarAutoInstallNote: String { rarAutoInstallNote(bundle: .main) }
    public static func rarAutoInstallNote(bundle: Bundle) -> String {
        String(localized: "Düğme, RAR’ın güncel macOS sürümünü doğrudan \(rarlabDownloadText) adresinden (https) indirir ve yönetici parolası istemeden MacRAR’ın klasörüne kurar; sisteminizdeki başka bir yere dokunmaz.", bundle: bundle)
    }

    /// Lisans özeti (RARLAB lisans metnine göre).
    public static var rarLicenseNote: String { rarLicenseNote(bundle: .main) }
    public static func rarLicenseNote(bundle: Bundle) -> String {
        String(localized: "rar deneme sürümü en çok 40 gün ücretsizdir, sonrasında RARLAB lisansı gerekir; unrar ücretsizdir ve MacRAR ile birlikte gelir. MacRAR rar’ı paketlemez.", bundle: bundle)
    }

    /// Tek satırlık özet (hata/uyarı metinleri için).
    public static var oneLiner: String { oneLiner(bundle: .main) }
    public static func oneLiner(bundle: Bundle) -> String {
        String(localized: "RAR oluşturmak için Yardım ▸ Kurulum Yardımcısı’ndan rar’ı RARLAB’dan indirip kurun ya da \(rarlabDownloadText) adresinden elle kurun.", bundle: bundle)
    }
}
