import Foundation
import Darwin

/// Metadata-only traversal; these checks are not a substitute for action-time revalidation.
public struct FileMetadataReader: Sendable {
    public init() {}

    public func identity(at url: URL) -> FileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK else { return nil }
        return FileIdentity(device: info.st_dev, inode: UInt64(info.st_ino))
    }

    /// The base itself may be a canonicalized trusted root; every relative component must be real.
    public func canonicalPath(_ target: URL, relativeTo base: URL) -> URL? {
        let root = base.standardizedFileURL.resolvingSymlinksInPath()
        let path = target.standardizedFileURL.path
        guard path == root.path || path.hasPrefix(root.path == "/" ? "/" : root.path + "/") else { return nil }
        var current = root
        guard identity(at: current) != nil else { return nil }
        let relative = String(path.dropFirst(root.path == "/" ? 1 : root.path.count))
        for part in relative.split(separator: "/") {
            current.appendPathComponent(String(part))
            guard identity(at: current) != nil else { return nil }
        }
        guard current.resolvingSymlinksInPath().standardizedFileURL.path == path else { return nil }
        return current
    }

    struct Measurement {
        var bytes: Int64 = 0
        var allocatedBytes: Int64 = 0
        var allocatedAvailable = true
        var entries = 0
        var partial = false
        var warnings: [String] = []
    }

    func measure(_ directory: URL, entryLimit: Int, deadline: TimeInterval, excluding: (URL) -> Bool = { _ in false }) -> Measurement {
        var result = Measurement()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path,
              identity(at: directory) != nil,
              let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in
                  result.partial = true
                  if result.warnings.count < 20 { result.warnings.append("Could not enumerate cache contents.") }
                  return true
              }) else {
            result.partial = true
            result.warnings.append("Could not enumerate \(directory.lastPathComponent).")
            return result
        }
        while true {
            guard result.entries < max(0, entryLimit), ProcessInfo.processInfo.systemUptime < deadline else {
                result.partial = true
                break
            }
            guard let file = enumerator.nextObject() as? URL else { break }
            result.entries += 1
            if excluding(file) {
                enumerator.skipDescendants()
                result.partial = true
                if !result.warnings.contains("Sensitive paths were excluded from measurement.") {
                    result.warnings.append("Sensitive paths were excluded from measurement.")
                }
                continue
            }
            guard canonicalPath(file, relativeTo: directory) != nil else { enumerator.skipDescendants(); continue }
            do {
                let values = try file.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                if values.isRegularFile == true {
                    let size = Int64(max(0, values.fileSize ?? 0))
                    result.bytes = result.bytes > Int64.max - size ? Int64.max : result.bytes + size
                    if let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize {
                        let amount = Int64(max(0, allocated))
                        result.allocatedBytes = result.allocatedBytes > Int64.max - amount ? Int64.max : result.allocatedBytes + amount
                    } else { result.allocatedAvailable = false }
                }
            } catch {
                result.partial = true
                if result.warnings.count < 20 { result.warnings.append("Could not read metadata in \(directory.lastPathComponent).") }
            }
        }
        return result
    }
}
