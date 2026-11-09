import Darwin
import Foundation

/// Filesystem evidence captured at the move, before handing its outcome to the UI.
public struct TrashRecoveryEvidence: Codable, Equatable, Sendable {
    public let fileIdentity: FileIdentity
    let originalPath: String
    let trashedPath: String
    private let originalParents: [FileIdentity]
    private let trashedParents: [FileIdentity]

    struct Preparation {
        let originalPath: String
        let fileIdentity: FileIdentity
        let originalParents: [FileIdentity]

        func completed(at destination: URL?) -> TrashRecoveryEvidence? {
            guard let destination, destination.isFileURL,
                  let originalStillPresent = TrashRecoveryEvidence.withParent(of: originalPath, body: { parent, name, parents in
                      parents != originalParents || Self.itemIdentity(at: parent, name: name) == fileIdentity
                  }), !originalStillPresent else { return nil }
            return TrashRecoveryEvidence.withParent(of: destination.path) { parent, name, parents in
                guard Self.itemIdentity(at: parent, name: name) == fileIdentity else { return nil }
                return TrashRecoveryEvidence(fileIdentity: fileIdentity, originalPath: originalPath,
                    trashedPath: destination.path, originalParents: originalParents, trashedParents: parents)
            } ?? nil
        }

        fileprivate static func itemIdentity(at parent: Int32, name: String) -> FileIdentity? {
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
            let type = info.st_mode & S_IFMT
            guard type == S_IFREG || type == S_IFDIR else { return nil }
            return FileIdentity(device: info.st_dev, inode: UInt64(info.st_ino))
        }
    }

    static func prepare(original: URL, expectedIdentity: FileIdentity) -> Preparation? {
        guard original.isFileURL else { return nil }
        return withParent(of: original.path) { parent, name, parents in
            guard Preparation.itemIdentity(at: parent, name: name) == expectedIdentity else { return nil }
            return Preparation(originalPath: original.path, fileIdentity: expectedIdentity, originalParents: parents)
        } ?? nil
    }

    func restore() -> String? {
        Self.withParent(of: originalPath) { originalParent, originalName, liveOriginalParents -> String? in
            guard liveOriginalParents == originalParents else {
                return "The original directory or one of its parents changed."
            }
            let result = Self.withParent(of: trashedPath) { trashParent, trashName, liveTrashParents -> String? in
                guard liveTrashParents == trashedParents,
                      Preparation.itemIdentity(at: trashParent, name: trashName) == fileIdentity else {
                    return "The trashed item or one of its parents changed."
                }
                // Parent descriptors pin the verified directories. RENAME_EXCL
                // rejects even a destination created after the identity checks.
                guard renameatx_np(trashParent, trashName, originalParent, originalName, UInt32(RENAME_EXCL)) == 0 else {
                    return errno == EEXIST ? "The original path already exists."
                        : "Could not restore the trashed item to its original path."
                }
                return nil
            }
            return result ?? "The Trash directory is missing, inaccessible, or contains a symbolic link."
        } ?? "The original directory is missing, inaccessible, or contains a symbolic link."
    }

    private static func withParent<T>(of path: String, body: (Int32, String, [FileIdentity]) -> T) -> T? {
        guard path.hasPrefix("/"), path != "/", !path.contains("\0"),
              URL(fileURLWithPath: path).standardizedFileURL.path == path else { return nil }
        var physicalPath = path
        // macOS publishes these system-owned aliases at the volume root.
        if let alias = ["/var", "/tmp", "/etc"].first(where: { path.hasPrefix($0 + "/") }) {
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: alias),
                  target == "private" + alias || target == "/private" + alias else { return nil }
            physicalPath = "/private" + path
        }
        let components = physicalPath.split(separator: "/").map(String.init)
        guard let name = components.last else { return nil }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var descriptor = open("/", flags)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var parents: [FileIdentity] = []
        for component in components.dropLast() {
            let next = openat(descriptor, component, flags)
            guard next >= 0 else { return nil }
            close(descriptor)
            descriptor = next
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { return nil }
            parents.append(FileIdentity(device: info.st_dev, inode: UInt64(info.st_ino)))
        }
        return body(descriptor, name, parents)
    }
}
