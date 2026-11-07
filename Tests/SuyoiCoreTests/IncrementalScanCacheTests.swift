import Foundation
import Testing
@testable import SuyoiCore

@Suite("Incremental directory cache")
struct IncrementalScanCacheTests {
    @Test("Unchanged directory returns its recorded size")
    func cacheHit() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = IncrementalDirectoryCache()
        let now = Date()
        cache.record(bytes: 1234, for: directory, now: now)
        #expect(cache.cachedBytes(for: directory, now: now.addingTimeInterval(1)) == 1234)
    }

    @Test("Directory mtime changes invalidate measurements")
    func modificationTimeMiss() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = IncrementalDirectoryCache()
        let now = Date()
        cache.record(bytes: 1234, for: directory, now: now)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(10)], ofItemAtPath: directory.path)
        #expect(cache.cachedBytes(for: directory, now: now) == nil)
    }

    @Test("Replacing a directory invalidates measurements even with the same mtime")
    func inodeReplacementMiss() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("candidate", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let modificationDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: directory.path)
        let cache = IncrementalDirectoryCache()
        cache.record(bytes: 1234, for: directory)
        // Keep the old inode allocated while creating its replacement.
        try FileManager.default.moveItem(at: directory, to: parent.appendingPathComponent("previous"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: directory.path)
        #expect(cache.cachedBytes(for: directory) == nil)
    }

    @Test("Expired and future-dated entries are unavailable")
    func ttlExpiration() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = IncrementalDirectoryCache(ttlSeconds: 120)
        let now = Date()
        cache.record(bytes: 1234, for: directory, now: now)
        #expect(cache.cachedBytes(for: directory, now: now.addingTimeInterval(119)) == 1234)
        #expect(cache.cachedBytes(for: directory, now: now.addingTimeInterval(120)) == nil)
        cache.record(bytes: 1234, for: directory, now: now)
        #expect(cache.cachedBytes(for: directory, now: now.addingTimeInterval(-1)) == nil)
    }

    @Test("Invalidate removes one path and clear removes all paths")
    func invalidation() throws {
        let first = try temporaryDirectory()
        let second = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let cache = IncrementalDirectoryCache()
        cache.record(bytes: 1, for: first)
        cache.record(bytes: 2, for: second)
        cache.invalidate(path: first.path)
        #expect(cache.cachedBytes(for: first) == nil)
        #expect(cache.cachedBytes(for: second) == 2)
        cache.clear()
        #expect(cache.cachedBytes(for: second) == nil)
    }

    @Test("Capacity evicts the oldest entry and never exceeds 1024")
    func boundedCapacity() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let cache = IncrementalDirectoryCache(maxEntries: 2048)
        let now = Date()
        var directories: [URL] = []
        for index in 0...1024 {
            let directory = parent.appendingPathComponent(String(index), isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            cache.record(bytes: Int64(index), for: directory, now: now)
            directories.append(directory)
        }
        #expect(cache.cachedBytes(for: directories[0], now: now) == nil)
        #expect(cache.cachedBytes(for: directories[1], now: now) == 1)
        #expect(cache.cachedBytes(for: directories[1024], now: now) == 1024)
    }

    @Test("Symlinks, negative measurements and disabled caches are not cached")
    func invalidInputs() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("directory", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let link = parent.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        let cache = IncrementalDirectoryCache()
        cache.record(bytes: 1, for: link)
        cache.record(bytes: -1, for: directory)
        #expect(cache.cachedBytes(for: link) == nil)
        #expect(cache.cachedBytes(for: directory) == nil)
        for disabled in [IncrementalDirectoryCache(ttlSeconds: -1), IncrementalDirectoryCache(maxEntries: 0)] {
            disabled.record(bytes: 1, for: directory)
            #expect(disabled.cachedBytes(for: directory) == nil)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("suyoi-cache-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
