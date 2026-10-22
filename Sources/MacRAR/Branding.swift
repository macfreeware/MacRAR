import SwiftUI
import AppKit
import MacRARCore

/// MacRAR'ın görsel kimliği: renkler uygulama simgesindeki "kitap yığını"ndan gelir.
enum Brand {
    /// Yalnızca ekran görüntüsü üreticisi (test) için: paket dışında çalışırken kenar çubuğunda gösterilecek sürüm metni.
    nonisolated(unsafe) static var versionTextOverride: String?
    static let indigo = Color(red: 0.20, green: 0.17, blue: 0.45)
    static let blue = Color(red: 0.10, green: 0.36, blue: 0.70)
    static let orange = Color(red: 0.96, green: 0.58, blue: 0.16)
    static let teal = Color(red: 0.12, green: 0.66, blue: 0.62)
    static let purple = Color(red: 0.62, green: 0.20, blue: 0.72)
    static let slate = Color(red: 0.22, green: 0.27, blue: 0.36)
    static let slateLight = Color(red: 0.31, green: 0.37, blue: 0.48)

    /// Arşivin içindeyken: marka gradyanı (lacivert → mavi).
    static let archiveGradient = LinearGradient(colors: [indigo, blue], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// Klasör gezerken: sakin gri-mavi; arşiv içi görünümden belirgin biçimde ayrışır.
    static let folderGradient = LinearGradient(colors: [slate, slateLight], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Simgedeki üç kitabın renkleriyle ince "kitap sırtı" şeridi.
struct SpineBar: View {
    var height: CGFloat = 3

    var body: some View {
        HStack(spacing: 0) {
            Brand.orange
            Brand.teal
            Brand.purple
        }
        .frame(height: height)
    }
}

/// Pencerenin üstündeki marka bandı: logo + ad + bulunulan yer (arşiv ya da klasör).
struct BrandHeader: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 46, height: 46)
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)

            VStack(alignment: .leading, spacing: 1) {
                Text("MacRAR")
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Text("ARŞİV YÖNETİCİSİ")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(2.2)
                    .foregroundStyle(.white.opacity(0.7))
            }

            Spacer(minLength: 12)
            contextPill
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(model.isInArchive ? Brand.archiveGradient : Brand.folderGradient)
        .overlay(alignment: .bottom) { SpineBar() }
        .animation(.easeInOut(duration: 0.25), value: model.isInArchive)
    }

    @ViewBuilder private var contextPill: some View {
        HStack(spacing: 10) {
            Image(systemName: model.isInArchive ? "archivebox.fill" : "folder.fill")
                .font(.system(size: 20))
                .foregroundStyle(model.isInArchive ? Brand.orange : .white.opacity(0.85))
            VStack(alignment: .leading, spacing: 1) {
                Text(model.isInArchive ? "ARŞİVİN İÇİNDESİNİZ" : "DOSYA GEZGİNİ")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(.white.opacity(0.65))
                Text(primaryText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1).truncationMode(.middle)
                if let secondary = secondaryText {
                    Text(secondary)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.18), lineWidth: 1))
        .frame(maxWidth: 420, alignment: .trailing)
    }

    private var primaryText: String {
        if let a = model.archiveURL { return a.lastPathComponent }
        let n = model.folderURL.lastPathComponent
        return n.isEmpty ? "Macintosh HD" : n
    }

    private var secondaryText: String? {
        if model.isInArchive {
            guard let s = model.archiveStats else { return nil }
            var t = String(localized: "\(s.files) dosya · \(s.folders) klasör · \(Format.bytes(s.size))")
            if s.packed > 0, s.size > 0 {
                let ratio = Int((Double(s.packed) / Double(s.size) * 100).rounded())
                t += " → \(Format.bytes(s.packed)) (" + String(localized: "%\(ratio)") + ")"
            }
            return t
        }
        let n = model.rows.count
        return n == 0 ? String(localized: "Boş klasör") : String(localized: "\(n) öğe")
    }
}

/// Kenar çubuğunun üstündeki marka bloğu.
struct SidebarBrand: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text("MacRAR").font(.system(size: 15, weight: .heavy, design: .rounded))
                Text(Brand.versionTextOverride ?? VersionInfo().version.map { "v\($0)" } ?? String(localized: "geliştirme"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .overlay(alignment: .bottom) { SpineBar(height: 2).opacity(0.9) }
    }
}
