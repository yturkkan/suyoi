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

    /// Returns nil only after a complete metadata check of the directory about to be trashed.
    func trashDescendantBlocker(at directory: URL, expectedIdentity: FileIdentity, homeDirectory: URL) -> String? {
        let entryLimit = 250_000
        let depthLimit = 64
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        let incomplete = "Candidate contents could not be fully checked for sensitive paths"
        let directoryFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
        var entries = 0

        func openRoot() -> Int32 {
            let path = directory.path
            let descriptor = open(path, directoryFlags)
            // Foundation preserves these macOS aliases in otherwise canonical URLs.
            // Validate the literal link, then open its physical path without following links.
            guard descriptor < 0, errno == ELOOP,
                  let alias = ["/var", "/tmp", "/etc"].first(where: { path.hasPrefix($0 + "/") }),
                  let target = try? FileManager.default.destinationOfSymbolicLink(atPath: alias),
                  target == "private" + alias || target == "/private" + alias else { return descriptor }
            return open("/private" + path, directoryFlags)
        }

        func unchanged(_ before: stat, _ after: stat) -> Bool {
            before.st_dev == after.st_dev && before.st_ino == after.st_ino
                && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
                && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
                && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
                && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        }

        // Each child is checked relative to an already-open directory. Only real
        // directories are opened; symlink entries are checked by name alone.
        func inspect(_ descriptor: Int32, path: URL, before: stat, depth: Int) -> String? {
            guard let stream = fdopendir(descriptor) else {
                close(descriptor)
                return incomplete
            }
            defer { closedir(stream) }
            while ProcessInfo.processInfo.systemUptime < deadline {
                errno = 0
                guard let entry = readdir(stream) else {
                    var after = stat()
                    return errno == 0 && fstat(descriptor, &after) == 0 && unchanged(before, after) ? nil : incomplete
                }
                let name = withUnsafeBytes(of: &entry.pointee.d_name) { bytes in
                    bytes.baseAddress.flatMap { String(validatingUTF8: $0.assumingMemoryBound(to: CChar.self)) }
                }
                guard let name else { return incomplete }
                if name == "." || name == ".." { continue }
                guard entries < entryLimit else { return incomplete }
                entries += 1
                let childPath = path.appendingPathComponent(name, isDirectory: false)
                if AgentCacheCatalog.isForbiddenPath(childPath, homeDirectory: homeDirectory) {
                    return "Candidate contains a forbidden or sensitive path"
                }
                var child = stat()
                guard fstatat(descriptor, name, &child, AT_SYMLINK_NOFOLLOW) == 0,
                      child.st_dev == before.st_dev, child.st_ino == entry.pointee.d_ino else { return incomplete }
                if (child.st_mode & S_IFMT) != S_IFDIR { continue }
                guard depth < depthLimit else { return incomplete }
                let childDescriptor = openat(descriptor, name, directoryFlags)
                guard childDescriptor >= 0 else { return incomplete }
                var opened = stat()
                guard fstat(childDescriptor, &opened) == 0, unchanged(child, opened) else {
                    close(childDescriptor)
                    return incomplete
                }
                if let blocker = inspect(childDescriptor, path: childPath, before: opened, depth: depth + 1) {
                    return blocker
                }
            }
            return incomplete
        }

        let descriptor = openRoot()
        guard descriptor >= 0 else { return incomplete }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              FileIdentity(device: before.st_dev, inode: UInt64(before.st_ino)) == expectedIdentity else {
            close(descriptor)
            return incomplete
        }
        if let blocker = inspect(descriptor, path: directory, before: before, depth: 0) { return blocker }

        // The final Trash call still uses a path. Check that it resolves to the
        // inspected root without symlinks after walking its contents.
        let finalDescriptor = openRoot()
        guard finalDescriptor >= 0 else { return incomplete }
        defer { close(finalDescriptor) }
        var after = stat()
        guard fstat(finalDescriptor, &after) == 0, unchanged(before, after),
              ProcessInfo.processInfo.systemUptime < deadline else { return incomplete }
        return nil
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
