import SwiftUI
import AppKit
import MacRARCore

/// Kayıtlı parolalar (arayüz modeli). Anahtar Zinciri'ne **yalnızca gerektiğinde** dokunur:
/// uygulama açılırken değil, parola sorulduğunda ya da yönetici açıldığında yüklenir.
@MainActor
@Observable
final class PasswordVault {
    private(set) var items: [SavedPassword] = []
    private(set) var isLoaded = false
    var errorMessage: String?
    @ObservationIgnored private let store: PasswordStoring

    init(store: PasswordStoring = KeychainPasswordStore()) {
        self.store = store
    }

    /// Listeyi (bir kez) yükler. Anahtar Zinciri izin penceresi çıkabileceğinden arka planda çalışır.
    func loadIfNeeded() async {
        guard !isLoaded else { return }
        let store = self.store
        do {
            items = try await Task.detached { try store.load() }.value
            isLoaded = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Son kullanıma göre sıralı (yeni önce), kullanılmamışlar ada göre.
    var sorted: [SavedPassword] {
        items.sorted {
            switch ($0.lastUsed, $1.lastUsed) {
            case let (a?, b?): return a > b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    @discardableResult
    func add(name: String, password: String, hint: String? = nil) async -> Bool {
        await loadIfNeeded()
        guard isLoaded, !password.isEmpty else { return false }
        // Aynı parola zaten kayıtlıysa yenisini ekleme; yalnızca son kullanımı güncelle.
        if let i = items.firstIndex(where: { $0.password == password }) {
            items[i].lastUsed = Date()
            return await persist()
        }
        let n = name.trimmingCharacters(in: .whitespaces)
        let h = hint?.trimmingCharacters(in: .whitespacesAndNewlines)
        items.append(SavedPassword(name: n.isEmpty ? String(localized: "Parola") : n, password: password, lastUsed: Date(),
                                   hint: (h?.isEmpty ?? true) ? nil : h))
        return await persist()
    }

    @discardableResult
    func update(_ item: SavedPassword) async -> Bool {
        guard isLoaded, let i = items.firstIndex(where: { $0.id == item.id }) else { return false }
        items[i] = item
        return await persist()
    }

    @discardableResult
    func remove(_ id: UUID) async -> Bool {
        guard isLoaded else { return false }
        items.removeAll { $0.id == id }
        return await persist()
    }

    /// Doğrulanmış (arşivi açan) bir parolanın son kullanım zamanını günceller.
    /// Liste henüz yüklenmediyse Anahtar Zinciri'ne dokunmaz.
    func touch(password: String) async {
        guard isLoaded, let i = items.firstIndex(where: { $0.password == password }) else { return }
        items[i].lastUsed = Date()
        _ = await persist()
    }

    private func persist() async -> Bool {
        let snapshot = items
        let store = self.store
        do {
            try await Task.detached { try store.save(snapshot) }.value
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

// MARK: - Parola seçici (Parola ve Ekle pencerelerinde ortak)

/// "Kayıtlı parolalar" açılır menüsü. Seçilen parola `onPick` ile verilir.
struct SavedPasswordMenu: View {
    let vault: PasswordVault
    var title: LocalizedStringKey = "Kayıtlı parolalar"
    let onPick: (SavedPassword) -> Void

    var body: some View {
        Menu {
            if vault.sorted.isEmpty {
                Text(vault.isLoaded ? "Kayıtlı parola yok" : "Yükleniyor…")
            } else {
                ForEach(vault.sorted) { item in
                    Button(item.hint.map { "\(item.name) — \($0)" } ?? item.name) { onPick(item) }
                }
            }
        } label: {
            Label(title, systemImage: "key.horizontal.fill")
        }
        .menuIndicator(.visible)
        .fixedSize()
        .task { await vault.loadIfNeeded() }
        .help(vault.errorMessage ?? String(localized: "Parola yöneticisinde kayıtlı parolalardan birini seç"))
    }
}

// MARK: - Parola yöneticisi penceresi

struct PasswordManagerSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    private struct Draft: Equatable {
        var id: UUID?
        var name = ""
        var password = ""
        var hint = ""
    }

    @State private var selection: UUID?
    @State private var draft: Draft?
    @State private var revealed = Set<UUID>()
    @State private var showDraftPassword = false

    private var vault: PasswordVault { model.vault }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "key.horizontal.fill").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading) {
                    Text("Parola yöneticisi").font(.headline)
                    Text("Parolalar macOS Anahtar Zinciri’nde saklanır.").font(.callout).foregroundStyle(.secondary)
                }
            }

            if let err = vault.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            }

            List(selection: $selection) {
                ForEach(vault.sorted) { item in row(item).tag(item.id) }
            }
            .frame(height: 220)
            .overlay {
                if vault.sorted.isEmpty {
                    ContentUnavailableView("Kayıtlı parola yok", systemImage: "key",
                                           description: Text(vault.isLoaded ? "“Ekle…” ile ilk parolanızı kaydedin." : "Yükleniyor…"))
                }
            }

            if draft != nil { editor }

            HStack {
                Button("Ekle…") { draft = Draft(); showDraftPassword = false }
                Button("Düzenle…") { beginEdit() }.disabled(selected == nil)
                Button("Parolayı Kopyala") { copy() }.disabled(selected == nil)
                Button("Sil", role: .destructive) { delete() }.disabled(selected == nil)
                Spacer()
                Button("Kapat") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await vault.loadIfNeeded() }
    }

    private var selected: SavedPassword? { vault.items.first { $0.id == selection } }

    private func row(_ item: SavedPassword) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                if let hint = item.hint, !hint.isEmpty {
                    Text(hint).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(item.lastUsed.map { String(localized: "Son kullanım: \(Format.date($0))") } ?? String(localized: "Hiç kullanılmadı"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(revealed.contains(item.id) ? item.password : String(repeating: "•", count: min(max(item.password.count, 6), 14)))
                .font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button {
                if revealed.contains(item.id) { revealed.remove(item.id) } else { revealed.insert(item.id) }
            } label: { Image(systemName: revealed.contains(item.id) ? "eye.slash" : "eye") }
            .buttonStyle(.borderless).help("Parolayı göster/gizle")
        }
    }

    @ViewBuilder private var editor: some View {
        GroupBox(draft?.id == nil ? "Yeni parola" : "Parolayı düzenle") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Ad (örn. Muhasebe arşivleri)", text: Binding(get: { draft?.name ?? "" }, set: { draft?.name = $0 }))
                TextField("İpucu / not (isteğe bağlı; parolanın kendisini yazmayın)",
                          text: Binding(get: { draft?.hint ?? "" }, set: { draft?.hint = $0 }))
                HStack {
                    Group {
                        if showDraftPassword {
                            TextField("Parola", text: Binding(get: { draft?.password ?? "" }, set: { draft?.password = $0 }))
                        } else {
                            SecureField("Parola", text: Binding(get: { draft?.password ?? "" }, set: { draft?.password = $0 }))
                        }
                    }
                    Toggle("Göster", isOn: $showDraftPassword).toggleStyle(.checkbox)
                }
                HStack {
                    Spacer()
                    Button("Vazgeç") { draft = nil }
                    Button("Kaydet") { commitDraft() }
                        .keyboardShortcut(.defaultAction)
                        .disabled((draft?.password ?? "").isEmpty)
                }
            }
            .padding(6)
        }
    }

    private func beginEdit() {
        guard let s = selected else { return }
        draft = Draft(id: s.id, name: s.name, password: s.password, hint: s.hint ?? "")
        showDraftPassword = false
    }

    private func commitDraft() {
        guard let d = draft else { return }
        draft = nil
        Task {
            if let id = d.id, var item = vault.items.first(where: { $0.id == id }) {
                item.name = d.name.isEmpty ? item.name : d.name
                item.password = d.password
                let h = d.hint.trimmingCharacters(in: .whitespacesAndNewlines)
                item.hint = h.isEmpty ? nil : h
                await vault.update(item)
            } else {
                await vault.add(name: d.name, password: d.password, hint: d.hint)
            }
        }
    }

    private func delete() {
        guard let s = selected else { return }
        selection = nil
        Task { await vault.remove(s.id) }
    }

    /// Panoya kopyalar ve 30 sn sonra (hâlâ aynıysa) temizler; "gizli" işaretiyle pano geçmişi araçlarından saklanır.
    private func copy() {
        guard let s = selected else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s.password, forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let count = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
        }
    }
}
