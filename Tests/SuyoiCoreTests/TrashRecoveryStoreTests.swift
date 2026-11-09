import Foundation
import Testing
@testable import SuyoiCore

private final class TrashRecoveryFixture: @unchecked Sendable {
    let root: URL
    let original: URL
    let trashed: URL
    var evidence: TrashRecoveryEvidence?

    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("suyoi-recovery-" + UUID().uuidString, isDirectory: true)
        original = root.appendingPathComponent("project/original")
        trashed = root.appendingPathComponent("trash/trashed")
        for file in [original, trashed] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
    }

    func createTrashedFile() throws {
        try Data("recoverable contents".utf8).write(to: original)
        try trashOriginal()
    }

    func trashOriginal() throws {
        let identity = try #require(FileMetadataReader().identity(at: original))
        let pending = try #require(TrashRecoveryEvidence.prepare(original: original, expectedIdentity: identity))
        try FileManager.default.moveItem(at: original, to: trashed)
        let receipt = try #require(pending.completed(at: trashed))
        evidence = receipt
    }

    func record(in store: TrashRecoveryStore) throws -> TrashedItemRecord {
        store.record(originalPath: original.path, trashedURL: trashed, category: "cache", bytes: 20, recovery: evidence)
        return try #require(store.records().first)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite("Trash recovery store")
struct TrashRecoveryStoreTests {
    @Test("A new store has no recovery history")
    func emptyStore() {
        #expect(TrashRecoveryStore().records().isEmpty)
    }

    @Test("Recording preserves metadata and captures the trashed identity")
    func recordingMetadata() throws {
        let fixture = try TrashRecoveryFixture()
        defer { fixture.remove() }
        try fixture.createTrashedFile()
        let store = TrashRecoveryStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        store.record(originalPath: fixture.original.path, trashedURL: fixture.trashed,
                     category: "build", bytes: 1234, now: now, recovery: fixture.evidence)
        let item = try #require(store.records().first)
        #expect(store.records().count == 1)
        #expect(UUID(uuidString: item.id) != nil)
        #expect(item.originalPath == fixture.original.path)
        #expect(item.trashedPath == fixture.trashed.path)
        #expect(item.category == "build")
        #expect(item.bytes == 1234)
        #expect(item.trashedAt == now)
        #expect(item.fileIdentity == FileMetadataReader().identity(at: fixture.trashed))
        #expect(item.fileIdentity != nil)
        let encoded = try JSONEncoder().encode(item)
        #expect(try JSONDecoder().decode(TrashedItemRecord.self, from: encoded) == item)
    }

    @Test("Restoring a file preserves its contents and removes only its record")
    func restoreFile() throws {
        let fixture = try TrashRecoveryFixture()
        defer { fixture.remove() }
        try fixture.createTrashedFile()
        let store = TrashRecoveryStore()
        let unrelated = fixture.root.appendingPathComponent("other")
        store.record(originalPath: unrelated.path, trashedURL: unrelated, category: "other", bytes: 0)
        let otherItem = try #require(store.records().first)
        let item = try fixture.record(in: store)

        let outcome = store.restore(item)
        #expect(outcome == TrashRestoreOutcome(recordID: item.id, restored: true, error: nil))
        #expect(try Data(contentsOf: fixture.original) == Data("recoverable contents".utf8))
        #expect(!FileManager.default.fileExists(atPath: fixture.trashed.path))
        #expect(store.records() == [otherItem])
        #expect(!store.restore(item).restored)
    }

    @Test("Restoring a directory preserves its nested files")
    func restoreDirectory() throws {
        let fixture = try TrashRecoveryFixture()
        defer { fixture.remove() }
        let child = fixture.original.appendingPathComponent("nested/file")
        try FileManager.default.createDirectory(at: child.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("nested contents".utf8).write(to: child)
        try fixture.trashOriginal()
        let store = TrashRecoveryStore()
        let item = try fixture.record(in: store)
        #expect(store.restore(item).restored)
        #expect(try Data(contentsOf: fixture.original.appendingPathComponent("nested/file")) == Data("nested contents".utf8))
        #expect(store.records().isEmpty)
    }

    @Test("Existing original files and directories are never overwritten", arguments: [false, true])
    func originalAlreadyExists(directory: Bool) throws {
        let fixture = try TrashRecoveryFixture()
        defer { fixture.remove() }
        try fixture.createTrashedFile()
        if directory {
            try FileManager.default.createDirectory(at: fixture.original, withIntermediateDirectories: false)
        } else {
            try Data("existing contents".utf8).write(to: fixture.original)
        }
        let identity = try #require(FileMetadataReader().identity(at: fixture.original))
        let store = TrashRecoveryStore()
        let item = try fixture.record(in: store)
        let outcome = store.restore(item)
        #expect(!outcome.restored)
        #expect(outcome.recordID == item.id)
        #expect(outcome.error != nil)
        #expect(FileMetadataReader().identity(at: fixture.original) == identity)
        if !directory {
            #expect(try Data(contentsOf: fixture.original) == Data("existing contents".utf8))
        }
        #expect(try Data(contentsOf: fixture.trashed) == Data("recoverable contents".utf8))
        #expect(store.records() == [item])
    }

    @Test("A dangling symlink at the original path blocks recovery")
    func danglingDestinationSymlink() throws {
        let fixture = try TrashRecoveryFixture()
        defer { fixture.remove() }
        try fixture.createTrashedFile()
        let target = fixture.root.appendingPathComponent("missing")
        try FileManager.default.createSymbolicLink(at: fixture.original, withDestinationURL: target)
        let store = TrashRecoveryStore()
        let item = try fixture.record(in: store)
        #expect(!store.restore(item).restored)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.original.path) == target.path)
        #expect(FileManager.default.fileExists(atPath: fixture.trashed.path))
        #expect(store.records() == [item])
    }

    @Test("Replacing the trashed inode blocks recovery and retains history")
    func changedIdentity() throws {
        let fixture = try TrashRecoveryFixture()
        defer { fixture.remove() }
        try fixture.createTrashedFile()
        let store = TrashRecoveryStore()
        let item = try fixture.record(in: store)
        // Keep the old inode allocated to make replacement deterministic.
        try FileManager.default.moveItem(at: fixture.trashed, to: fixture.root.appendingPathComponent("previous"))
        try Data("replacement".utf8).write(to: fixture.trashed)
        #expect(FileMetadataReader().identity(at: fixture.trashed) != item.fileIdentity)
        let outcome = store.restore(item)
        #expect(!outcome.restored)
        #expect(outcome.error != nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.original.path))
        #expect(try Data(contentsOf: fixture.trashed) == Data("replacement".utf8))
        #expect(store.records() == [item])
    }

    @Test("Missing trashed items fail without removing history")
    func missingSource() throws {
        let fixture = try TrashRecoveryFixture()
        defer { fixture.remove() }
        let store = TrashRecoveryStore()
        let item = try fixture.record(in: store)
        #expect(item.fileIdentity == nil)
        let outcome = store.restore(item)
        #expect(!outcome.restored)
        #expect(outcome.error != nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.original.path))
        #expect(store.records() == [item])
    }

    @Test("Source symlinks are rejected even without a recorded identity", arguments: [false, true])
    func sourceSymlink(dangling: Bool) throws {
        let fixture = try TrashRecoveryFixture()
        defer { fixture.remove() }
        let target = fixture.root.appendingPathComponent("target")
        if !dangling { try Data("target contents".utf8).write(to: target) }
        try FileManager.default.createSymbolicLink(at: fixture.trashed, withDestinationURL: target)
        let store = TrashRecoveryStore()
        let item = try fixture.record(in: store)
        #expect(item.fileIdentity == nil)
        #expect(!store.restore(item).restored)
        #expect(!FileManager.default.fileExists(atPath: fixture.original.path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.trashed.path) == target.path)
        if !dangling { #expect(try Data(contentsOf: target) == Data("target contents".utf8)) }
        #expect(store.records() == [item])
    }

    @Test("A source replaced by a symlink is rejected")
    func sourceBecomesSymlink() throws {
        let fixture = try TrashRecoveryFixture()
        defer { fixture.remove() }
        try fixture.createTrashedFile()
        let store = TrashRecoveryStore()
        let item = try fixture.record(in: store)
        let previous = fixture.root.appendingPathComponent("previous")
        try FileManager.default.moveItem(at: fixture.trashed, to: previous)
        try FileManager.default.createSymbolicLink(at: fixture.trashed, withDestinationURL: previous)
        #expect(!store.restore(item).restored)
        #expect(!FileManager.default.fileExists(atPath: fixture.original.path))
        #expect(FileManager.default.fileExists(atPath: previous.path))
        #expect(store.records() == [item])
    }

    @Test("An unbound source cannot be restored after appearing at the recorded path")
    func optionalIdentity() throws {
        let fixture = try TrashRecoveryFixture()
        defer { fixture.remove() }
        let store = TrashRecoveryStore()
        let item = try fixture.record(in: store)
        #expect(item.fileIdentity == nil)
        let encoded = try JSONEncoder().encode(item)
        #expect(try JSONDecoder().decode(TrashedItemRecord.self, from: encoded) == item)
        try fixture.createTrashedFile()
        #expect(!store.restore(item).restored)
        #expect(!FileManager.default.fileExists(atPath: fixture.original.path))
        #expect(try Data(contentsOf: fixture.trashed) == Data("recoverable contents".utf8))
        #expect(store.records() == [item])
    }

    @Test("A failed move retains the source and recovery record")
    func missingDestinationParent() throws {
        let fixture = try TrashRecoveryFixture()
        defer { fixture.remove() }
        try fixture.createTrashedFile()
        let store = TrashRecoveryStore()
        let original = fixture.root.appendingPathComponent("absent/child")
        store.record(originalPath: original.path, trashedURL: fixture.trashed, category: "cache", bytes: 20)
        let item = try #require(store.records().first)
        let outcome = store.restore(item)
        #expect(!outcome.restored)
        #expect(outcome.error != nil)
        #expect(FileManager.default.fileExists(atPath: fixture.trashed.path))
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(store.records() == [item])
    }

    @Test("A replaced original directory blocks recovery and keeps the source", arguments: [false, true])
    func replacedDestinationParent(symlink: Bool) throws {
        let fixture = try TrashRecoveryFixture()
        defer { fixture.remove() }
        try fixture.createTrashedFile()
        let store = TrashRecoveryStore()
        let item = try fixture.record(in: store)
        let originalParent = fixture.original.deletingLastPathComponent()
        let previous = fixture.root.appendingPathComponent("previous")
        try FileManager.default.moveItem(at: originalParent, to: previous)
        if symlink {
            try FileManager.default.createSymbolicLink(at: originalParent, withDestinationURL: previous)
        } else {
            try FileManager.default.createDirectory(at: originalParent, withIntermediateDirectories: false)
        }
        #expect(!store.restore(item).restored)
        #expect(!FileManager.default.fileExists(atPath: fixture.original.path))
        #expect(FileManager.default.fileExists(atPath: fixture.trashed.path))
        #expect(store.records() == [item])
    }

    @Test("A symlink to the same Trash parent cannot redirect recovery")
    func symlinkToOriginalTrashParent() throws {
        let fixture = try TrashRecoveryFixture()
        defer { fixture.remove() }
        try fixture.createTrashedFile()
        let store = TrashRecoveryStore()
        let item = try fixture.record(in: store)
        let trashParent = fixture.trashed.deletingLastPathComponent()
        let previous = fixture.root.appendingPathComponent("previous")
        try FileManager.default.moveItem(at: trashParent, to: previous)
        try FileManager.default.createSymbolicLink(at: trashParent, withDestinationURL: previous)
        #expect(!store.restore(item).restored)
        #expect(!FileManager.default.fileExists(atPath: fixture.original.path))
        #expect(FileManager.default.fileExists(atPath: previous.appendingPathComponent(fixture.trashed.lastPathComponent).path))
        #expect(store.records() == [item])
    }

    @Test("Only the newest 50 records are retained in insertion order")
    func boundedCapacity() throws {
        let fixture = try TrashRecoveryFixture()
        defer { fixture.remove() }
        let store = TrashRecoveryStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<55 {
            store.record(originalPath: fixture.original.path, trashedURL: fixture.trashed,
                         category: String(index), bytes: Int64(index), now: now)
        }
        let records = store.records()
        #expect(records.count == 50)
        #expect(records.map(\.bytes) == (5..<55).reversed().map { Int64($0) })
        #expect(Set(records.map(\.id)).count == 50)
    }

    @Test("Concurrent recording and snapshots preserve the capacity bound")
    func concurrentRecording() throws {
        let fixture = try TrashRecoveryFixture()
        defer { fixture.remove() }
        try fixture.createTrashedFile()
        let store = TrashRecoveryStore()
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            store.record(originalPath: fixture.original.path, trashedURL: fixture.trashed,
                         category: "cache", bytes: Int64(index))
            #expect(store.records().count <= 50)
        }
        #expect(store.records().count == 50)
        #expect(Set(store.records().map(\.id)).count == 50)
    }

    @Test("Concurrent recovery attempts move an item exactly once")
    func concurrentRestore() async throws {
        let fixture = try TrashRecoveryFixture()
        defer { fixture.remove() }
        try fixture.createTrashedFile()
        let store = TrashRecoveryStore()
        let item = try fixture.record(in: store)
        let successCount = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<8 { group.addTask { store.restore(item).restored } }
            var count = 0
            for await restored in group where restored { count += 1 }
            return count
        }
        #expect(successCount == 1)
        #expect(try Data(contentsOf: fixture.original) == Data("recoverable contents".utf8))
        #expect(store.records().isEmpty)
    }
}
