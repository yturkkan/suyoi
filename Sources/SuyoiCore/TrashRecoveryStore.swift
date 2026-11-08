import Darwin
import Foundation

public struct TrashedItemRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let originalPath: String
    public let trashedPath: String
    public let category: String
    public let bytes: Int64
    public let trashedAt: Date
    public let fileIdentity: FileIdentity?

    public init(id: String, originalPath: String, trashedPath: String, category: String,
                bytes: Int64, trashedAt: Date, fileIdentity: FileIdentity?) {
        self.id = id
        self.originalPath = originalPath
        self.trashedPath = trashedPath
        self.category = category
        self.bytes = bytes
        self.trashedAt = trashedAt
        self.fileIdentity = fileIdentity
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

    public func record(originalPath: String, trashedURL: URL, category: String, bytes: Int64, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard trashedURL.isFileURL else { return }
        let item = TrashedItemRecord(
            id: UUID().uuidString, originalPath: originalPath, trashedPath: trashedURL.path,
            category: category, bytes: bytes, trashedAt: now,
            fileIdentity: FileMetadataReader().identity(at: trashedURL)
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

        guard item.originalPath.hasPrefix("/"), item.trashedPath.hasPrefix("/"),
              !item.originalPath.contains("\0"), !item.trashedPath.contains("\0") else {
            return failure("Recovery requires valid absolute file paths.")
        }
        let source = URL(fileURLWithPath: item.trashedPath)
        guard let currentIdentity = FileMetadataReader().identity(at: source) else {
            return failure("Trashed item is missing, inaccessible, or a symbolic link.")
        }
        if let expectedIdentity = item.fileIdentity, currentIdentity != expectedIdentity {
            return failure("Trashed item identity changed.")
        }

        // Unlike fileExists, lstat also detects dangling destination symlinks.
        // Any error other than a missing path prevents the move.
        var destinationMetadata = stat()
        guard lstat(item.originalPath, &destinationMetadata) != 0 else {
            return failure("The original path already exists.")
        }
        guard errno == ENOENT else {
            return failure("The original path could not be verified as available.")
        }

        do {
            // moveItem refuses existing destinations. The filesystem operation
            // remains path-based, with a narrow race after metadata validation.
            try FileManager.default.moveItem(at: source, to: URL(fileURLWithPath: item.originalPath))
            items.removeAll { $0.id == item.id }
            return TrashRestoreOutcome(recordID: item.id, restored: true, error: nil)
        } catch {
            return failure("Could not restore the trashed item to its original path.")
        }
    }
}
