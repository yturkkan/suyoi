import Foundation

public enum CLIOptions: Equatable, Sendable {
    case gui
    case snapshot
    case scanCleanup(path: String?)
    case quotas
    case agentStorage
    case help

    public enum ParseError: Error, Equatable, LocalizedError {
        case invalidArguments
        public var errorDescription: String? { "Unknown, conflicting, or unexpected arguments." }
    }

    /// Arguments exclude the executable name. Exactly one command is allowed.
    public init(arguments: [String]) throws {
        guard let first = arguments.first else { self = .gui; return }
        switch first {
        case "--snapshot" where arguments.count == 1: self = .snapshot
        case "--quotas" where arguments.count == 1: self = .quotas
        case "--agent-storage" where arguments.count == 1: self = .agentStorage
        case "--help" where arguments.count == 1: self = .help
        case "--scan-cleanup":
            guard arguments.count <= 2 else { throw ParseError.invalidArguments }
            let path = arguments.dropFirst().first
            if let path, path.isEmpty || path.hasPrefix("-") { throw ParseError.invalidArguments }
            self = .scanCleanup(path: path)
        default: throw ParseError.invalidArguments
        }
    }

    public static let usage = """
    Suyoi: a read-only menu bar companion

    Suyoi                         Open menu bar app
    Suyoi --snapshot              Print current-user process, agent, project and TCP listener JSON
    Suyoi --scan-cleanup [path]   Review generated folders (default: ~/Developer) and allowlisted agent caches
    Suyoi --agent-storage         Print allowlisted agent cache inventory JSON
    Suyoi --quotas                Print bounded local account-wide quota and token usage JSON
    Suyoi --help                  Show this help

    Choose one command. No process termination, file deletion, network probes, or live quota requests. Quotas read allowlisted numeric session telemetry only.
    Sizes are logical bytes, not a promise of reclaimable space. Partial results include warnings.
    """
}
