import Testing
@testable import SuyoiCore

@Suite("Read-only CLI options")
struct CLIOptionsTests {
    @Test func supportedCommands() throws {
        #expect(try CLIOptions(arguments: []) == .gui)
        #expect(try CLIOptions(arguments: ["--snapshot"]) == .snapshot)
        #expect(try CLIOptions(arguments: ["--scan-cleanup"]) == .scanCleanup(path: nil))
        #expect(try CLIOptions(arguments: ["--scan-cleanup", "/tmp/project with spaces"]) == .scanCleanup(path: "/tmp/project with spaces"))
        #expect(try CLIOptions(arguments: ["--scan-cleanup", "~/Developer"]) == .scanCleanup(path: "~/Developer"))
        #expect(try CLIOptions(arguments: ["--agent-storage"]) == .agentStorage)
        #expect(try CLIOptions(arguments: ["--quotas"]) == .quotas)
        #expect(try CLIOptions(arguments: ["--hook-bridge"]) == .hookBridge)
        #expect(try CLIOptions(arguments: ["--help"]) == .help)
    }

    @Test(arguments: [
        ["--quotas", "path"], ["--quotas", "--snapshot"], ["--unknown"], ["project"], ["--snapshot", "--scan-cleanup"],
        ["--snapshot", "--snapshot"], ["--help", "--snapshot"],
        ["--hook-bridge", "path"], ["--hook-bridge", "--snapshot"], ["--hook-bridge", ""],
        ["--scan-cleanup", "--agent-storage"], ["--scan-cleanup", "--unknown"],
        ["--scan-cleanup", "one", "two"], ["--scan-cleanup", ""],
        ["--agent-storage", "path"], ["--snapshot", "path"], ["--scan-cleanup", "-x"]
    ])
    func rejectsUnknownConflictingOrExtraArguments(_ arguments: [String]) {
        #expect(throws: CLIOptions.ParseError.invalidArguments) {
            try CLIOptions(arguments: arguments)
        }
    }

    @Test func helpIncludesEveryCommandAndReadOnlyBoundary() {
        for command in ["--snapshot", "--scan-cleanup", "--agent-storage", "--quotas", "--hook-bridge", "--help"] {
            #expect(CLIOptions.usage.contains(command))
        }
        #expect(CLIOptions.usage.contains("read-only"))
        #expect(CLIOptions.usage.contains("~/Developer"))
    }
}
