import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable
import MacRARCore

/// Arşivden Finder'a sürüklenen bir öğenin tarifi. Çıkarma, sürükleme başlarken değil, kullanıcı
/// bırakınca (Finder dosyayı istediğinde) yapılır; böylece yalnızca gerçekten bırakılanlar çıkarılır.
struct ArchiveDragPayload: Sendable {
    let archive: URL
    let root: ArchiveEntry
    let allEntries: [ArchiveEntry]
    let password: String?
    let service: ArchiveService

    /// Öğeyi (klasörse içeriğiyle) geçici klasöre çıkarıp yolunu döndürür.
    func materialize() async throws -> URL {
        let selection = ArchiveSelection.expand([root], in: allEntries)
        do {
            let url = try await service.extractToTemporary(archive: archive, root: root,
                                                           selection: selection.isEmpty ? [root] : selection,
                                                           password: password)
            DragRecord.shared.set(DraggedItem(archive: archive, rootPath: root.path, url: url, at: Date()))
            return url
        } catch {
            // Beklemeden: uygulama içi bırakmada ana iş parçacığı bu dosyayı eşzamanlı bekler; beklenirse kilitlenir.
            let archive = archive
            Task { @MainActor in AppModel.shared.dragExtractionFailed(archive: archive, error: error) }
            throw error
        }
    }

    var reference: ArchiveItemRef { ArchiveItemRef(archivePath: archive.path, entryPath: root.path) }
}

/// MacRAR içinde bırakılan sürüklemeler için hangi arşivin hangi öğesi olduğu. Dosya çıkarılmaz; bu yüzden ana iş
/// parçacığını bekletmez. Finder bu türü tanımaz ve dosyayı ister.
struct ArchiveItemRef: Codable, Transferable, Sendable {
    let archivePath: String
    let entryPath: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .macrarArchiveItem)
            .visibility(.ownProcess)
    }
}

extension UTType {
    static let macrarArchiveItem = UTType(exportedAs: "local.macrar.archive-item")
}

/// Son sürüklenip çıkarılan öğe. Herhangi bir iş parçacığından yazılır.
final class DragRecord: @unchecked Sendable {
    static let shared = DragRecord()
    private let lock = NSLock()
    private var item: DraggedItem?

    var latest: DraggedItem? { lock.withLock { item } }
    func set(_ value: DraggedItem?) { lock.withLock { item = value } }
}

/// Son sürüklenip çıkarılan öğe. macOS uygulama içi bırakmada dosyanın bir kopyasını başka bir yerde verir; pencereye
/// geri bırakılan öğenin arşivden geldiği buradan anlaşılır.
struct DraggedItem: Sendable {
    let archive: URL
    let rootPath: String
    /// MacRAR'ın geçici klasöründeki asıl kopya.
    let url: URL
    let at: Date
}

/// Dosya sürüklemesi. (Klasörler için `ArchiveFolderDrag`: içerik türü öğeye göre değişemediğinden ayrı tür.)
struct ArchiveFileDrag: Transferable, Sendable {
    let payload: ArchiveDragPayload

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { item in
            SentTransferredFile(try await item.payload.materialize(), allowAccessingOriginalFile: false)
        }
        .suggestedFileName { $0.payload.root.name }
        // Yalnızca MacRAR içinde (kenar çubuğundaki Uygulamalar); Finder bunu görürse dosya diye kaydeder.
        ProxyRepresentation(exporting: \.payload.reference)
            .visibility(.ownProcess)
    }
}

struct ArchiveFolderDrag: Transferable, Sendable {
    let payload: ArchiveDragPayload

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .folder) { item in
            SentTransferredFile(try await item.payload.materialize(), allowAccessingOriginalFile: false)
        }
        .suggestedFileName { $0.payload.root.name }
        // Yalnızca MacRAR içinde (kenar çubuğundaki Uygulamalar); Finder bunu görürse dosya diye kaydeder.
        ProxyRepresentation(exporting: \.payload.reference)
            .visibility(.ownProcess)
    }
}

extension AppModel {
    /// Bu satır için sürükleme tarifi. Arşiv sürükleme anında kapanmışsa çıkarma hata verir (çökmez).
    func dragPayload(for row: Row) -> ArchiveDragPayload {
        let archive = archiveURL ?? URL(fileURLWithPath: "/nonexistent.rar")
        let all = listing?.entries ?? []
        let root = row.entry ?? ArchiveEntry(path: row.archivePath, isDirectory: row.isDirectory, size: row.sizeValue)
        return ArchiveDragPayload(archive: archive, root: root, allEntries: all,
                                  password: archivePassword, service: service)
    }

    /// Sürükleme sırasında çıkarma başarısız olursa kullanıcıya bildirir. Parola gerekiyorsa sorar ve
    /// oturum için hatırlar; böylece kullanıcı sürüklemeyi tekrar denediğinde çalışır.
    func dragExtractionFailed(archive: URL, error: Error) {
        if case ArchiveError.cancelled = error { return }
        if case ArchiveError.passwordRequired = error {
            Task {
                if let pw = await askPassword(archive: archive, wrong: false), archive == archiveURL {
                    archivePassword = pw
                    alert = AlertInfo(title: String(localized: "Parola kaydedildi"), message: String(localized: "Dosyaları sürükleyerek çıkarmak için işlemi yeniden deneyin."))
                }
            }
        } else if case ArchiveError.wrongPassword = error {
            Task {
                if let pw = await askPassword(archive: archive, wrong: true), archive == archiveURL {
                    archivePassword = pw
                    alert = AlertInfo(title: String(localized: "Parola kaydedildi"), message: String(localized: "Dosyaları sürükleyerek çıkarmak için işlemi yeniden deneyin."))
                }
            }
        } else {
            alert = AlertInfo(title: String(localized: "Sürükleyerek çıkarılamadı"), message: error.localizedDescription)
        }
    }
}
