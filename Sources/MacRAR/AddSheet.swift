import SwiftUI
import AppKit
import MacRARCore

/// "Arşiv adı ve parametreleri" penceresi.
struct AddSheet: View {
    let model: AppModel
    let request: AddRequest
    @Environment(\.dismiss) private var systemDismiss
    @Environment(\.panelClose) private var panelClose

    @AppStorage("addFormat") private var savedFormat = ArchiveFormat.rar5.rawValue
    @AppStorage("addMethod") private var savedMethod = CompressionMethod.normal.rawValue

    @State private var name: String
    @State private var folder: URL
    @State private var format: ArchiveFormat = .rar5
    @State private var method: CompressionMethod = .normal
    @State private var dictionary = ""
    @State private var solid = false
    @State private var splitEnabled = false
    @State private var splitSize = "100"
    @State private var splitUnit = "m"
    @State private var updateMode: UpdateMode = .add
    @State private var password = ""
    @State private var confirm = ""
    @State private var encryptNames = false
    @State private var testAfter = false
    @State private var deleteAfter = false
    @State private var lock = false
    @State private var recoveryEnabled = false
    @State private var recovery = 3
    @State private var keepSymlinks = true
    @State private var comment = ""
    @State private var addTimestamp = false
    @State private var savePassword = false
    @State private var estimate: SizeEstimator.Estimate?
    @State private var estimating = false

    init(model: AppModel, request: AddRequest) {
        self.model = model
        self.request = request
        _name = State(initialValue: request.defaultName)
        _folder = State(initialValue: request.defaultFolder)
        if request.existingArchive != nil, model.isZipArchive { _format = State(initialValue: .zip) }
    }

    /// Finder'dan açılan bağımsız pencerede (SheetPanel) kendi kapatma eylemi; ana pencerenin sayfasında sistem eylemi.
    private func dismiss() { if let panelClose { panelClose() } else { systemDismiss() } }

    private var isExisting: Bool { request.existingArchive != nil }
    private var tools: ToolPaths { model.tools }

    private var availableFormats: [ArchiveFormat] {
        ArchiveFormat.allCases.filter { $0.isRAR ? tools.canWriteRAR : tools.bsdtar != nil }
    }

    private var passwordMismatch: Bool { !password.isEmpty && password != confirm }
    private var nameInvalid: Bool {
        !isExisting && (name.trimmingCharacters(in: .whitespaces).isEmpty || name.contains("/"))
    }
    private var canCreate: Bool {
        if passwordMismatch || nameInvalid { return false }
        if isExisting { return model.canModifyArchive }
        return availableFormats.contains(format)
    }

    private var targetURL: URL {
        if let e = request.existingArchive { return e }
        var base = name.trimmingCharacters(in: .whitespaces)
        if addTimestamp {
            let st = model.stampSettings
            base += st.separator + ArchiveNaming.timestamp(pattern: st.pattern)
        }
        if !base.lowercased().hasSuffix("." + format.fileExtension) { base += "." + format.fileExtension }
        return folder.appendingPathComponent(base)
    }

