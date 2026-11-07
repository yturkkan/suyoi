import Foundation
import Darwin

/// Bounded, local metadata reads only. Does not launch git or inspect agent files.
public struct ProjectResolver: ProjectResolving {
    public let homeDirectory: URL
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    public func resolveProject(at directory: URL) -> Observation<ProjectContext?> {
        var warnings: [String] = []
        var current = directory.standardizedFileURL
        var context: ProjectContext?
        for _ in 0..<8 {
            guard current.path != "/" else { break }
            guard Self.isRealDirectory(current) else {
                warnings.append("Project directory is unavailable or contains a symbolic link.")
                break
            }
            let manifestNames = ["package.json", "Package.swift", "Cargo.toml", "pyproject.toml", "go.mod"]
            let manifests = manifestNames.filter { Self.exists(current.appendingPathComponent($0)) }
            let isHome = current.path == homeDirectory.path
            let gitURL = current.appendingPathComponent(".git")
            if !manifests.isEmpty || (!isHome && Self.exists(gitURL)) {
                var name = current.lastPathComponent
                var framework: String?
                for manifest in manifests {
                    guard let text = Self.readText(current.appendingPathComponent(manifest), limit: 256 * 1024, warnings: &warnings) else { continue }
                    switch manifest {
                    case "package.json":
                        guard let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            warnings.append("Invalid package.json metadata."); continue
                        }
                        if let value = json["name"] as? String, !value.isEmpty { name = value }
                        let dependencies = (json["dependencies"] as? [String: Any] ?? [:]).merging(json["devDependencies"] as? [String: Any] ?? [:]) { first, _ in first }
                        let frameworks = [("next", "Next.js"), ("astro", "Astro"), ("nuxt", "Nuxt"), ("@remix-run/react", "Remix"),
                            ("@remix-run/node", "Remix"), ("@sveltejs/kit", "SvelteKit"), ("expo", "Expo"), ("@angular/core", "Angular"),
                            ("hono", "Hono"), ("vite", "Vite"), ("express", "Express"), ("react", "React"), ("vue", "Vue")]
                        for (key, label) in frameworks where dependencies[key] != nil {
                            let version = (dependencies[key] as? String).flatMap { Self.capture("^[~^<>=\\s]*v?([0-9]+)(?:[.xX*\\s]|$)", in: $0) }
                            framework = label + (version.map { " \($0)" } ?? "")
                            break
                        }
                    case "Package.swift": framework = "SwiftPM"
                    case "Cargo.toml":
                        name = Self.tomlName(text, sections: ["package"]) ?? name
                        framework = "Rust / Cargo"
                    case "pyproject.toml":
                        name = Self.tomlName(text, sections: ["project", "tool.poetry"]) ?? name
                        let dependencies = Self.pythonDependencies(text)
                        for (dependency, label) in [("fastapi", "FastAPI"), ("django", "Django"), ("flask", "Flask"), ("streamlit", "Streamlit")] {
                            if Self.capture("(?i)(?:^|[\\s\\\"'\\[,])(" + dependency + ")(?:[\\s\\\"'\\]<>=!~;,.]|$)", in: dependencies) != nil {
                                framework = label; break
                            }
                        }
                    case "go.mod":
                        name = Self.capture("(?m)^\\s*module\\s+[\\\"]?([^\\s\\\"]+)", in: text) ?? name
                        framework = "Go"
                    default: break
                    }
                    // One primary manifest identifies this root; fall through only on unreadable/invalid metadata.
                    break
                }
                let git = Self.gitMetadata(at: gitURL, warnings: &warnings)
                context = ProjectContext(rootPath: current.path, name: name, framework: framework,
                    gitBranch: git.branch, gitCommit: git.commit, isWorktree: git.worktree)
                break
            }
            if isHome { break }
            current.deleteLastPathComponent()
        }
        return Observation(value: context, status: warnings.isEmpty ? .complete : .partial, warnings: warnings, capturedAt: Date())
    }

    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func hasSymlinkComponent(_ url: URL) -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK { return true }
        let parent = url.deletingLastPathComponent().standardizedFileURL
        return parent.resolvingSymlinksInPath().path != parent.path
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        var info = stat()
        return !hasSymlinkComponent(url) && lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func readText(_ url: URL, limit: Int, warnings: inout [String]) -> String? {
        guard exists(url) else { return nil }
        guard !hasSymlinkComponent(url) else { warnings.append("Symbolic-link metadata rejected: \(url.lastPathComponent)."); return nil }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { warnings.append("Metadata could not be opened: \(url.lastPathComponent)."); return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= limit else {
            warnings.append("Metadata is not a bounded regular file: \(url.lastPathComponent)."); return nil
        }
        // Never read beyond the cap, even if the file grows after the initial fstat.
        var bytes = [UInt8](repeating: 0, count: limit)
        var count = 0
        while count < bytes.count {
            let amount = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress!.advanced(by: count), buffer.count - count)
            }
            if amount == 0 { break }
            if amount < 0 {
                if errno == EINTR { continue }
                warnings.append("Metadata read failed: \(url.lastPathComponent)."); return nil
            }
            count += amount
        }
        guard fstat(descriptor, &info) == 0, info.st_size <= limit,
              let text = String(bytes: bytes.prefix(count), encoding: .utf8) else {
            warnings.append("Metadata exceeded its read limit or was not UTF-8: \(url.lastPathComponent)."); return nil
        }
        return text
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func tomlName(_ text: String, sections: [String]) -> String? {
        // Prefer [project] over [tool.poetry], independent of section order.
        for target in sections {
            var section = ""
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") { section = capture("^\\[([^\\]]+)\\]", in: trimmed) ?? "" }
                if section == target, let name = capture("^name\\s*=\\s*[\\\"']([^\\\"']+)[\\\"']", in: trimmed) { return name }
            }
        }
        return nil
    }

    private static func pythonDependencies(_ text: String) -> String {
        var section = ""
        var collectingArray = false
        var result: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("[") && !collectingArray {
                section = capture("^\\[([^\\]]+)\\]", in: trimmed) ?? ""
                continue
            }
            if section == "tool.poetry.dependencies" { result.append(trimmed) }
            if section == "project" {
                if trimmed.hasPrefix("dependencies"), trimmed.contains("=") { collectingArray = true }
                if collectingArray {
                    result.append(trimmed)
                    if trimmed.contains("]") { collectingArray = false }
                }
            }
        }
        return result.joined(separator: "\n")
    }

    private static func gitMetadata(at entry: URL, warnings: inout [String]) -> (branch: String?, commit: String?, worktree: Bool) {
        guard exists(entry) else { return (nil, nil, false) }
        var gitDirectory = entry
        var worktree = false
        if !isRealDirectory(entry) {
            guard let text = readText(entry, limit: 4096, warnings: &warnings), text.hasPrefix("gitdir:") else { return (nil, nil, false) }
            let path = String(text.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { warnings.append("Empty gitdir metadata."); return (nil, nil, false) }
            gitDirectory = metadataURL(path, relativeTo: entry.deletingLastPathComponent())
            worktree = gitDirectory.path.contains("/worktrees/")
        }
        guard isRealDirectory(gitDirectory) else { warnings.append("Git metadata directory unavailable or symbolic."); return (nil, nil, worktree) }
        guard let head = readText(gitDirectory.appendingPathComponent("HEAD"), limit: 4096, warnings: &warnings)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return (nil, nil, worktree) }
        if !head.hasPrefix("ref:") { return (nil, shortSHA(head), worktree) }
        let ref = String(head.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        guard ref.hasPrefix("refs/heads/"), !ref.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }), !ref.contains("\\"), !ref.contains("\n") else {
            warnings.append("Unsupported Git HEAD reference."); return (nil, nil, worktree)
        }
        let branch = String(ref.dropFirst("refs/heads/".count))
        guard !branch.isEmpty else { warnings.append("Empty Git branch reference."); return (nil, nil, worktree) }
        var directories = [gitDirectory]
        if let common = readText(gitDirectory.appendingPathComponent("commondir"), limit: 4096, warnings: &warnings)?.trimmingCharacters(in: .whitespacesAndNewlines), !common.isEmpty {
            let commonURL = metadataURL(common, relativeTo: gitDirectory)
            if isRealDirectory(commonURL) { directories.append(commonURL) }
            else { warnings.append("Git common directory unavailable or symbolic.") }
        }
        for directory in directories {
            if let loose = readText(directory.appendingPathComponent(ref), limit: 4096, warnings: &warnings), let sha = shortSHA(loose.trimmingCharacters(in: .whitespacesAndNewlines)) { return (branch, sha, worktree) }
        }
        for directory in directories {
            if let packed = readText(directory.appendingPathComponent("packed-refs"), limit: 256 * 1024, warnings: &warnings) {
                for line in packed.components(separatedBy: .newlines) {
                    let fields = line.split(whereSeparator: \.isWhitespace)
                    if fields.count == 2, fields[1] == ref, let sha = shortSHA(String(fields[0])) { return (branch, sha, worktree) }
                }
            }
        }
        return (branch, nil, worktree)
    }

    private static func shortSHA(_ value: String) -> String? {
        guard (7...64).contains(value.count), value.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return String(value.prefix(7))
    }

    private static func metadataURL(_ path: String, relativeTo directory: URL) -> URL {
        (path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)).standardizedFileURL
    }
}
