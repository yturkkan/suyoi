import Foundation
import Testing
@testable import SuyoiCore

struct InventoryTests {
    private func serverProcess(_ pid: Int, parent: Int, name: String, cwd: String = "/projects/app") -> ObservedProcess {
        ObservedProcess(pid: pid, parentPID: parent, uid: 501, cpuPercent: 0, residentBytes: 100,
            executable: "/bin/" + name, startTimeMicroseconds: UInt64(pid) * 1_000_000, cwd: cwd)
    }

    @Test(arguments: ["zsh", "bash", "fish", "sh", "tcsh", "ksh", "login"])
    func singleChildShellIsNeverServerRoot(shell: String) throws {
        let processes = [serverProcess(10, parent: 1, name: shell), serverProcess(11, parent: 10, name: "node")]
        let groups = ProcessTree(processes: processes).groupServers(listeners: [Listener(pid: 11, processName: "node", address: "127.0.0.1", port: 3000)])
        let group = try #require(groups.first)
        #expect(groups.count == 1)
        #expect(group.rootPID == 11)
        #expect(group.memberPIDs == [11])
        #expect(group.memberIdentities == [processes[1].identity])
    }

    @Test func serverMemberIdentitiesRoundTripAndLegacyDecoding() throws {
        let processes = [serverProcess(10, parent: 1, name: "node"), serverProcess(11, parent: 10, name: "node")]
        let group = try #require(ProcessTree(processes: processes).groupServers(listeners: [
            Listener(pid: 10, processName: "node", address: "127.0.0.1", port: 3000)
        ]).first)
        #expect(group.memberIdentities == processes.map(\.identity))
        let data = try JSONEncoder().encode(group)
        #expect(try JSONDecoder().decode(ServerGroup.self, from: data) == group)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "memberIdentities")
        let decoded = try JSONDecoder().decode(ServerGroup.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.memberIdentities.isEmpty)
        #expect(decoded.memberPIDs == group.memberPIDs)
    }

    @Test(arguments: ["zsh", "codex"])
    func sharedPortDoesNotCrossBoundaryIntoDifferentProject(boundary: String) {
        let processes = [serverProcess(10, parent: 1, name: "node"),
            serverProcess(11, parent: 10, name: boundary),
            serverProcess(12, parent: 11, name: "node", cwd: "/projects/other")]
        let listeners = [10, 12].map { Listener(pid: $0, processName: "node", address: "127.0.0.1", port: 3000) }
        let groups = ProcessTree(processes: processes).groupServers(listeners: listeners)
        #expect(groups.map(\.rootPID) == [10, 12])
        #expect(groups.map(\.memberPIDs) == [[10], [12]])
    }

    @Test func testParsesExecutableWithSpacesAndCurrentUserOnly() {
        let rows = InventoryParser.processes(" 42 1 501 2.3 100 /Applications/Codex.app/Contents/MacOS/Codex\n43 1 0 0.0 50 /bin/claude\n44 1 501 0.1 64 /Applications/My Tool.app/Contents/MacOS/tool", uid: 501)
        #expect(rows.count == 2)
        #expect(rows.first?.residentBytes == 102400)
        #expect(rows.first?.agentName == "Codex")
        #expect(rows.last?.executable == "/Applications/My Tool.app/Contents/MacOS/tool")
    }
    @Test func testRejectsMalformedAndNegativeProcessRows() {
        #expect(InventoryParser.processes("bad\n0 1 501 0 50 /bin/codex\n42 1 501 NaN 50 /bin/codex\n43 1 501 1 -20 /bin/codex", uid: 501).isEmpty)
    }
    @Test func testExactAgentNamesDoNotMatchHelpersOrUnrelatedNames() {
        let rows = InventoryParser.processes("10 1 501 0 20 /usr/bin/claude\n11 1 501 0 20 /usr/bin/opencode\n12 1 501 0 20 /usr/bin/aider\n13 1 501 0 20 /tmp/not-codex\n14 1 501 0 20 /Applications/Codex.app/Contents/Frameworks/Codex Helper\n15 1 501 0 20 /usr/bin/node", uid: 501)
        #expect(rows.compactMap(\.agentName) == ["Claude Code", "OpenCode", "Aider"])
    }
    @Test func testListenersParseIPv4IPv6AndDeduplicate() {
        let rows = InventoryParser.listeners("p20\ncnode\nf4\nn127.0.0.1:3000\nf5\nn127.0.0.1:3000\nf6\nn[::1]:5173\np21\ncPython\nn*:8000\n")
        #expect(rows.count == 3)
        #expect(rows.map(\.port) == [3000, 5173, 8000])
        #expect(rows.dropFirst().first?.address == "::1")
        #expect(rows.first?.exposure == "Loopback")
        #expect(rows.last?.exposure == "All interfaces")
        #expect(rows.allSatisfy { $0.isDevelopmentRuntime })
    }
    @Test func testListenersRejectMalformedRecords() {
        #expect(InventoryParser.listeners("n*:3000\np0\ncnode\nn*:3000\np22\ncnode\nnnot-a-port\nn*:99999\nn*:0\np23\nn*:80").isEmpty)
    }
    @Test func testNonDevelopmentListenerIsNotCalledDevServer() {
        let row = InventoryParser.listeners("p42\ncControlCenter\nn*:5000").first
        #expect(row != nil)
        #expect(row?.isDevelopmentRuntime == false)
    }
}

