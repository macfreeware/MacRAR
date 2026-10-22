import Foundation

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let output: Data
    /// `onOutput` true döndürdüğü için süreç erken sonlandırıldıysa true.
    public let killedEarly: Bool

    public var text: String { String(decoding: output, as: UTF8.self) }
}

/// Kilitli küçük durum taşıyıcı (Process'i iptal/erken-kapatma için paylaşır).
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private(set) var cancelled = false
    private(set) var killedEarly = false
    private var buffer = Data()

    func attach(_ p: Process) {
        lock.lock(); defer { lock.unlock() }
        process = p
        if cancelled, p.isRunning { p.terminate() }
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let p = process, p.isRunning { p.terminate() }
    }

    func killEarly() {
        lock.lock(); defer { lock.unlock() }
        killedEarly = true
        if let p = process, p.isRunning { p.terminate() }
    }

    func append(_ d: Data, capture: Bool) {
        guard capture else { return }
        lock.lock(); buffer.append(d); lock.unlock()
    }

    var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
}

public enum ProcessRunner {
    /// Foundation, süreç argümanlarını macOS'un dosya sistemi gösterimine (ayrışık/NFD Unicode) çevirerek gönderir:
    /// "ş" (c5 9f) alt sürece "s" + çengel (73 cc a7) olarak ulaşır. Dosya yolları için zararsızdır (APFS ve HFS+ ikisini
    /// de çözer) ama PAROLA gibi baytların aynen taşınması gereken argümanları bozar: başka programlarda oluşturulmuş
    /// bir arşivin Türkçe karakterli parolası tutmaz, MacRAR'ın oluşturduğu da başka yerde açılmaz.
    ///
    /// `exact` içindeki ASCII dışı argümanlar, yalnızca ASCII'den oluşan bir `/bin/sh -c` betiğiyle (`printf` sekizlik
    /// kaçışları) yeniden kurulur ve alt sürece baytı baytına ulaşır. Diğer argümanlar eskisi gibi iletilir.
    static func rebuildArguments(executable: URL, arguments: [String], exact: [String]) -> (URL, [String]) {
        let toProtect = Set(exact.filter { !$0.allSatisfy(\.isASCII) })
        guard !toProtect.isEmpty else { return (executable, arguments) }
        func quote(_ a: String) -> String { "'" + a.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var script = "exec " + quote(executable.path)
        for a in arguments {
            if toProtect.contains(a) {
                let octal = a.utf8.map { String(format: "\\%03o", $0) }.joined()
                script += " \"$(printf '" + octal + "')\""
            } else {
                script += " " + quote(a)
            }
        }
        return (URL(fileURLWithPath: "/bin/sh"), ["-c", script])
    }

    /// Komutu çalıştırır; stdout+stderr birleşik olarak toplanır.
    /// - Parameters:
    ///   - stdin: Süreci beslemek için veri (parolalar için). nil ise stdin kapalıdır (EOF), böylece
    ///     araçlar hiçbir zaman etkileşimli girdi beklerken takılmaz.
    ///   - exactArguments: Baytı baytına (NFC bozulmadan) iletilmesi gereken argümanlar, örn. komut satırında verilen parolalar.
    ///   - capture: false ise çıktı bellekte tutulmaz (yalnızca `onOutput` ile akıtılır).
    ///   - onStart: Süreç başlayınca pid ile çağrılır (örn. açık dosya konumundan ilerleme izlemek için).
    ///   - onOutput: Her çıktı parçasında çağrılır. true dönerse süreç sonlandırılır.
    public static func run(_ executable: URL,
                           _ arguments: [String],
                           currentDirectory: URL? = nil,
                           environment: [String: String] = [:],
                           exactArguments: [String] = [],
                           stdin: Data? = nil,
                           capture: Bool = true,
                           onStart: (@Sendable (Int32) -> Void)? = nil,
                           onOutput: (@Sendable (Data) -> Bool)? = nil) async throws -> ProcessResult {
        let process = Process()
        let (launchURL, launchArgs) = rebuildArguments(executable: executable, arguments: arguments, exact: exactArguments)
        process.executableURL = launchURL
        process.arguments = launchArgs
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        } else if FileManager.default.currentDirectoryPath == "/" {
            // Finder/Dock'tan açılan uygulamanın çalışma klasörü "/" (salt okunur): araçlar geçici dosyayı orada açamasın.
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
        }

        // rar/unrar dosya adlarını yerel karakter kümesinde yazar; UTF-8 zorunlu.
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "en_US.UTF-8"
        env["LANG"] = "en_US.UTF-8"
        env.merge(environment) { _, new in new }
        process.environment = env

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = outPipe
        let inPipe: Pipe? = stdin != nil ? Pipe() : nil
        process.standardInput = inPipe ?? FileHandle.nullDevice

        let state = RunState()
        let group = DispatchGroup()

        let result: ProcessResult = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessResult, Error>) in
                group.enter() // çıktı EOF
                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                        group.leave()
                        return
                    }
                    state.append(chunk, capture: capture)
                    if let onOutput, onOutput(chunk) { state.killEarly() }
                }

                group.enter() // süreç sonu
                process.terminationHandler = { _ in group.leave() }

                do {
                    try process.run()
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    cont.resume(throwing: error)
                    return
                }
                state.attach(process)
                onStart?(process.processIdentifier)

                // Ebeveyndeki uç kopyaları kapat; aksi halde EOF hiç gelmez.
                try? outPipe.fileHandleForWriting.close()
                if let inPipe, let stdin {
                    try? inPipe.fileHandleForReading.close()
                    DispatchQueue.global().async {
                        try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
                        try? inPipe.fileHandleForWriting.close()
                    }
                }

                group.notify(queue: .global()) {
                    cont.resume(returning: ProcessResult(exitCode: process.terminationStatus,
                                                         output: state.data,
                                                         killedEarly: state.killedEarly))
                }
            }
        } onCancel: {
            state.cancel()
        }

        if state.cancelled { throw ArchiveError.cancelled }
        return result
    }
}
