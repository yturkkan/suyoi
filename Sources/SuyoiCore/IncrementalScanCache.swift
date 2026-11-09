import Darwin
import Foundation

/// A bounded cache for directory size measurements used by scan/display work only.
/// A directory's mtime does not detect all nested content changes; the TTL limits
/// staleness. Cached measurements never authorize Trash: execution must perform
/// fresh identity and safety verification independently.
public final class IncrementalDirectoryCache: @unchecked Sendable {
    public struct EntryKey: Hashable, Sendable {
        public let path: String
        public let deviceID: Int64
        public let inode: UInt64
        public let modificationTimeNanoseconds: Int64

        public init(path: String, deviceID: Int64, inode: UInt64, modificationTimeNanoseconds: Int64) {
            self.path = path
            self.deviceID = deviceID
            self.inode = inode
            self.modificationTimeNanoseconds = modificationTimeNanoseconds
        }
    }

    private struct Entry {
        let key: EntryKey
        let bytes: Int64
        let allocatedBytes: Int64?
        let recordedAt: Date
        let sequence: UInt64
    }

    private let lock = NSLock()
    private let ttlSeconds: TimeInterval
    private let maxEntries: Int
    private var entries: [String: Entry] = [:]
    private var sequence: UInt64 = 0

    public init(ttlSeconds: TimeInterval = 120, maxEntries: Int = 1024) {
        self.ttlSeconds = ttlSeconds.isFinite ? max(0, ttlSeconds) : 0
        self.maxEntries = min(1024, max(0, maxEntries))
    }

    public func cachedBytes(for url: URL, now: Date = Date()) -> Int64? {
        cachedMeasurement(for: url, now: now)?.bytes
    }

    func cachedMeasurement(for url: URL, now: Date = Date()) -> (bytes: Int64, allocatedBytes: Int64?)? {
        lock.lock()
        defer { lock.unlock() }
        let path = url.standardizedFileURL.path
        guard let entry = entries[path] else { return nil }
        let age = now.timeIntervalSince(entry.recordedAt)
        guard age >= 0, age < ttlSeconds, let key = Self.liveKey(for: url), key == entry.key else {
            entries.removeValue(forKey: path)
            return nil
        }
        return (entry.bytes, entry.allocatedBytes)
    }

    public func record(bytes: Int64, allocatedBytes: Int64? = nil, for url: URL, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard bytes >= 0, ttlSeconds > 0, maxEntries > 0,
              let key = Self.liveKey(for: url) else { return }
        entries = entries.filter {
            let age = now.timeIntervalSince($0.value.recordedAt)
            return age >= 0 && age < ttlSeconds
        }
        if entries[key.path] == nil, entries.count >= maxEntries,
           let oldest = entries.min(by: { $0.value.sequence < $1.value.sequence })?.key {
            entries.removeValue(forKey: oldest)
        }
        sequence &+= 1
        entries[key.path] = Entry(key: key, bytes: bytes, allocatedBytes: allocatedBytes,
            recordedAt: now, sequence: sequence)
    }

    public func invalidate(path: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeValue(forKey: URL(fileURLWithPath: path).standardizedFileURL.path)
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll(keepingCapacity: false)
    }

    private static func liveKey(for url: URL) -> EntryKey? {
        guard url.isFileURL else { return nil }
        let path = url.standardizedFileURL.path
        var metadata = stat()
        guard lstat(path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR else { return nil }
        let seconds = Int64(metadata.st_mtimespec.tv_sec)
        let (nanoseconds, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let (mtime, additionOverflow) = nanoseconds.addingReportingOverflow(Int64(metadata.st_mtimespec.tv_nsec))
        guard !overflow, !additionOverflow else { return nil }
        return EntryKey(path: path, deviceID: Int64(metadata.st_dev), inode: UInt64(metadata.st_ino),
                        modificationTimeNanoseconds: mtime)
    }
}
