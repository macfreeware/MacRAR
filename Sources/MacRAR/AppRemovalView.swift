import SwiftUI
import AppKit
import MacRARCore

/// "Yardım ▸ MacRAR'ı Kaldır…" penceresi.
struct AppRemovalView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var removeUserData = true
    @State private var removePasswords = false
    @State private var confirming = false
    @State private var working = false
    @State private var progress = ""
    @State private var failure: String?
    @State private var report: AppRemoval.Report?

    private var removableApp: URL? {
        AppRemoval.removableApp(bundleURL: Bundle.main.bundleURL, parents: AppRemoval.Environment.live.appParents)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 48, height: 48)
                Text("MacRAR’ı Kaldır").font(.system(size: 20, weight: .bold))
            }

            if let report {
                done(report)
            } else {
                form
            }
        }
        .padding(22)
        .frame(width: 480)
        .confirmationDialog("MacRAR kaldırılsın mı?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Kaldır", role: .destructive) { Task { await run() } }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Yönetici parolanız istenecek ve Finder yeniden başlayacak.")
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let app = removableApp {
                Text("Şunlar kaldırılır: \(app.path), Finder sağ tık eklentisi ve kurulum kaydı. Yönetici parolası istenebilir.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Bu kopya Uygulamalar klasöründe değil (\(Bundle.main.bundleURL.path)); uygulama dosyası silinmez, onu kendiniz Çöp Kutusu’na atın. Eklenti kaydı ve seçtiğiniz veriler temizlenir.",
                      systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $removeUserData) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ayarları ve indirilen araçları da sil")
                            Text("Tercihler, Finder gizli anahtarı ve Kurulum Yardımcısı’nın indirdiği rar/unrar (~/Library/Application Support/MacRAR).")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Toggle(isOn: $removePasswords) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Kayıtlı parolaları da sil")
                            Text("Parola Yöneticisi’ndeki parolalar (Anahtar Zinciri). Bu işlem geri alınamaz.")
                                .font(.caption).foregroundStyle(removePasswords ? Color.red : Color.secondary)
                        }
                    }
                }
                .padding(4)
            }

            if working {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(progress).font(.callout).foregroundStyle(.secondary) }
            }
            if let failure { Text(failure).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }

            HStack {
                Spacer()
                Button("Vazgeç") { dismiss() }.disabled(working)
                Button("MacRAR’ı Kaldır…", role: .destructive) { confirming = true }
                    .keyboardShortcut(.defaultAction).disabled(working)
            }
        }
    }

    private func done(_ report: AppRemoval.Report) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("MacRAR kaldırıldı.", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green)
            if !report.appRemoved {
                Text("Uygulama dosyası silinmedi: \(report.appPath) konumundaki MacRAR’ı Çöp Kutusu’na atın.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Text("Finder birkaç saniye içinde yeniden başlayacak; sağ tık girdileri kaybolur. Uygulama kapanıyor…")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("Şimdi kapat") { NSApp.terminate(nil) }.keyboardShortcut(.defaultAction) }
        }
    }

    private func run() async {
        working = true; failure = nil
        defer { working = false }
        do {
            let result = try await AppRemoval.remove(
                options: .init(removeUserData: removeUserData, removePasswords: removePasswords),
                progress: { text in Task { @MainActor in progress = text } })
            report = result
            try? await Task.sleep(for: .seconds(4))
            NSApp.terminate(nil)
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// Yardım menüsündeki "MacRAR’ı Kaldır…" girdisi.
struct UninstallCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("MacRAR’ı Kaldır…") {
            openWindow(id: "uninstall")
            NSApplication.shared.activate()
        }
    }
}
