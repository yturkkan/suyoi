import Foundation
import Darwin

/// Reads only the bounded argv prefix and returns normalized identity, never arguments.
struct ProcessArgumentsReader {
    static func candidate(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return runtime(name) || direct(name) != nil
    }

    private static func runtime(_ name: String) -> Bool {
        ["node", "bun", "deno", "python", "python3"].contains(name) || name.hasPrefix("python3.")
    }

    private static func direct(_ name: String) -> (String, String)? {
        switch name {
        case "claude": return ("Claude Code", "claude")
        case "codex": return ("Codex", "codex")
        case "opencode", "opencode-cli": return ("OpenCode", "opencode")
        case "aider": return ("Aider", "aider")
        case "gemini": return ("Gemini CLI", "gemini")
        default: return nil
        }
    }

    static func parseExecutablePath(from data: Data) -> String? {
        guard data.count > 4 else { return nil }
        let index = 4
        guard let end = data[index...].firstIndex(of: 0),
              let rawPath = String(bytes: data[index..<end], encoding: .utf8),
              rawPath.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: rawPath).standardizedFileURL.path
    }

    func executablePath(pid: Int32) -> String? {
        guard let data = readProcArgsData(pid: pid) else { return nil }
        return Self.parseExecutablePath(from: data)
    }

    static func parseInvocation(from data: Data, executablePath: String) -> AgentInvocation? {
        let executable = URL(fileURLWithPath: executablePath).lastPathComponent
        if let (name, entry) = direct(executable) { return AgentInvocation(agentName: name, entrypoint: entry) }
        guard runtime(executable), data.count >= 4 else { return nil }
        let bytes = data
        let raw = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        let argc = Int32(bitPattern: raw)
        guard argc > 0 else { return nil }
        var index = 4
        guard let end = bytes[index...].firstIndex(of: 0) else { return nil }
        index = end + 1
        while index < bytes.count && bytes[index] == 0 { index += 1 }
        var args: [String] = []
        for _ in 0..<min(Int(argc), 3) {
            guard index < bytes.count, let end = bytes[index...].firstIndex(of: 0),
                  let token = String(bytes: bytes[index..<end], encoding: .utf8) else { return nil }
            args.append(token)
            index = end + 1
        }
        guard args.count > 1 else { return nil }
        let token: String
        if executable.hasPrefix("python"), args[1] == "-m" {
            guard args.count > 2, !args[2].hasPrefix("-") else { return nil }
            token = args[2]
        } else {
            guard !args[1].hasPrefix("-") else { return nil }
            token = args[1]
        }
        let parts = token.split(separator: "/").map(String.init)
        let base = parts.last ?? token
        var match = direct(base)
        if match == nil {
            let packages: [(String, String, String, String)] = [
                ("@anthropic-ai", "claude-code", "Claude Code", "claude"),
                ("@openai", "codex", "Codex", "codex"),
                ("@google", "gemini-cli", "Gemini CLI", "gemini")
            ]
            for (scope, package, name, entry) in packages where parts.count >= 2 {
                if zip(parts, parts.dropFirst()).contains(where: { $0.0 == scope && $0.1 == package }) {
                    match = (name, entry); break
                }
            }
        }
        guard let (name, entry) = match else { return nil }
        return AgentInvocation(agentName: name, runtime: executable, entrypoint: entry)
    }

    func invocation(pid: Int32, executablePath: String) -> AgentInvocation? {
        guard Self.candidate(executablePath) else { return nil }
        let executable = URL(fileURLWithPath: executablePath).lastPathComponent
        if let (name, entry) = Self.direct(executable) {
            return AgentInvocation(agentName: name, entrypoint: entry)
        }
        guard let data = readProcArgsData(pid: pid) else { return nil }
        return Self.parseInvocation(from: data, executablePath: executablePath)
    }

    private func readProcArgsData(pid: Int32) -> Data? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0, size <= 4 * 1024 * 1024 else { return nil }
        var data = Data(count: size)
        let result = data.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0) }
        guard result == 0, size <= data.count else { return nil }
        data.count = size
        return data
    }
}