final class CleanupTests {
    var root: URL!
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Suyoi-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func put(_ path: String, bytes: Int = 10) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 65, count: bytes).write(to: file)
    }
    @Test func testFindsOnlyKnownGeneratedDirectoriesWithoutReadingSource() throws {
        try put("app/node_modules/module/index.js", bytes: 100)
        try put("app/.next/cache/image", bytes: 20)
        try put("app/.next/server/page", bytes: 80)
        try put("app/src/main.swift")
        let report = CleanupScanner().scan(root: root)
        #expect(report.candidates.count == 2)
        #expect(report.candidates.map(\.bytes).reduce(0, +) == 120)
        #expect(!(report.partial))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("app/src/main.swift").path))
    }
    @Test func testDoesNotTraverseSymlinkedProjectOrCandidate() throws {
        try put("outside/node_modules/value", bytes: 20)
        let scanRoot = root.appendingPathComponent("scan")
        try FileManager.default.createDirectory(at: scanRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: scanRoot.appendingPathComponent("linked"), withDestinationURL: root.appendingPathComponent("outside"))
        try FileManager.default.createSymbolicLink(at: scanRoot.appendingPathComponent("node_modules"), withDestinationURL: root.appendingPathComponent("outside/node_modules"))
        #expect(CleanupScanner().scan(root: scanRoot).candidates.isEmpty)
    }
    @Test func testMissingAndSymlinkRootReportsWarning() throws {
        let missing = CleanupScanner().scan(root: root.appendingPathComponent("missing"))
        #expect(!(missing.warnings.isEmpty))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        #expect(!(CleanupScanner().scan(root: link).warnings.isEmpty))
    }
    @Test func testEntryBudgetReportsPartialInsteadOfComplete() throws {
        for n in 0..<20 { try put("app/node_modules/\(n)") }
        #expect(CleanupScanner().scan(root: root, entryLimit: 5).partial)
    }
    @Test func testZeroBudgetAndExpiredDeadlineReturnPartial() throws {
        try put("app/node_modules/value")
        #expect(CleanupScanner().scan(root: root, entryLimit: 0).partial)
        #expect(CleanupScanner().scan(root: root, timeLimit: 0).partial)
        #expect(CleanupScanner().scan(root: root, entryLimit: 0).candidates.isEmpty)
    }
    @Test func testSymlinkWithinCandidateIsNotCounted() throws {
        try put("outside/big", bytes: 100)
        try put("app/node_modules/real", bytes: 20)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("app/node_modules/link"), withDestinationURL: root.appendingPathComponent("outside"))
        let report = CleanupScanner().scan(root: root)
        #expect(report.candidates.first?.bytes == 20)
    }
    @Test func testIgnoresGitAndNestedCandidateDoubleCounting() throws {
        try put(".git/node_modules/secret")
        try put("app/node_modules/sub/node_modules/file", bytes: 24)
        let report = CleanupScanner().scan(root: root)
        #expect(report.candidates.count == 1)
        #expect(report.candidates.first?.bytes == 24)
    }
}
