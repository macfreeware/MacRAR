import SwiftUI
import MacRARCore

/// Ekranda ilerleme gösteren, iptal edilebilen uzun süreli işlem.
@MainActor
@Observable
final class OperationState: Identifiable {
    enum Phase: Equatable {
        case running
        case finished
        case failed(String)
    }

    let id = UUID()
    var title: String
    var fraction: Double?
    var currentFile = ""
    var log: [String] = []
    var warnings: [String] = []
    var phase: Phase = .running
    let startedAt = Date()
    var finishedAt: Date?
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var cancelAction: (() -> Void)?

    init(title: String) { self.title = title }

    var isRunning: Bool { phase == .running }

    func apply(_ snap: ProgressTracker.Snapshot) {
        if let f = snap.fraction { fraction = f }
        if !snap.currentFile.isEmpty { currentFile = snap.currentFile }
        if !snap.newMessages.isEmpty {
            log.append(contentsOf: snap.newMessages)
            if log.count > 400 { log.removeFirst(log.count - 400) }
        }
    }

    func cancel() { cancelAction?() }
}

struct AlertInfo: Identifiable {
    struct Confirm {
        var label: String
        var destructive: Bool
        var action: () -> Void
    }
    let id = UUID()
    var title: String
    var message: String
    var confirm: Confirm?
}

// MARK: - Pencere (sheet) istekleri

final class PasswordRequest: Identifiable {
    let id = UUID()
    let archiveName: String
    let wrong: Bool
    /// Doluysa: parola doğrulanınca bu adla parola yöneticisine kaydedilir.
    var saveName: String?
    private var handler: ((String?) -> Void)?

    init(archiveName: String, wrong: Bool, handler: @escaping (String?) -> Void) {
        self.archiveName = archiveName
        self.wrong = wrong
        self.handler = handler
    }

    /// Parolayı, doğrulandıktan sonra `saveName` adıyla kaydetme isteğiyle birlikte verir.
    func resolve(_ password: String?, saveName: String?) {
        self.saveName = saveName
        resolve(password)
    }

    /// Yalnızca bir kez çalışır (sheet kapanışında nil ile tekrar çağrılması güvenlidir).
    func resolve(_ password: String?) {
        let h = handler
        handler = nil
        h?(password)
    }
}

struct AddRequest: Identifiable {
    let id = UUID()
    var sources: [URL]
    var defaultName: String
    var defaultFolder: URL
    /// Doluysa mevcut arşive ekleme kipi.
    var existingArchive: URL?
    var pathInArchive: String = ""
}

struct ExtractRequest: Identifiable {
    let id = UUID()
    /// Çıkarılacak arşivler (klasör modunda seçilenler veya açık arşiv).
    var archives: [URL]
    /// Açık arşivde seçili satırlar (boşsa tümü).
    var selectedRows: [Row]
    var defaultDestination: URL
}

struct PromptRequest: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var initialText: String
    var multiline: Bool = false
    var confirmLabel: String = String(localized: "Tamam")
    var onConfirm: (String) -> Void
}

struct CompareRequest: Identifiable {
    let id = UUID()
    var firstName: String
    var secondName: String
    var result: ArchiveComparison.Result
}

enum ActiveSheet: Identifiable {
    case add(AddRequest)
    case compare(CompareRequest)
    case extract(ExtractRequest)
    case password(PasswordRequest)
    case prompt(PromptRequest)
    case info
    case passwordManager

    var id: String {
        switch self {
        case .add(let r): return "add-\(r.id)"
        case .compare(let r): return "compare-\(r.id)"
        case .extract(let r): return "extract-\(r.id)"
        case .password(let r): return "password-\(r.id)"
        case .prompt(let r): return "prompt-\(r.id)"
        case .info: return "info"
        case .passwordManager: return "passwordManager"
        }
    }
}
