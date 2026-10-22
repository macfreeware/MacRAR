import Foundation

/// İki arşivin içeriğini (girdi listelerinden) karşılaştırır. Diske çıkarmaz.
public enum ArchiveComparison {
    public enum Status: String, Sendable, CaseIterable {
        /// Yalnızca ilk arşivde var.
        case onlyInFirst
        /// Yalnızca ikinci arşivde var.
        case onlyInSecond
        /// İçerik farklı (CRC farklı).
        case differentContent
        /// Boyut farklı (CRC bilinmiyor ya da karşılaştırılamadı).
        case differentSize
        /// CRC ve boyut aynı: içerik aynı.
        case identical
        /// Boyut aynı ama en az bir tarafta CRC yok: aynı olduğu doğrulanamadı.
        case sameSizeUnverified
        /// Biri dosya, öteki klasör.
        case typeMismatch
    }

    public struct Item: Identifiable, Sendable, Equatable {
        public var id: String { path }
        public var path: String
        public var status: Status
        public var first: ArchiveEntry?
        public var second: ArchiveEntry?

        /// Farkı olan (aynı/doğrulanamayan dışındaki) satır mı?
        public var isDifference: Bool {
            switch status {
            case .identical, .sameSizeUnverified: return false
            default: return true
            }
        }
    }

    public struct Result: Sendable {
        public var items: [Item]
        public func count(_ s: Status) -> Int { items.lazy.filter { $0.status == s }.count }
        public var differenceCount: Int { items.lazy.filter(\.isDifference).count }
        public var isIdentical: Bool { differenceCount == 0 && count(.sameSizeUnverified) == 0 }
    }

    /// Klasör girdileri yalnızca varlık olarak karşılaştırılmaz (dosyaların yoluyla zaten belli olur): sonuçtan çıkarılır.
    public static func compare(_ first: [ArchiveEntry], _ second: [ArchiveEntry]) -> Result {
        func index(_ list: [ArchiveEntry]) -> [String: ArchiveEntry] {
            var d: [String: ArchiveEntry] = [:]
            for e in list { d[e.path.precomposedStringWithCanonicalMapping] = e }
            return d
        }
        let a = index(first), b = index(second)
        var items: [Item] = []
        for key in Set(a.keys).union(b.keys) {
            let x = a[key], y = b[key]
            switch (x, y) {
            case let (x?, nil):
                if !x.isDirectory { items.append(Item(path: x.path, status: .onlyInFirst, first: x, second: nil)) }
            case let (nil, y?):
                if !y.isDirectory { items.append(Item(path: y.path, status: .onlyInSecond, first: nil, second: y)) }
            case let (x?, y?):
                if x.isDirectory && y.isDirectory { continue }
                if x.isDirectory != y.isDirectory {
                    items.append(Item(path: x.path, status: .typeMismatch, first: x, second: y))
                } else if let cx = x.crc32, let cy = y.crc32, !cx.isEmpty, !cy.isEmpty {
                    let same = cx.caseInsensitiveCompare(cy) == .orderedSame && x.size == y.size
                    items.append(Item(path: x.path, status: same ? .identical : .differentContent, first: x, second: y))
                } else if x.size != y.size {
                    items.append(Item(path: x.path, status: .differentSize, first: x, second: y))
                } else {
                    items.append(Item(path: x.path, status: .sameSizeUnverified, first: x, second: y))
                }
            case (nil, nil): break
            }
        }
        items.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return Result(items: items)
    }
}

/// Birleştirme: aynı yola sahip dosyalar birden çok arşivde varsa sonraki arşivdeki geçerli olur.
public enum ArchiveMerge {
    /// Birden çok arşivde bulunan dosya yolları (klasörler sayılmaz). Sıra: arşivlerin verildiği sıra.
    public static func conflicts(in listings: [[ArchiveEntry]]) -> [String] {
        var seen = Set<String>()
        var dup = Set<String>()
        for entries in listings {
            for e in entries where !e.isDirectory {
                let k = e.path.precomposedStringWithCanonicalMapping
                if !seen.insert(k).inserted { dup.insert(e.path) }
            }
        }
        return dup.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
