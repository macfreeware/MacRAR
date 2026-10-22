import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Arşiv türleri için "varsayılan uygulama" yönetimi (Ayarlar'daki bölüm).
/// Ayarlamayı macOS'un resmi API'si yapar ve kullanıcıdan kendi onay penceresiyle onay ister.
enum DefaultApps {
    struct Kind: Identifiable, Equatable {
        let id: String        // UTI
        let title: String
        let ext: String
        /// MacRAR'ın öncelikli işi (RAR/7Z) mi; öbürleri sistemin kendi arşiv yardımcısının yerine geçmek ister.
        let primary: Bool

        var type: UTType? { UTType(id) ?? UTType(filenameExtension: ext) }
    }

    static let kinds: [Kind] = [
        Kind(id: "com.rarlab.rar-archive", title: String(localized: "RAR arşivleri"), ext: "rar", primary: true),
        Kind(id: "org.7-zip.7-zip-archive", title: String(localized: "7-Zip arşivleri"), ext: "7z", primary: true),
        Kind(id: "public.zip-archive", title: String(localized: "ZIP arşivleri"), ext: "zip", primary: false),
        Kind(id: "org.gnu.gnu-zip-tar-archive", title: String(localized: "TAR.GZ arşivleri"), ext: "tgz", primary: false),
    ]

    struct Current: Equatable {
        var name: String?
        var bundleID: String?
        var isMacRAR: Bool
    }

    /// Bu tür için şu anki varsayılan uygulama (yoksa nil adlı).
    static func current(for kind: Kind, thisBundleID: String? = Bundle.main.bundleIdentifier) -> Current {
        guard let type = kind.type, let url = NSWorkspace.shared.urlForApplication(toOpen: type) else {
            return Current(name: nil, bundleID: nil, isMacRAR: false)
        }
        let bundle = Bundle(url: url)
        let id = bundle?.bundleIdentifier
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return Current(name: name, bundleID: id, isMacRAR: id != nil && id == thisBundleID)
    }

    /// Uygulama /Applications (veya ~/Applications) içinde mi? Başka yerdeki kopya varsayılan yapılmamalı:
    /// geliştirme klasöründeki derleme silinince varsayılan uygulama "kaybolur".
    static func isInstalledInApplications(_ url: URL = Bundle.main.bundleURL) -> Bool {
        let p = url.resolvingSymlinksInPath().path
        return p.hasPrefix("/Applications/") || p.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// macOS onay penceresini gösterir; kullanıcı reddederse hata fırlatır.
    @MainActor
    static func makeDefault(_ kind: Kind) async throws {
        guard let type = kind.type else { throw CocoaError(.fileNoSuchFile) }
        try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type)
    }
}

/// Ayarlar → "Varsayılan uygulama" bölümü.
struct DefaultAppSection: View {
    @State private var currents: [String: DefaultApps.Current] = [:]
    @State private var message: String?
    @State private var busy = false

    private var installed: Bool { DefaultApps.isInstalledInApplications() }

    var body: some View {
        Section {
            ForEach(DefaultApps.kinds) { kind in
                let cur = currents[kind.id]
                HStack(spacing: 10) {
                    Image(systemName: cur?.isMacRAR == true ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(cur?.isMacRAR == true ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(kind.title) (.\(kind.ext))")
                        Text(cur?.isMacRAR == true ? String(localized: "Varsayılan: MacRAR")
                             : String(localized: "Varsayılan: \(cur?.name ?? String(localized: "belirlenmemiş"))"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if cur?.isMacRAR != true {
                        Button("MacRAR'ı varsayılan yap") { Task { await make(kind) } }
                            .disabled(busy || !installed)
                    }
                }
            }
            HStack {
                Button("RAR ve 7Z'yi MacRAR yap") { Task { await makeAllPrimary() } }
                    .disabled(busy || !installed || DefaultApps.kinds.filter(\.primary).allSatisfy { currents[$0.id]?.isMacRAR == true })
                Button("Yenile") { refresh() }
            }
            if !installed {
                Label("Varsayılan yapmak için MacRAR'ın Uygulamalar klasöründe kurulu olması gerekir (şu an: \(Bundle.main.bundleURL.deletingLastPathComponent().path)).",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Varsayılan uygulama")
        } footer: {
            Text("Arşiv dosyasına çift tıklayınca MacRAR açılır. macOS değişikliği onaylamanızı isteyecektir. ZIP ve TAR.GZ için macOS'un kendi Arşiv Yardımcısı'nın yerini alırsınız; istemiyorsanız dokunmayın.")
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        var map: [String: DefaultApps.Current] = [:]
        for k in DefaultApps.kinds { map[k.id] = DefaultApps.current(for: k) }
        currents = map
    }

    private func make(_ kind: DefaultApps.Kind) async {
        busy = true; defer { busy = false }
        do {
            try await DefaultApps.makeDefault(kind)
            message = String(localized: "“.\(kind.ext)” için MacRAR varsayılan yapıldı.")
        } catch {
            message = String(localized: "Değiştirilemedi: \(error.localizedDescription)")
        }
        refresh()
    }

    private func makeAllPrimary() async {
        busy = true; defer { busy = false }
        var changed: [String] = []
        for kind in DefaultApps.kinds where kind.primary && currents[kind.id]?.isMacRAR != true {
            do { try await DefaultApps.makeDefault(kind); changed.append(".\(kind.ext)") }
            catch { message = String(localized: "Değiştirilemedi (.\(kind.ext)): \(error.localizedDescription)"); refresh(); return }
        }
        message = changed.isEmpty ? nil : String(localized: "MacRAR varsayılan yapıldı: \(changed.joined(separator: ", "))")
        refresh()
    }
}
