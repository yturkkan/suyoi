import Darwin
import Foundation
import Testing
@testable import SuyoiCore

struct NativeAgentJobLauncherTests {
    @Test func launchReturnsBeforeChildCompletesAndDiscardsLargeOutput() async throws {
        let fixture = try QuotaFixture()
        defer { fixture.clean() }
        let gate = fixture.home.appendingPathComponent("release")
        let completion = fixture.home.appendingPathComponent("completed")
        let script = """
        attempt=0
        while [ ! -f release ] && [ "$attempt" -lt 80 ]; do
            /bin/sleep 0.05
            attempt=$((attempt + 1))
        done
        [ -f release ] || exit 1
        [ "$PATH" = /opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin ] || exit 2
        /bin/dd if=/dev/zero bs=1048576 count=8 2>/dev/null || exit 3
        /bin/dd if=/dev/zero bs=1048576 count=8 >&2 2>/dev/null || exit 4
        printf '%s' "$$" > finished
        /bin/mv finished completed
        """

        // The launcher itself can go out of scope while its owned child runs.
        try NativeAgentJobLauncher(homeDirectory: fixture.home, baseEnvironment: [:]).launch(
            executable: "/bin/sh", arguments: ["-c", script], workingDirectory: fixture.home
        )
        try Data().write(to: gate)
        try await waitUntil { FileManager.default.fileExists(atPath: completion.path) }
        let pid = try #require(Int32(String(contentsOf: completion, encoding: .utf8)))
        try #require(pid > 1)
        try await waitUntil { Darwin.kill(pid, 0) == -1 && errno == ESRCH }
    }

    @Test func providerStoresAreScopedToTheChildEnvironment() throws {
        let fixture = try QuotaFixture()
        defer { fixture.clean() }
        let catalog = NativeSessionCatalog(homeDirectory: fixture.home)
        let baseEnv = [
            "OPENAI_API_KEY": "sk-openai-test",
            "ANTHROPIC_API_KEY": "sk-ant-test",
            "HTTPS_PROXY": "http://127.0.0.1:8080",
            "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib",
            "NODE_OPTIONS": "--require /tmp/evil.js",
            "PYTHONPATH": "/tmp/evil",
            "BASH_ENV": "/tmp/evil.sh",
            "HTTP_PROXY": "bad\ncontrol"
        ]
        let codex = NativeAgentJobLauncher.environment(for: "/tools/codex", catalog: catalog, baseEnvironment: baseEnv)
        let openCode = NativeAgentJobLauncher.environment(for: "/tools/opencode", catalog: catalog, baseEnvironment: [:])
        let claude = NativeAgentJobLauncher.environment(for: "/tools/claude", catalog: catalog, baseEnvironment: baseEnv)

        #expect(codex["HOME"] == catalog.homeDirectory.path)
        #expect(codex["CODEX_HOME"] == catalog.codexHome.path)
        #expect(codex["CODEX_SQLITE_HOME"] == catalog.codexHome.path)
        #expect(codex["OPENAI_API_KEY"] == "sk-openai-test")
        #expect(codex["ANTHROPIC_API_KEY"] == nil)
        #expect(codex["HTTPS_PROXY"] == "http://127.0.0.1:8080")
        #expect(codex["HTTP_PROXY"] == nil)
        #expect(codex["DYLD_INSERT_LIBRARIES"] == nil)
        #expect(codex["NODE_OPTIONS"] == nil)
        #expect(codex["PYTHONPATH"] == nil)
        #expect(codex["BASH_ENV"] == nil)
        #expect(codex["OPENCODE_DB"] == nil)

        #expect(openCode["OPENCODE_DB"] == catalog.openCodeDB.path)
        #expect(openCode["CODEX_HOME"] == nil)
        #expect(Set(openCode.keys) == ["HOME", "PATH", "LC_ALL", "GIT_OPTIONAL_LOCKS", "OPENCODE_DB"])

        #expect(claude["CLAUDE_CONFIG_DIR"] == catalog.claudeHome.path)
        #expect(claude["ANTHROPIC_API_KEY"] == "sk-ant-test")
        #expect(claude["OPENAI_API_KEY"] == nil)

        let bunBin = fixture.home.appendingPathComponent(".bun/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bunBin, withIntermediateDirectories: true)
        let withUserBin = NativeAgentJobLauncher.environment(for: "/tools/claude", catalog: catalog, baseEnvironment: [:])
        #expect(withUserBin["PATH"]?.hasPrefix(catalog.homeDirectory.appendingPathComponent(".bun/bin").path + ":") == true)
    }

    @Test func launchRejectsRelativeExecutablesAndMissingDirectories() throws {
        let fixture = try QuotaFixture()
        defer { fixture.clean() }
        let launcher = NativeAgentJobLauncher(homeDirectory: fixture.home, baseEnvironment: [:])
        #expect(throws: NativeAgentJobLauncher.Error.relativeExecutable) {
            try launcher.launch(executable: "true", arguments: [], workingDirectory: fixture.home)
        }
        #expect(throws: NativeAgentJobLauncher.Error.invalidWorkingDirectory) {
            try launcher.launch(executable: "/usr/bin/true", arguments: [], workingDirectory: fixture.home.appendingPathComponent("absent"))
        }
        #expect(throws: NativeAgentJobLauncher.Error.launchFailed) {
            try launcher.launch(executable: fixture.home.appendingPathComponent("absent").path, arguments: [], workingDirectory: fixture.home)
        }
        #expect(throws: NativeAgentJobLauncher.Error.startupExited(7)) {
            try launcher.launch(executable: "/bin/sh", arguments: ["-c", "exit 7"], workingDirectory: fixture.home)
        }
        try launcher.launch(executable: "/usr/bin/true", arguments: [], workingDirectory: fixture.home)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(6)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition())
    }
}
