import SwiftUI
import AppKit
import MacRARCore

// MARK: - Çıkarma penceresi

struct ExtractSheet: View {
    let model: AppModel
    let request: ExtractRequest
    @Environment(\.dismiss) private var systemDismiss
    @Environment(\.panelClose) private var panelClose

    private func dismiss() { if let panelClose { panelClose() } else { systemDismiss() } }

    @AppStorage("extractOverwrite") private var overwriteRaw = OverwriteMode.overwrite.rawValue
    @AppStorage("extractSubfolder") private var createSubfolder = true
    @AppStorage("extractReveal") private var reveal = true
    @AppStorage("recentDestinations") private var recentRaw = ""

    @State private var destination: String
    @State private var keepPaths = true
    @State private var keepBroken = false
    @State private var useSelection: Bool

    init(model: AppModel, request: ExtractRequest) {
        self.model = model
        self.request = request
        _destination = State(initialValue: request.defaultDestination.path)
        _useSelection = State(initialValue: !request.selectedRows.isEmpty)
    }

    private var recents: [String] { recentRaw.split(separator: "\n").map(String.init) }

    /// Seçili arşivlerin hepsi RAR mı? (RAR'a özgü seçenekler yalnızca o zaman anlamlı)
    private var allRAR: Bool {
        request.archives.allSatisfy { ArchiveService.engine(for: $0) == .rar }
    }

    private var title: String {
        request.archives.count == 1 ? request.archives[0].lastPathComponent : String(localized: "\(request.archives.count) arşiv")
    }

