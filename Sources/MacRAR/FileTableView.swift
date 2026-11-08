import SwiftUI
import MacRARCore

/// Ad sütunu hücresi.
struct NameCell: View {
    let row: Row
    let showLocation: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: AppModel.shared.archivedAppIcon(for: row) ?? Icons.icon(for: row)).resizable().frame(width: 18, height: 18)
            Text(row.name).lineLimit(1).truncationMode(.middle)
            if row.isEncrypted {
                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
            }
            if showLocation, !row.location.isEmpty {
                Text(row.location).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
        }
    }
}

struct FileTableView: View {
    @Bindable var model: AppModel

    var body: some View {
        if model.isInArchive {
            archiveTable
        } else {
            folderTable
        }
    }

    private var folderTable: some View {
        Table(model.rows, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Ad", value: \.name, comparator: .localizedStandard) { row in
                NameCell(row: row, showLocation: false)
            }
            .width(min: 180, ideal: 320)
            TableColumn("Boyut", value: \.sizeValue) { row in
                Text(row.sizeText).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Tür", value: \.kind) { row in
                Text(row.kind).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 90, ideal: 150)
            TableColumn("Değiştirilme", value: \.modifiedValue) { row in
                Text(row.modifiedText).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 120, ideal: 160)
        }
        .with(RowInteractions(model: model))
    }

    private var archiveTable: some View {
        Table(of: Row.self, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Ad", value: \.name, comparator: .localizedStandard) { row in
                NameCell(row: row, showLocation: !model.searchText.isEmpty)
            }
            .width(min: 180, ideal: 300)
            TableColumn("Boyut", value: \.sizeValue) { row in
                Text(row.sizeText).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Sıkıştırılmış", value: \.packedValue) { row in
                Text(row.packedText).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80, ideal: 100)
            TableColumn("Tür", value: \.kind) { row in
                Text(row.kind).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 130)
            TableColumn("Değiştirilme", value: \.modifiedValue) { row in
                Text(row.modifiedText).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 120, ideal: 150)
            TableColumn("CRC32", value: \.crc) { row in
                Text(row.crc).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)
        } rows: {
            // Satırlar Finder'a sürüklenebilir: çıkarma bırakma anında yapılır.
            ForEach(model.rows) { row in
                if row.isDirectory {
                    TableRow(row).draggable(ArchiveFolderDrag(payload: model.dragPayload(for: row)))
                } else {
                    TableRow(row).draggable(ArchiveFileDrag(payload: model.dragPayload(for: row)))
                }
            }
        }
        .with(RowInteractions(model: model))
    }
}

/// Çift tıklama, bağlam menüsü ve klavye kısayolları.
struct RowInteractions: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content
            .contextMenu(forSelectionType: Row.ID.self) { ids in
                contextMenu(for: ids)
            } primaryAction: { ids in
                model.openRows(ids)
            }
            .onKeyPress(.space) {
                guard model.canView else { return .ignored }
                model.quickLook()
                return .handled
            }
            .onKeyPress(.delete) {
                model.goUp()
                return .handled
            }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<Row.ID>) -> some View {
        let rows = ids.compactMap { id in model.rows.first { $0.id == id } }
        if rows.isEmpty {
            Button("Yenile") { model.reloadCurrent() }
        } else if model.isInArchive {
            Button(rows[0].isDirectory ? "Klasörü Aç" : "Aç") { model.open(rows[0]) }
            if rows.contains(where: { !$0.isDirectory }) {
                Button("Önizle") { model.selection = ids; model.quickLook() }
            }
            Divider()
            Button("Seçilenleri Çıkar…") { model.selection = ids; model.showExtract() }
            Button("Buraya Çıkar") { model.selection = ids; Task { await model.extractHereQuick() } }
            if model.canModifyArchive {
                Divider()
                if rows.count == 1 { Button("Yeniden Adlandır…") { model.selection = ids; model.promptRename() } }
                Button("Arşivden Sil", role: .destructive) { model.selection = ids; model.confirmDelete() }
            }
            Divider()
            Button("Yolu Kopyala") { model.selection = ids; model.copyPathOfSelection() }
        } else {
            let archives = rows.filter(\.isArchiveFile)
            Button(rows[0].isDirectory ? "Klasörü Aç" : (rows[0].isArchiveFile ? "Arşivi Aç" : "Aç")) { model.open(rows[0]) }
            if !archives.isEmpty {
                Button("Dosyaları Çıkar…") { model.selection = ids; model.showExtract() }
                Button("Buraya Aç") { model.quickExtract(archives.compactMap(\.url), intoSubfolder: false) }
                Button("Aç (arşiv adıyla klasöre)") { model.quickExtract(archives.compactMap(\.url), intoSubfolder: true) }
                Button(archives.count > 1 ? "Arşivleri Sına" : "Arşivi Sına") { model.selection = ids; Task { await model.runTest() } }
                if archives.count >= 2 {
                    Button("Arşivleri Birleştir…") { model.selection = ids; model.beginMerge() }
                }
                if archives.count == 2 {
                    Button("Arşivleri Karşılaştır…") { model.selection = ids; model.showCompare() }
                }
            }
            Divider()
            Button("Arşive Ekle…") { model.selection = ids; model.showAdd() }
            Button("RAR’a Sıkıştır") { model.quickCompress(rows.compactMap(\.url), timestamped: false) }
            Button("RAR’a Sıkıştır (zaman damgalı)") { model.quickCompress(rows.compactMap(\.url), timestamped: true) }
            Divider()
            Button("Finder’da Göster") { model.selection = ids; model.revealSelectionInFinder() }
            Button("Yolu Kopyala") { model.selection = ids; model.copyPathOfSelection() }
            Divider()
            Button("Çöp Kutusu’na Taşı", role: .destructive) { model.selection = ids; model.confirmDelete() }
        }
    }
}
