import AppKit
import Foundation
import SuyoiCore

#if DEBUG
let fixtureArguments = Array(CommandLine.arguments.dropFirst())
if Bundle.main.bundleIdentifier == DashboardFixture.bundleIdentifier || fixtureArguments.first == "--dashboard-fixture" {
    MainActor.assumeIsolated { DashboardFixture.run(arguments: fixtureArguments) }
}
#endif

// Parse before creating NSApplication; CLI inspection never probes sockets.
let options: CLIOptions
do {
    options = try CLIOptions(arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n\n\(CLIOptions.usage)\n".utf8))
    exit(2)
}

switch options {
case .gui:
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
case .help:
    print(CLIOptions.usage)
case .hookBridge:
    let input = FileHandle.standardInput.readData(ofLength: 65_537)
    let output = HookBridgeClient().forwardEventAndWait(input)
    FileHandle.standardOutput.write(output)
    FileHandle.standardOutput.write(Data("\n".utf8))
case .snapshot, .scanCleanup, .agentStorage, .quotas:
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    do {
        let data: Data
        switch options {
        case .snapshot:
            data = try encoder.encode(SystemInspector().snapshot())
        case .scanCleanup(let path):
            let root = path.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer")
            data = try encoder.encode(InventoryService(safetyEvaluator: SafetyEvaluator()).scanCleanup(root: root))
        case .quotas:
            data = try encoder.encode(LocalQuotaInspector().inspectQuotas(at: Date()))
        case .agentStorage:
            let caches = AgentCacheCatalog().scanAgentCaches()
            let report = CleanupReport(candidates: [], warnings: caches.warnings, partial: caches.partial,
                agentCacheCandidates: caches.candidates, discoveredCount: caches.candidates.count)
            data = try encoder.encode(report)
        case .gui, .help, .hookBridge:
            preconditionFailure("Non-JSON command reached JSON output")
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
        FileHandle.standardError.write(Data("Suyoi could not encode its inspection: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
