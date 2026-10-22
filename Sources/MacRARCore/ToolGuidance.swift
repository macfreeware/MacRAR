import Foundation

/// RAR araçlarının nasıl edinileceğine dair kullanıcıya gösterilen yönlendirmeler (tek doğruluk kaynağı).
///
/// Not: Homebrew'daki `rar` paketi (cask) 2026-09-01'de macOS Gatekeeper denetiminden geçmediği için devre dışı bırakıldı
/// ve `unrar` formülü Homebrew'dan kaldırıldı; bu yüzden `brew install --cask rar` artık çalışmaz.
public enum ToolGuidance {
    public static let rarlabDownloadURL = URL(string: "https://www.rarlab.com/download.htm")!
    public static let rarlabDownloadText = "rarlab.com/download.htm"

    /// Resmi paketi nasıl kuracağı (kısa).
    public static let rarInstallSteps =
        String(localized: "RARLAB’ın resmi “RAR for macOS” (komut satırı) paketini \(rarlabDownloadText) adresinden indirin; açılan klasördeki rar ve unrar dosyalarını /usr/local/bin içine kopyalayın. macOS ilk çalıştırmada engellerse: Sistem Ayarları ▸ Gizlilik ve Güvenlik ▸ “Yine de Aç”.")

    /// Kurulum Yardımcısı'ndaki otomatik kurulumun açıklaması.
    public static let rarAutoInstallNote =
        String(localized: "Düğme, RAR’ın güncel macOS sürümünü doğrudan \(rarlabDownloadText) adresinden (https) indirir ve yönetici parolası istemeden MacRAR’ın klasörüne kurar; sisteminizdeki başka bir yere dokunmaz.")

    /// Lisans özeti (RARLAB lisans metnine göre).
    public static let rarLicenseNote =
        String(localized: "rar deneme sürümü en çok 40 gün ücretsizdir, sonrasında RARLAB lisansı gerekir; unrar ücretsizdir ve MacRAR ile birlikte gelir. MacRAR rar’ı paketlemez.")

    /// Tek satırlık özet (hata/uyarı metinleri için).
    public static let oneLiner =
        String(localized: "RAR oluşturmak için Yardım ▸ Kurulum Yardımcısı’ndan rar’ı RARLAB’dan indirip kurun ya da \(rarlabDownloadText) adresinden elle kurun.")
}