    private enum Tab: String, CaseIterable, Identifiable {
        case general = "Genel", password = "Parola", advanced = "Gelişmiş"
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .general: return "Genel"
            case .password: return "Parola"
            case .advanced: return "Gelişmiş"
            }
        }
    }

    @State private var tab: Tab = .general
    @State private var showPassword = false

    /// Mevcut arşive ekleme ya da parola desteklemeyen biçimlerde "Parola" sekmesi gösterilmez.
    private var showsPasswordTab: Bool { !isExisting && format.supportsPassword }
    private var tabs: [Tab] { showsPasswordTab ? Tab.allCases : [.general, .advanced] }

    var body: some View {
        VStack(spacing: 0) {
            CompactBrandBar(badge: isExisting ? "ARŞİVE EKLE" : "ARŞİV OLUŞTUR", leadingInset: panelClose != nil ? 78 : 14)
            Picker("", selection: $tab) {
                ForEach(tabs) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 2)

            Form {
                switch tab {
                case .general: generalTab
                case .password: passwordTab
                case .advanced: advancedTab
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if !canCreate && !isExisting && !availableFormats.contains(format) {
                    Text("Seçili biçim için gerekli araç bulunamadı.").font(.callout).foregroundStyle(.red)
                } else if passwordMismatch {
                    Label("Parolalar eşleşmiyor.", systemImage: "xmark.circle").font(.callout).foregroundStyle(.red)
                }
                Spacer()
                Button("İptal") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isExisting ? "Ekle" : "Arşivle") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
            .padding(12)
        }
        .frame(width: 540, height: 650)
        .onAppear {
            if isExisting {
                format = model.isZipArchive ? .zip
                    : (model.listing?.info.formatName.contains("4") ?? false) ? .rar4 : .rar5
            } else if let f = ArchiveFormat(rawValue: savedFormat), availableFormats.contains(f) {
                format = f
            } else if let f = availableFormats.first {
                format = f
            }
            method = CompressionMethod(rawValue: savedMethod) ?? .normal
        }
        .onChange(of: format) { if !tabs.contains(tab) { tab = .general } }
        // Boş bir Group'a bağlı .task hiç çalışmaz (görünüm yok); bu yüzden hesaplama kök görünümde başlatılır.
        .task(id: estimateKey) { await updateEstimate() }
    }

    // MARK: Genel: ad/konum/biçim ve sıkıştırma

    @ViewBuilder private var generalTab: some View {
        if isExisting {
            Section("Hedef arşiv") {
                LabeledContent("Arşiv", value: request.existingArchive!.lastPathComponent)
                if !request.pathInArchive.isEmpty {
                    LabeledContent("Arşiv içi klasör", value: request.pathInArchive)
                }
                LabeledContent("Eklenecek", value: summary)
                estimateLabel
            }
        } else {
            Section("Arşiv") {
                // Ad alanı tam genişlikte ve sola yaslı; sonuçta oluşacak dosya adı hemen altında görünür.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Arşiv adı").foregroundStyle(.secondary).font(.callout)
                    TextField("", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .labelsHidden()
                    Text("\(targetURL.lastPathComponent)  ·  \(summary)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    estimateLabel
                }
                Toggle("Ada zaman damgası ekle (biçim: Ayarlar)", isOn: $addTimestamp)
                if FileManager.default.fileExists(atPath: targetURL.path) {
                    Label(format.isRAR ? "Bu ada sahip arşiv var; dosyalar ona eklenecek."
                                       : "Bu ada sahip dosyanın üzerine yazılacak.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
                // Konum tek satırda kalır (uzun yol baştan kısaltılır); alt alta kırılıp pencereyi uzatmaz.
                LabeledContent("Konum") {
                    HStack(spacing: 8) {
                        Text(folder.path).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                            .frame(maxWidth: 240, alignment: .trailing)
                        Button("Seç…") { chooseFolder() }
                    }
                }
                Picker("Biçim", selection: $format) {
                    ForEach(availableFormats) { f in Text(label(for: f)).tag(f) }
                }
            }
        }

        Section("Sıkıştırma") {
            if isExisting && format == .zip {
                Text("Arşivdeki dosyalar korunur; aynı adlı dosyalar yenileriyle değiştirilir.").foregroundStyle(.secondary)
            } else if format.isRAR || isExisting {
                Picker("Yöntem", selection: $method) {
                    ForEach(CompressionMethod.allCases, id: \.self) { m in Text(label(for: m)).tag(m) }
                }
                if !isExisting && format == .rar5 {
                    Picker("Sözlük boyutu", selection: $dictionary) {
                        Text("Otomatik").tag("")
                        ForEach(["1m", "4m", "16m", "64m", "128m", "256m", "512m", "1g"], id: \.self) { d in
                            Text(d.replacingOccurrences(of: "m", with: " MB").replacingOccurrences(of: "g", with: " GB")).tag(d)
                        }
                    }
                }
                Picker("Güncelleme kipi", selection: $updateMode) {
                    Text("Ekle ve değiştir").tag(UpdateMode.add)
                    Text("Yalnızca yeni/değişenleri güncelle").tag(UpdateMode.update)
                }
            } else if format == .zip {
                Picker("Yöntem", selection: Binding(get: { method == .store }, set: { method = $0 ? .store : .normal })) {
                    Text("Normal (deflate)").tag(false)
                    Text("Sıkıştırmasız").tag(true)
                }
            } else {
                Text("Bu biçim için sıkıştırma düzeyi otomatik seçilir.").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Boyut tahmini

    /// Kaynak boyutu ve örnekleme ile hesaplanan yaklaşık arşiv boyutu.
    @ViewBuilder private var estimateLabel: some View {
        Group {
            if let e = estimate, e.totalBytes > 0 {
                let packed = e.sampled || method == .store
                Text(String(localized: "Kaynak: \(Format.bytes(e.totalBytes)) (\(e.fileCount) dosya)")
                     + (packed ? "  ·  " + String(localized: "tahmini arşiv: ~\(Format.bytes(e.estimatedBytes))") : ""))
            } else if estimating {
                Text("Boyut hesaplanıyor…")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    /// Kaynaklar ya da sıkıştırmasız seçimi değişince tahmin yenilenir.
    private var estimateKey: String {
        request.sources.map(\.path).joined(separator: "|") + "#\(format.rawValue)#\(method.rawValue)"
    }

    private func updateEstimate() async {
        let sources = request.sources
        let store = method == .store && (format.isRAR || format == .zip)
        estimating = true
        let work = Task.detached(priority: .utility) { SizeEstimator.estimate(sources: sources, store: store) }
        let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard !Task.isCancelled else { return }
        estimate = result
        estimating = false
    }

    // MARK: Parola

    @ViewBuilder private var passwordTab: some View {
        Section("Parola") {
            LabeledContent("Parola") { passwordField($password) }
            LabeledContent("Parolayı doğrula") { passwordField($confirm) }
            Toggle("Parolayı göster", isOn: $showPassword)
            LabeledContent("Kayıtlı parolalar") {
                SavedPasswordMenu(vault: model.vault, title: "Seç…") { picked in
                    password = picked.password
                    confirm = picked.password
                    savePassword = false
                }
            }
            if passwordMismatch {
                Label("Parolalar eşleşmiyor.", systemImage: "xmark.circle").foregroundStyle(.red).font(.callout)
            }
        }
        Section("Seçenekler") {
            if !password.isEmpty {
                Toggle("Bu parolayı parola yöneticisine kaydet", isOn: $savePassword)
            }
            if format.isRAR {
                Toggle("Dosya adlarını da şifrele", isOn: $encryptNames).disabled(password.isEmpty)
            } else if format == .zip {
                Text("ZIP için AES-256 kullanılır.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Gelişmiş

    @ViewBuilder private var advancedTab: some View {
        if format.isRAR {
            Section("RAR seçenekleri") {
                if !isExisting {
                    Toggle("Katı arşiv oluştur", isOn: $solid)
                    Toggle("Parçalara böl", isOn: $splitEnabled)
                    if splitEnabled {
                        HStack {
                            TextField("Boyut", text: $splitSize).frame(width: 90)
                            Picker("", selection: $splitUnit) {
                                Text("KB").tag("k"); Text("MB").tag("m"); Text("GB").tag("g")
                            }
                            .labelsHidden().frame(width: 80)
                        }
                    }
                    Toggle("Arşivi kilitle", isOn: $lock)
                }
                Toggle("Sembolik bağlantıları sakla", isOn: $keepSymlinks)
                Toggle("Kurtarma kaydı ekle", isOn: $recoveryEnabled)
                if recoveryEnabled {
                    Stepper("Kurtarma kaydı: %\(recovery)", value: $recovery, in: 1...10)
                }
            }
        }
        Section("İşlem sonrası") {
            if format.isRAR {
                Toggle("Arşivlemeden sonra sına", isOn: $testAfter)
            }
            Toggle("Arşivlemeden sonra kaynak dosyaları sil", isOn: $deleteAfter)
            if deleteAfter {
                Label("Kaynak dosyalar kalıcı olarak silinir (Çöp Kutusu’na gitmez).", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
        if !isExisting && format.isRAR {
            Section("Yorum") {
                TextEditor(text: $comment)
                    .font(.body).frame(height: 56)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            }
        }
        if !format.isRAR {
            Section { Text("Bu biçim için ek seçenek yok.").foregroundStyle(.secondary) }
        }
    }

    /// İki parola alanı aynı genişlik ve sola yaslı metinle hizalanır; "Parolayı göster" ile düz metin görünür.
    @ViewBuilder
    private func passwordField(_ text: Binding<String>) -> some View {
        Group {
            if showPassword { TextField("", text: text) } else { SecureField("", text: text) }
        }
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.leading)
        .frame(width: 250)
    }

    private var summary: String {
        let n = request.sources.count
        if n == 1 { return request.sources[0].lastPathComponent }
        return String(localized: "\(n) öğe")
    }

    private func label(for f: ArchiveFormat) -> String {
        switch f {
        case .rar5: return "RAR"
        case .rar4: return String(localized: "RAR4 (eski uyumluluk)")
        case .zip: return "ZIP"
        case .sevenZip: return "7Z"
        case .tarGz: return "TAR.GZ"
        case .tarBz2: return "TAR.BZ2"
        case .tarXz: return "TAR.XZ"
        }
    }

    private func label(for m: CompressionMethod) -> String {
        switch m {
        case .store: return String(localized: "Sıkıştırmasız")
        case .fastest: return String(localized: "En hızlı")
        case .fast: return String(localized: "Hızlı")
        case .normal: return String(localized: "Normal")
        case .good: return String(localized: "İyi")
        case .best: return String(localized: "En iyi")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = String(localized: "Seç")
        if panel.runModal() == .OK, let u = panel.url { folder = u }
    }

    private func start() {
        var o = CompressOptions(archive: targetURL, sources: request.sources)
        o.format = format
        o.method = method
        o.updateMode = updateMode
        o.keepSymlinks = keepSymlinks
        o.testAfter = testAfter
        o.deleteAfter = deleteAfter
        o.pathInArchive = request.pathInArchive
        o.appendToExisting = isExisting

        if isExisting {
            o.format = format
            // Açık arşivin parolası biliniyorsa yeni dosyalar da aynı parolayla eklenir.
            if let pw = model.archivePassword, !pw.isEmpty {
                o.password = pw
                o.encryptNames = model.listing?.info.hasEncryptedHeaders ?? false
            }
        } else {
            if !password.isEmpty { o.password = password; o.encryptNames = encryptNames && format.isRAR }
            if format.isRAR {
                o.dictionary = dictionary.isEmpty ? nil : dictionary
                o.solid = solid
                o.lock = lock
                if splitEnabled, let n = Int(splitSize.trimmingCharacters(in: .whitespaces)), n > 0 {
                    o.volumeSize = "\(n)\(splitUnit)"
                }
                if !comment.isEmpty { o.comment = comment }
            }
        }
        if format.isRAR, recoveryEnabled { o.recoveryPercent = recovery }

        if !isExisting {
            savedFormat = format.rawValue
            savedMethod = method.rawValue
        }
        if savePassword, !password.isEmpty, !isExisting {
            let pw = password, label = targetURL.deletingPathExtension().lastPathComponent
            Task { await model.saveToVault(name: label, password: pw) }
        }
        dismiss()
        Task { await model.runAdd(o) }
    }
}
