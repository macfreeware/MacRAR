import Foundation
import Darwin

/// `bsdtar` dosya adını yalnızca dosyaya BAŞLARKEN yazdırır; tek büyük dosyada ilerleme hiç değişmezdi.
/// Bu izleyici, aracın açık dosyalarının o anki okuma/yazma konumunu (işletim sisteminden, `libproc` ile) okuyarak
/// ilerlemeyi bayt bazında verir. Yalnızca kendi alt sürecimizi okur; ek izin gerekmez.
public enum TransferMonitor {
    public struct OpenFile: Equatable, Sendable {
        public let path: String
        public let offset: Int64
    }

    /// Sürecin açık normal dosyaları ve konumları (okunamazsa boş).
    public static func openFiles(pid: Int32) -> [OpenFile] {
        let listBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard listBytes > 0 else { return [] }
        let count = Int(listBytes) / MemoryLayout<proc_fdinfo>.size + 8
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(count * MemoryLayout<proc_fdinfo>.size))
        guard got > 0 else { return [] }
        var result: [OpenFile] = []
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = withUnsafePointer(to: &info.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            result.append(OpenFile(path: path, offset: info.pfi.fi_offset))
        }
        return result
    }

    /// Çekirdeğin bildirdiği gerçek yol (`/var/...` → `/private/var/...`). `URL.resolvingSymlinksInPath` bu ön eki
    /// atladığı için kullanılmaz.
    public static func realPath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        return realpath(path, &buffer) != nil ? String(cString: buffer) : path
    }

    /// Açık dosyaları, `roots` (kaynakların üst klasörleri ya da çıkarma hedefi) altındaki göreli yola çevirir:
    /// ilerleme ağırlıkları bu göreli yollarla (örn. "proje/alt/dosya.bin") anahtarlanır.
    public static func candidates(in files: [OpenFile], roots: [String], absolute: Bool = false) -> [(key: String, offset: Int64)] {
        files.compactMap { f in
            guard let root = roots.first(where: { f.path == $0 || f.path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) else { return nil }
            if absolute { return (f.path, f.offset) }          // rar: ağırlıklar mutlak yolla anahtarlıdır
            guard f.path != root else { return nil }
            let prefixLength = root.hasSuffix("/") ? root.count : root.count + 1
            return (String(f.path.dropFirst(prefixLength)), f.offset)
        }
    }

    /// Süreç sürdükçe yaklaşık 8 kez/sn açık dosya konumlarını okuyup `tracker`'a bildirir. Dönen görev iptal edilince durur.
    public static func start(pid: Int32, roots: [String], absolute: Bool = false, tracker: ProgressTracker?) -> Task<Void, Never> {
        let resolved = roots.map(realPath)
        return Task.detached(priority: .utility) {
            while !Task.isCancelled {
                tracker?.setActive(candidates: candidates(in: openFiles(pid: pid), roots: resolved, absolute: absolute))
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }
}

/// `ProcessRunner.run(onStart:)` kapanışından görevi dışarı taşımak için küçük kutu.
final class TransferMonitorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    func set(_ t: Task<Void, Never>) { lock.lock(); task = t; lock.unlock() }
    func cancel() { lock.lock(); task?.cancel(); task = nil; lock.unlock() }
}
