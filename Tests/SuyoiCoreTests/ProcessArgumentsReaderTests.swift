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
    @Test func expandedDirectAndWrappedInvocations() {
        let cases: [([String], String, String)] = [
            (["antigravity", "agy"], "Antigravity CLI", "antigravity"),
            (["hermes", "hermes-agent", "hermes_cli"], "Hermes Agent", "hermes"),
            (["qwen"], "Qwen Code", "qwen"),
            (["kimi", "kimi-cli"], "Kimi CLI", "kimi"),
            (["openclaw"], "OpenClaw", "openclaw"),
            (["omp", "oh-my-pi"], "Oh My Pi", "omp"),
            (["codebuddy"], "CodeBuddy", "codebuddy"),
            (["qoder", "qodercli"], "Qoder", "qoder"),
            (["copilot"], "GitHub Copilot", "copilot")
        ]
        for (aliases, name, entry) in cases {
            for alias in aliases {
                let path = "/opt/bin/" + alias
                #expect(ProcessArgumentsReader.candidate(path))
                #expect(ProcessArgumentsReader.parseInvocation(from: Data(), executablePath: path)
                    == AgentInvocation(agentName: name, entrypoint: entry))
                for runtime in ["node", "bun", "deno", "python", "python3"] {
                    let result = ProcessArgumentsReader.parseInvocation(
                        from: fixture([runtime, path, "--prompt", "secret"]), executablePath: "/bin/" + runtime)
                    #expect(result == AgentInvocation(agentName: name, runtime: runtime, entrypoint: entry))
                }
                let module = ProcessArgumentsReader.parseInvocation(
                    from: fixture(["python3", "-m", alias, "--prompt", "secret"]), executablePath: "/bin/python3")
                #expect(module == AgentInvocation(agentName: name, runtime: "python3", entrypoint: entry))
            }
        }
    }
    @Test func expandedScopedPackages() {
        let cases = [("@qwen-code/qwen-code", "Qwen Code", "qwen"),
                     ("@moonshot-ai/kimi-cli", "Kimi CLI", "kimi"),
                     ("@github/copilot", "GitHub Copilot", "copilot")]
        for (package, name, entry) in cases {
            for script in [package, "/opt/lib/node_modules/" + package + "/dist/cli.js"] {
                for runtime in ["node", "bun", "deno", "python", "python3"] {
                    let result = ProcessArgumentsReader.parseInvocation(
                        from: fixture([runtime, script]), executablePath: "/bin/" + runtime)
                    #expect(result == AgentInvocation(agentName: name, runtime: runtime, entrypoint: entry))
                }
            }
        }
    }
    @Test func expandedExecutableNames() {
        let cases: [([String], String)] = [
            (["antigravity", "agy"], "Antigravity CLI"),
            (["hermes", "hermes-agent"], "Hermes Agent"),
            (["kimi", "kimi-cli"], "Kimi CLI"),
            (["openclaw"], "OpenClaw"),
            (["pi", "pi-agent"], "Pi Agent"),
            (["omp", "oh-my-pi"], "Oh My Pi"),
            (["qoder", "qodercli", "qoderclicn"], "Qoder"),
            (["codebuddy", "workbuddy"], "CodeBuddy"),
            (["copilot", "github-copilot-cli"], "GitHub Copilot"),
            (["windsurf-agent"], "Windsurf")
        ]
        for (aliases, name) in cases {
            for alias in aliases {
                let process = ObservedProcess(pid: 42, parentPID: 1, uid: 501, cpuPercent: 0,
                    residentBytes: 0, executable: "/opt/bin/" + alias)
                #expect(AgentRecognizer.agentName(for: process) == name)
            }
        }
    }
    @Test func expandedNamesDoNotMatchUnrelatedArguments() {
        for token in ["antigravity-helper", "hermes_cli_extra", "kimi-cli.js", "qodercli-helper",
                      "@qwen-code/other/cli.js", "@moonshot-ai/other/cli.js", "@github/other/cli.js"] {
            #expect(ProcessArgumentsReader.parseInvocation(from: fixture(["node", token]), executablePath: "/bin/node") == nil)
        }
        #expect(ProcessArgumentsReader.parseInvocation(from: fixture(["python3", "-m", "-hermes_cli"]), executablePath: "/bin/python3") == nil)
        #expect(ProcessArgumentsReader.parseInvocation(from: fixture(["node", "other.js", "copilot"]), executablePath: "/bin/node") == nil)
        #expect(ProcessArgumentsReader.parseInvocation(from: fixture(["node"], environment: ["@github/copilot"]), executablePath: "/bin/node") == nil)
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
