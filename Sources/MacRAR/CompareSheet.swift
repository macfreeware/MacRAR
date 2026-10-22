import SwiftUI
import MacRARCore

/// İki arşivin içeriğini karşılaştıran pencere (yalnızca girdi listelerine bakar; diske çıkarma yoktur).
struct CompareSheet: View {
    let request: CompareRequest
    @Environment(\.dismiss) private var dismiss

    private enum Filter: String, CaseIterable, Identifiable {
        case differences = "Farklar", all = "Tümü"
        var id: String { rawValue }
        var title: LocalizedStringKey { self == .differences ? "Farklar" : "Tümü" }
    }

    @State private var filter: Filter = .differences
    @State private var query = ""

    private var result: ArchiveComparison.Result { request.result }

    private var shown: [ArchiveComparison.Item] {
        result.items.filter { item in
            (filter == .all || item.isDifference || item.status == .sameSizeUnverified)
                && (query.isEmpty || item.path.localizedStandardContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.left.arrow.right.square.fill").font(.title).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Arşivleri karşılaştır").font(.headline)
                    Text("A: \(request.firstName)").font(.callout).lineLimit(1).truncationMode(.middle)
                    Text("B: \(request.secondName)").font(.callout).lineLimit(1).truncationMode(.middle)
                }
            }

            summary

            HStack {
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                TextField("Ada göre süz", text: $query).textFieldStyle(.roundedBorder)
            }

            List(shown) { item in row(item) }
                .frame(minHeight: 260)
                .overlay {
                    if shown.isEmpty {
                        ContentUnavailableView(result.items.isEmpty ? "Arşivler boş" : "Gösterilecek satır yok",
                                               systemImage: result.differenceCount == 0 ? "checkmark.circle" : "magnifyingglass")
                    }
                }

            HStack {
                Button("Listeyi Kopyala") { copyReport() }
                Spacer()
                Button("Kapat") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
    }

    @ViewBuilder private var summary: some View {
        if result.isIdentical {
            Label("İki arşivin içeriği aynı (\(result.count(.identical)) dosya).", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            HStack(spacing: 14) {
                chip(.onlyInFirst); chip(.onlyInSecond); chip(.differentContent); chip(.differentSize)
                chip(.typeMismatch); chip(.sameSizeUnverified); chip(.identical)
            }
            .font(.callout)
            if result.count(.sameSizeUnverified) > 0 {
                Text("“Boyutu aynı” satırlarda bir tarafın CRC değeri okunamadığından içeriğin aynı olduğu doğrulanamadı.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func chip(_ status: ArchiveComparison.Status) -> some View {
        let n = result.count(status)
        if n > 0 {
            Label("\(n) \(Self.shortLabel(status))", systemImage: Self.symbol(status)).foregroundStyle(Self.color(status))
        }
    }

    private func row(_ item: ArchiveComparison.Item) -> some View {
        HStack(spacing: 8) {
            Image(systemName: Self.symbol(item.status)).foregroundStyle(Self.color(item.status)).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.path).lineLimit(1).truncationMode(.middle)
                Text(Self.label(item.status)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(item.first.map { Format.bytes($0.size) } ?? "—").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(item.second.map { Format.bytes($0.size) } ?? "—").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
    }

    private func copyReport() {
        var lines = ["A: \(request.firstName)", "B: \(request.secondName)", ""]
        for item in result.items where item.isDifference || filter == .all {
            lines.append("\(Self.label(item.status))\t\(item.path)")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    static func label(_ s: ArchiveComparison.Status) -> String {
        switch s {
        case .onlyInFirst: return String(localized: "Yalnızca A’da var")
        case .onlyInSecond: return String(localized: "Yalnızca B’de var")
        case .differentContent: return String(localized: "İçerik farklı (CRC)")
        case .differentSize: return String(localized: "Boyut farklı")
        case .identical: return String(localized: "Aynı")
        case .sameSizeUnverified: return String(localized: "Boyutu aynı (içerik doğrulanamadı)")
        case .typeMismatch: return String(localized: "Biri dosya, öteki klasör")
        }
    }

    static func shortLabel(_ s: ArchiveComparison.Status) -> String {
        switch s {
        case .onlyInFirst: return String(localized: "yalnız A")
        case .onlyInSecond: return String(localized: "yalnız B")
        case .differentContent: return String(localized: "içerik farklı")
        case .differentSize: return String(localized: "boyut farklı")
        case .identical: return String(localized: "aynı")
        case .sameSizeUnverified: return String(localized: "doğrulanamadı")
        case .typeMismatch: return String(localized: "tür farklı")
        }
    }

    static func symbol(_ s: ArchiveComparison.Status) -> String {
        switch s {
        case .onlyInFirst: return "arrow.left.circle.fill"
        case .onlyInSecond: return "arrow.right.circle.fill"
        case .differentContent, .differentSize: return "exclamationmark.circle.fill"
        case .identical: return "checkmark.circle.fill"
        case .sameSizeUnverified: return "questionmark.circle.fill"
        case .typeMismatch: return "xmark.circle.fill"
        }
    }

    static func color(_ s: ArchiveComparison.Status) -> Color {
        switch s {
        case .onlyInFirst: return .blue
        case .onlyInSecond: return .purple
        case .differentContent, .differentSize, .typeMismatch: return .orange
        case .identical: return .green
        case .sameSizeUnverified: return .secondary
        }
    }
}
