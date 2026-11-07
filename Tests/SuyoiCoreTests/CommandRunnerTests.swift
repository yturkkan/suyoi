import Foundation
import Testing
@testable import SuyoiCore

@Test func commandRejectsRelativeExecutable() {
    #expect(throws: CommandRunner.Error.self) { try CommandRunner().run(CommandRequest(executable: "bin/echo")) }
}

@Test func commandCapturesBothStreams() throws {
    let result = try CommandRunner().run(CommandRequest(executable: "/bin/sh", arguments: ["-c", "printf out; printf err >&2"]))
    #expect(result.exitCode == 0)
    #expect(result.stdoutText == "out")
    #expect(result.stderrText == "err")
    #expect(!result.timedOut && !result.truncated)
}

@Test func commandEnforcesTimeout() throws {
    let result = try CommandRunner().run(CommandRequest(executable: "/bin/sleep", arguments: ["5"], timeout: 0.05))
    #expect(result.timedOut)
}

@Test func commandEnforcesCombinedOutputCap() throws {
    let result = try CommandRunner().run(CommandRequest(executable: "/usr/bin/yes", maximumOutputBytes: 1024))
    #expect(result.truncated)
    #expect(result.stdout.count + result.stderr.count == 1024)
}
