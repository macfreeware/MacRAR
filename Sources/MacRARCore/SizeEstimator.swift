import Foundation
import Compression

/// Sıkıştırılmış arşiv boyutu tahmini: kaynakların toplam boyutunu bulur, dosyalardan küçük örnekler alıp zlib ile sıkıştırarak
/// oranı ölçer ve toplama uygular. Yaklaşık bir değerdir (RAR/7Z genelde biraz daha küçük, ZIP/TAR.GZ buna yakın üretir).
public enum SizeEstimator {
    public struct Estimate: Sendable, Equatable {
        public var totalBytes: Int64
        public var fileCount: Int
        /// Tahmini arşiv boyutu (bayt).
        public var estimatedBytes: Int64
        /// Örnek alınamadıysa (boş/okunamayan) false.
        public var sampled: Bool
    }

    /// Örnek alma sınırları: en çok bu kadar dosya, dosya başına bu kadar bayt, toplamda bu kadar bayt.
    static let maxSampledFiles = 40
    static let bytesPerFile = 128 * 1024
    static let maxSampleBytes = 4 * 1024 * 1024
    static let maxScannedFiles = 200_000

    /// Eşzamanlı çağrılabilir; büyük ağaçlarda zaman alabilir (arka planda çalıştırın). İptal edilirse nil.
    public static func estimate(sources: [URL], store: Bool = false) -> Estimate? {
        let fm = FileManager.default
        var files: [(url: URL, size: Int64)] = []
        var total: Int64 = 0
        var scanned = 0

        func add(_ url: URL, _ size: Int64) { files.append((url, size)); total += size }

        for src in sources {
            if Task.isCancelled { return nil }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                add(src, ((try? fm.attributesOfItem(atPath: src.path)[.size]) as? NSNumber)?.int64Value ?? 0)
                continue
            }
            guard let en = fm.enumerator(at: src, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []) else { continue }
            for case let url as URL in en {
                if Task.isCancelled { return nil }
                scanned += 1
                if scanned > maxScannedFiles { break }
                let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard v?.isRegularFile == true else { continue }
                add(url, Int64(v?.fileSize ?? 0))
            }
        }
        guard total > 0 else { return Estimate(totalBytes: 0, fileCount: files.count, estimatedBytes: 0, sampled: false) }
        if store { return Estimate(totalBytes: total, fileCount: files.count, estimatedBytes: total, sampled: false) }

        // En büyük dosyalar boyutun çoğunu belirler: onlardan örnek al (büyükten küçüğe).
        let candidates = files.filter { $0.size > 0 }.sorted { $0.size > $1.size }.prefix(maxSampledFiles)
        var inBytes: Int64 = 0, outBytes: Int64 = 0
        var weightedRatio = 0.0, weight = 0.0
        for f in candidates {
            if Task.isCancelled { return nil }
            if inBytes >= Int64(maxSampleBytes) { break }
            guard let h = try? FileHandle(forReadingFrom: f.url) else { continue }
            defer { try? h.close() }
            // Büyük dosyalarda ortadan al (başlıklar genelde sıkıştırılamaz/aşırı sıkışır).
            if f.size > Int64(bytesPerFile) * 2 { try? h.seek(toOffset: UInt64(f.size / 2)) }
            guard let data = try? h.read(upToCount: bytesPerFile), !data.isEmpty,
                  let packed = deflatedSize(data) else { continue }
            inBytes += Int64(data.count); outBytes += Int64(packed)
            let ratio = min(1.0, Double(packed) / Double(data.count))
            weightedRatio += ratio * Double(f.size); weight += Double(f.size)
        }
        guard weight > 0 else {
            return Estimate(totalBytes: total, fileCount: files.count, estimatedBytes: total, sampled: false)
        }
        // Örneklenen büyük dosyaların oranı, örneklenmeyen küçük dosyalara da uygulanır.
        let ratio = weightedRatio / weight
        // Her dosya için arşiv üstbilgisi (~100 bayt) kaba olarak eklenir.
        let est = Int64(Double(total) * ratio) + Int64(files.count) * 100
        return Estimate(totalBytes: total, fileCount: files.count, estimatedBytes: min(est, total + Int64(files.count) * 100), sampled: true)
    }

    static func deflatedSize(_ data: Data) -> Int? {
        let capacity = data.count + data.count / 10 + 1024
        var out = [UInt8](repeating: 0, count: capacity)
        let n = data.withUnsafeBytes { src -> Int in
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(&out, capacity, base, data.count, nil, COMPRESSION_ZLIB)
        }
        return n > 0 ? n : nil
    }
}