    var body: some View {
        VStack(spacing: 0) {
            CompactBrandBar(badge: "ARŞİVİ ÇIKAR", leadingInset: panelClose != nil ? 78 : 14)
            Form {
                Section("Hedef") {
                    HStack {
                        TextField("Hedef klasör", text: $destination)
                        Button("Seç…") { choose() }
                        if !recents.isEmpty {
                            Menu {
                                ForEach(recents, id: \.self) { r in Button(r) { destination = r } }
                            } label: { Image(systemName: "clock.arrow.circlepath") }
                            .menuIndicator(.hidden).fixedSize().help("Son kullanılan hedefler")
                        }
                    }
                    Toggle("Arşiv adıyla alt klasör oluştur (\(AppModel.baseName(of: request.archives[0])))", isOn: $createSubfolder)
                }

                if !request.selectedRows.isEmpty {
                    Section("Kapsam") {
                        Picker("Çıkarılacak", selection: $useSelection) {
                            Text("Seçili \(request.selectedRows.count) öğe").tag(true)
                            Text("Arşivin tamamı").tag(false)
                        }
                        .pickerStyle(.radioGroup)
                    }
                }

                Section("Seçenekler") {
                    Picker("Var olan dosyalar", selection: $overwriteRaw) {
                        Text("Üzerine yaz").tag(OverwriteMode.overwrite.rawValue)
                        Text("Atla").tag(OverwriteMode.skip.rawValue)
                        if allRAR { Text("Otomatik yeniden adlandır").tag(OverwriteMode.rename.rawValue) }
                    }
                    // Yolsuz çıkarma ve "bozukları sakla" yalnızca RARLAB araçlarında var; unar bunları desteklemiyor.
                    if allRAR && model.tools.rarReader != nil {
                        Picker("Klasör yapısı", selection: $keepPaths) {
                            Text("Tam yollarla çıkar").tag(true)
                            Text("Yol olmadan (hepsini tek klasöre)").tag(false)
                        }
                        Toggle("Bozuk dosyaları da sakla", isOn: $keepBroken)
                    }
                    Toggle("Bitince Finder’da göster", isOn: $reveal)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text(title).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("İptal") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Çıkar") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(destination.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 520, height: request.selectedRows.isEmpty ? 504 : 584)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: (destination as NSString).expandingTildeInPath)
        panel.prompt = String(localized: "Seç")
        if panel.runModal() == .OK, let u = panel.url { destination = u.path }
    }

    private func start() {
        let path = (destination.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        var choices = ExtractChoices(destination: URL(fileURLWithPath: path, isDirectory: true))
        choices.overwrite = OverwriteMode(rawValue: overwriteRaw) ?? .overwrite
        if !allRAR && choices.overwrite == .rename { choices.overwrite = .overwrite }
        choices.keepPaths = model.tools.rarReader != nil ? keepPaths : true
        choices.keepBroken = keepBroken
        choices.createSubfolder = createSubfolder
        choices.useSelection = useSelection && !request.selectedRows.isEmpty
        choices.reveal = reveal

        var list = recents.filter { $0 != path }
        list.insert(path, at: 0)
        recentRaw = list.prefix(8).joined(separator: "\n")

        dismiss()
        Task { await model.runExtract(request, choices: choices) }
    }
}

// MARK: - Parola penceresi

struct PasswordSheet: View {
    let request: PasswordRequest
    let vault: PasswordVault
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var reveal = false
    @State private var save = false
    @State private var saveName = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill").font(.title).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading) {
                    Text("Parola gerekli").font(.headline)
                    Text("“\(request.archiveName)” parola ile korunuyor.").font(.callout).foregroundStyle(.secondary)
                }
            }
            if request.wrong {
                Label("Girilen parola hatalı. Tekrar deneyin.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Group {
                    if reveal { TextField("Parola", text: $password) } else { SecureField("Parola", text: $password) }
                }
                .focused($focused)
                .onSubmit(submit)
                SavedPasswordMenu(vault: vault) { picked in
                    password = picked.password
                    save = false // zaten kayıtlı
                }
            }
            HStack {
                Toggle("Parolayı göster", isOn: $reveal)
                Spacer()
            }
            Toggle("Bu parolayı parola yöneticisine kaydet", isOn: $save)
            if save {
                TextField("Kayıt adı", text: $saveName)
                Text("Parola, arşiv açıldıktan sonra macOS Anahtar Zinciri’ne kaydedilir; yanlış parola kaydedilmez.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("İptal") { request.resolve(nil); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Tamam", action: submit).keyboardShortcut(.defaultAction).disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            focused = true
            saveName = request.archiveName
        }
        .onDisappear { request.resolve(nil) } // Esc/yan tıklama ile kapanırsa bekleyen işlemi iptal et
    }

    private func submit() {
        guard !password.isEmpty else { return }
        request.resolve(password, saveName: save ? saveName : nil)
        dismiss()
    }
}

// MARK: - Metin istemi (yeniden adlandırma, yorum, kurtarma kaydı)

struct PromptSheet: View {
    let request: PromptRequest
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    init(request: PromptRequest) {
        self.request = request
        _text = State(initialValue: request.initialText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.title).font(.headline)
            Text(request.message).font(.callout).foregroundStyle(.secondary)
            if request.multiline {
                TextEditor(text: $text)
                    .frame(height: 120)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                    .focused($focused)
            } else {
                TextField("", text: $text).focused($focused).onSubmit(confirm)
            }
            HStack {
                Spacer()
                Button("İptal") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.confirmLabel, action: confirm)
                    .keyboardShortcut(request.multiline ? KeyboardShortcut("\r", modifiers: .command) : .defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { focused = true }
    }

    private func confirm() {
        let t = text
        dismiss()
        request.onConfirm(t)
    }
}

// MARK: - Arşiv bilgisi

struct InfoSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let archive = model.archiveURL, let l = model.listing {
                HStack(spacing: 12) {
                    Image(nsImage: Icons.archiveIcon()).resizable().frame(width: 48, height: 48)
                    VStack(alignment: .leading) {
                        Text(archive.lastPathComponent).font(.headline).lineLimit(2)
                        Text(archive.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head)
                    }
                }
                let fileSize = (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    row("Biçim", l.info.formatName.isEmpty ? "—" : l.info.formatName)
                    row("Özellikler", features(l.info))
                    row("Dosya sayısı", "\(l.fileCount)")
                    row("Klasör sayısı", "\(l.folderCount)")
                    row("Açılmış boyut", Format.bytes(l.totalSize))
                    if l.totalPacked > 0 { row("Sıkıştırılmış boyut", Format.bytes(l.totalPacked)) }
                    row("Arşiv dosyası boyutu", Format.bytes(fileSize))
                    if l.totalSize > 0, l.totalPacked > 0 {
                        row("Sıkıştırma oranı", String(localized: "%\(Int((Double(l.totalPacked) / Double(l.totalSize) * 100).rounded()))"))
                    }
                    if l.hasEncryptedFiles { row("Şifreleme", l.info.hasEncryptedHeaders ? String(localized: "Dosya içerikleri ve adlar") : String(localized: "Dosya içerikleri")) }
                    if let first = l.entries.first?.method { row("Yöntem", first) }
                }
                if let c = l.info.comment {
                    Divider()
                    Text("Yorum").font(.subheadline).bold()
                    ScrollView {
                        Text(c).font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                    .frame(maxHeight: 100)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
                }
            }
            HStack {
                if model.canEditRARFeatures {
                    Menu("Arşivi Düzenle") {
                        Button("Yorum Ekle/Değiştir…") { dismiss(); model.promptComment() }
                        Button("Kurtarma Kaydı Ekle…") { dismiss(); model.promptRecoveryRecord() }
                        Button("Arşivi Kilitle…") { dismiss(); model.confirmLock() }
                    }
                    .fixedSize()
                }
                Spacer()
                Button("Kapat") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func row(_ k: LocalizedStringKey, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(v).textSelection(.enabled)
        }
    }

    private func features(_ i: ArchiveInfo) -> String {
        var f: [String] = []
        if i.isSolid { f.append(String(localized: "Katı")) }
        if i.hasEncryptedHeaders { f.append(String(localized: "Şifreli adlar")) }
        if i.hasRecoveryRecord { f.append(String(localized: "Kurtarma kaydı")) }
        if i.isVolume { f.append(String(localized: "Çok parçalı")) }
        if i.isLocked { f.append(String(localized: "Kilitli")) }
        return f.isEmpty ? "—" : f.joined(separator: ", ")
    }
}
