import Foundation
import Testing
@testable import SuyoiCore

@Suite("Bounded process argument parsing")
struct ProcessArgumentsReaderTests {
    func fixture(_ args: [String], environment: [String] = []) -> Data {
        var count = Int32(args.count).littleEndian
        var data = withUnsafeBytes(of: &count) { Data($0) }
        data.append(contentsOf: "/usr/bin/runtime\0\0\0".utf8)
        for value in args + environment { data.append(contentsOf: (value + "\0").utf8) }
        return data
    }
    @Test func wrappersAndDirectBinaries() {
        let cases = [("node", "/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js", "Claude Code"),
                     ("bun", "/opt/@openai/codex/bin/codex.js", "Codex"),
                     ("deno", "/bin/opencode-cli", "OpenCode"),
                     ("python3.12", "/bin/aider", "Aider"),
                     ("node", "@google/gemini-cli", "Gemini CLI")]
        for (runtime, script, name) in cases {
            let result = ProcessArgumentsReader.parseInvocation(from: fixture([runtime, script, "--prompt", "secret"]), executablePath: "/bin/" + runtime)
            #expect(result?.agentName == name)
            #expect(result?.runtime == runtime)
        }
        #expect(ProcessArgumentsReader.parseInvocation(from: fixture(["python3", "-m", "aider"]), executablePath: "/bin/python3")?.entrypoint == "aider")
        #expect(ProcessArgumentsReader.parseInvocation(from: Data(), executablePath: "/bin/codex")?.agentName == "Codex")
    }
    @Test func ignoresFlagsEnvironmentAndMalformedBuffers() {
        for args in [["node", "-p", "codex"], ["node", "other.js", "--prompt", "claude"], ["node", "-m", "aider"], ["python", "-c", "aider"]] {
            #expect(ProcessArgumentsReader.parseInvocation(from: fixture(args), executablePath: "/bin/" + args[0]) == nil)
        }
        #expect(ProcessArgumentsReader.parseInvocation(from: fixture(["node"], environment: ["codex"]), executablePath: "/bin/node") == nil)
        #expect(ProcessArgumentsReader.parseInvocation(from: Data([1, 0, 0]), executablePath: "/bin/node") == nil)
        var truncated = fixture(["node", "codex"]); truncated.removeLast()
        #expect(ProcessArgumentsReader.parseInvocation(from: truncated, executablePath: "/bin/node") == nil)
        #expect(ProcessArgumentsReader.parseInvocation(from: fixture(["git", "-m", "codex"]), executablePath: "/bin/git") == nil)
        var rawExec = Int32(1).littleEndian
        var execData = withUnsafeBytes(of: &rawExec) { Data($0) }
        execData.append(contentsOf: "/Applications/Example.app/Contents/Resources/../MacOS/Example\0".utf8)
        #expect(ProcessArgumentsReader.parseExecutablePath(from: execData) == "/Applications/Example.app/Contents/MacOS/Example")
    }
}
