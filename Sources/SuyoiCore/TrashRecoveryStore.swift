import Foundation

public struct TrashedItemRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let originalPath: String
    public let trashedPath: String
    public let category: String
    public let bytes: Int64
    public let trashedAt: Date
    public let fileIdentity: FileIdentity?
    let recovery: TrashRecoveryEvidence?

    public init(id: String, originalPath: String, trashedPath: String, category: String,
                bytes: Int64, trashedAt: Date, fileIdentity: FileIdentity?, recovery: TrashRecoveryEvidence? = nil) {
        self.id = id
        self.originalPath = originalPath
        self.trashedPath = trashedPath
        self.category = category
        self.bytes = bytes
        self.trashedAt = trashedAt
        self.fileIdentity = fileIdentity
        self.recovery = recovery
    }
}

public struct TrashRestoreOutcome: Equatable, Sendable {
    public let recordID: String
    public let restored: Bool
    public let error: String?

    public init(recordID: String, restored: Bool, error: String?) {
        self.recordID = recordID
        self.restored = restored
        self.error = error
    }
}

/// In-memory recovery history, ordered from most recently recorded to oldest.
public final class TrashRecoveryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TrashedItemRecord] = []

    public init() {}

    public func record(originalPath: String, trashedURL: URL, category: String, bytes: Int64,
                       now: Date = Date(), recovery: TrashRecoveryEvidence? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard trashedURL.isFileURL else { return }
        let boundRecovery = recovery.flatMap {
            $0.originalPath == originalPath && $0.trashedPath == trashedURL.path ? $0 : nil
        }
        let item = TrashedItemRecord(
            id: UUID().uuidString, originalPath: originalPath, trashedPath: trashedURL.path,
            category: category, bytes: bytes, trashedAt: now,
            fileIdentity: boundRecovery?.fileIdentity, recovery: boundRecovery
        )
        items.insert(item, at: 0)
        if items.count > 50 { items.removeLast(items.count - 50) }
    }

    public func records() -> [TrashedItemRecord] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    public func restore(_ item: TrashedItemRecord) -> TrashRestoreOutcome {
        // Serialize validation and moves as well as history updates so concurrent
        // requests to this store cannot restore the same item twice.
        lock.lock()
        defer { lock.unlock() }

        func failure(_ message: String) -> TrashRestoreOutcome {
            TrashRestoreOutcome(recordID: item.id, restored: false, error: message)
        }

        guard items.contains(item) else {
            return failure("The recovery record is no longer available.")
        }
        guard let recovery = item.recovery, recovery.fileIdentity == item.fileIdentity else {
            return failure("The original and trashed item could not be verified when moved.")
        }
        if let error = recovery.restore() {
            return failure(error)
        }

        items.removeAll { $0.id == item.id }
        return TrashRestoreOutcome(recordID: item.id, restored: true, error: nil)
    }
}
