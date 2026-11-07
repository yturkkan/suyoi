import Foundation
import Testing
@testable import SuyoiCore

@Suite("Bounded project metadata resolution")
struct ProjectResolverTests {
    private func fixture(_ body: (URL, ProjectResolver) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("suyoi-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root, ProjectResolver(homeDirectory: root.appendingPathComponent("home", isDirectory: true)))
    }
    private func write(_ text: String, _ path: String, at root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func nextAndViteManifests() throws {
        try fixture { root, resolver in
            try write(#"{"name":"next-app","dependencies":{"next":"^16.1.0","react":"19.0.0"},"devDependencies":{"vite":"7.0.0"}}"#, "next/package.json", at: root)
            try write(#"{"name":"vite-app","devDependencies":{"vite":"~7.1.2"},"dependencies":{"vue":"^3.0.0"}}"#, "vite/package.json", at: root)
            let next = resolver.resolveProject(at: root.appendingPathComponent("next"))
            #expect(next.status == .complete)
            #expect(next.value?.name == "next-app")
            #expect(next.value?.framework == "Next.js 16")
            #expect(resolver.resolveProject(at: root.appendingPathComponent("vite")).value?.framework == "Vite 7")
        }
    }

    @Test func frameworksAndMissingVersion() throws {
        try fixture { root, resolver in
            let frameworks = ["astro": "Astro", "nuxt": "Nuxt", "@remix-run/react": "Remix", "@sveltejs/kit": "SvelteKit",
                "expo": "Expo", "@angular/core": "Angular", "hono": "Hono", "express": "Express", "react": "React", "vue": "Vue"]
            for (key, label) in frameworks {
                try write("{\"dependencies\":{\"\(key)\":\"workspace:*\"}}", "package.json", at: root)
                #expect(resolver.resolveProject(at: root).value?.framework == label)
            }
        }
    }

    @Test func cargoPythonSwiftAndGo() throws {
        try fixture { root, resolver in
            try write("[package]\nname = \"rust-app\"\nversion = \"1.0.0\"\n", "cargo/Cargo.toml", at: root)
            let cargo = resolver.resolveProject(at: root.appendingPathComponent("cargo"))
            #expect(cargo.value?.name == "rust-app")
            #expect(cargo.value?.framework == "Rust / Cargo")
            try write("[project]\nname = 'python-app'\ndependencies = [\n 'fastapi>=0.100',\n 'uvicorn'\n]\n", "python/pyproject.toml", at: root)
            let python = resolver.resolveProject(at: root.appendingPathComponent("python"))
            #expect(python.value?.name == "python-app")
            #expect(python.value?.framework == "FastAPI")
            for (dependency, label) in [("django", "Django"), ("flask", "Flask"), ("streamlit", "Streamlit")] {
                try write("[tool.poetry]\nname = 'poetry-app'\n[tool.poetry.dependencies]\n\(dependency) = '^1.0'\n", "poetry/pyproject.toml", at: root)
                let value = resolver.resolveProject(at: root.appendingPathComponent("poetry")).value
                #expect(value?.name == "poetry-app")
                #expect(value?.framework == label)
            }
            try write("// swift-tools-version: 6.0\n", "swift/Package.swift", at: root)
            #expect(resolver.resolveProject(at: root.appendingPathComponent("swift")).value?.framework == "SwiftPM")
            try write("module example.com/team/service\n\ngo 1.24\n", "go/go.mod", at: root)
            let go = resolver.resolveProject(at: root.appendingPathComponent("go")).value
            #expect(go?.name == "example.com/team/service")
            #expect(go?.framework == "Go")
        }
    }

    @Test func normalBranchAndDetachedHead() throws {
        try fixture { root, resolver in
            try write("ref: refs/heads/feature/context\n", ".git/HEAD", at: root)
            try write("abcdef0123456789abcdef0123456789abcdef01\n", ".git/refs/heads/feature/context", at: root)
            let branch = resolver.resolveProject(at: root)
            #expect(branch.value?.gitBranch == "feature/context")
            #expect(branch.value?.gitCommit == "abcdef0")
            #expect(branch.value?.isWorktree == false)
            try write("1234567890abcdef1234567890abcdef12345678\n", ".git/HEAD", at: root)
            let detached = resolver.resolveProject(at: root).value
            #expect(detached?.gitBranch == nil)
            #expect(detached?.gitCommit == "1234567")
        }
    }

    @Test func worktreeAndPackedCommonRefs() throws {
        try fixture { root, resolver in
            try write("gitdir: ../main/.git/worktrees/feat\n", "checkout/.git", at: root)
            try write("ref: refs/heads/feat\n", "main/.git/worktrees/feat/HEAD", at: root)
            try write("../..\n", "main/.git/worktrees/feat/commondir", at: root)
            try write("# pack-refs with: peeled fully-peeled\n0123456789abcdef0123456789abcdef01234567 refs/heads/feat\n", "main/.git/packed-refs", at: root)
            let worktree = resolver.resolveProject(at: root.appendingPathComponent("checkout"))
            #expect(worktree.status == .complete)
            #expect(worktree.value?.isWorktree == true)
            #expect(worktree.value?.gitBranch == "feat")
            #expect(worktree.value?.gitCommit == "0123456")
            try write("fedcba9876543210fedcba9876543210fedcba98\n", "main/.git/refs/heads/feat", at: root)
            #expect(resolver.resolveProject(at: root.appendingPathComponent("checkout")).value?.gitCommit == "fedcba9")
        }
    }

    @Test func upwardTraversalHomeAndDepthLimits() throws {
        try fixture { root, _ in
            let home = root.appendingPathComponent("home", isDirectory: true)
            let resolver = ProjectResolver(homeDirectory: home)
            try write("ref: refs/heads/main\n", "home/.git/HEAD", at: root)
            let child = home.appendingPathComponent("src", isDirectory: true)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            #expect(resolver.resolveProject(at: child).value == nil)
            try write("{}", "home/package.json", at: root)
            #expect(resolver.resolveProject(at: child).value?.rootPath == home.path)
            try write("{}", "project/package.json", at: root)
            let project = root.appendingPathComponent("project", isDirectory: true)
            let seven = (0..<7).reduce(project) { url, i in url.appendingPathComponent("d\(i)", isDirectory: true) }
            let eight = seven.appendingPathComponent("eighth", isDirectory: true)
            try FileManager.default.createDirectory(at: eight, withIntermediateDirectories: true)
            #expect(resolver.resolveProject(at: seven).value?.rootPath == project.path)
            #expect(resolver.resolveProject(at: eight).value == nil)
            #expect(resolver.resolveProject(at: URL(fileURLWithPath: "/")).value == nil)
        }
    }

    @Test func unsafeAndOversizedMetadataIsPartial() throws {
        try fixture { root, resolver in
            try write(#"{"name":"outside"}"#, "outside.json", at: root)
            let project = root.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let manifest = project.appendingPathComponent("package.json")
            try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: root.appendingPathComponent("outside.json"))
            let symbolic = resolver.resolveProject(at: project)
            #expect(symbolic.status == .partial)
            #expect(symbolic.value?.name == "project")
            try FileManager.default.removeItem(at: manifest)
            try String(repeating: "a", count: 256 * 1024 + 1).write(to: manifest, atomically: true, encoding: .utf8)
            #expect(resolver.resolveProject(at: project).status == .partial)
            try write("{broken", "project/package.json", at: root)
            #expect(resolver.resolveProject(at: project).status == .partial)
            let alias = root.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: project)
            #expect(resolver.resolveProject(at: alias).status == .partial)
        }
    }

    @Test func invalidGitRefAndHeadLimits() throws {
        try fixture { root, resolver in
            try write("ref: refs/heads/../../secret\n", ".git/HEAD", at: root)
            let invalid = resolver.resolveProject(at: root)
            #expect(invalid.status == .partial)
            #expect(invalid.value?.gitCommit == nil)
            try write(String(repeating: "a", count: 4097), ".git/HEAD", at: root)
            #expect(resolver.resolveProject(at: root).status == .partial)
        }
    }
}
