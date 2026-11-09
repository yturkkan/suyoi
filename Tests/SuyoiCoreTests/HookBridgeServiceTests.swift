import Darwin
import Dispatch
import Foundation
import Testing
@testable import SuyoiCore

private struct HookBridgeFixture: Sendable {
    let root: URL
    let client: HookBridgeClient

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        client = HookBridgeClient(inboxDirectory: root.appendingPathComponent("inbox", isDirectory: true),
                                  outboxDirectory: root.appendingPathComponent("outbox", isDirectory: true))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func requests() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: client.inboxDirectory,
                                                       includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
    }

    func waitForRequest() async throws -> URL {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let request = requests().first { return request }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw RequestNotReceived()
    }

    func responseURL(for request: URL) -> URL {
        client.outboxDirectory.appendingPathComponent(request.deletingPathExtension().lastPathComponent + ".response.json")
    }

    private struct RequestNotReceived: Error {}
}

private final class HookBridgeNotifications: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    func record() { lock.withLock { storage += 1 } }
    var count: Int { lock.withLock { storage } }

    func waitForChange(after count: Int) async throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline {
            if self.count > count { return true }
            try await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

@Suite("Hook bridge transport and inbox notifications", .serialized)
struct HookBridgeServiceTests {
    private let approved = Data(#"{"decision":"approve"}"#.utf8)
    private let timedOut = Data(#"{"decision":"block","reason":"Approval timed out"}"#.utf8)
    private let invalidPayload = Data(#"{"decision":"block","reason":"Invalid hook payload"}"#.utf8)

    private func payload(_ event: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["hook_event_name": event, "session_id": "session-1"])
    }

    @Test func defaultDirectoriesUseProvidedHome() {
        let home = URL(fileURLWithPath: "/test-home", isDirectory: true)
        #expect(HookBridgeClient.defaultInboxDirectory(homeDirectory: home).path
                == "/test-home/Library/Application Support/Suyoi/approvals/inbox")
        #expect(HookBridgeClient.defaultOutboxDirectory(homeDirectory: home).path
                == "/test-home/Library/Application Support/Suyoi/approvals/outbox")
    }

    @Test(arguments: ["PermissionRequest", "PreToolUse"])
    func roundTripReturnsExactResponseAndCleansSpool(event: String) async throws {
        let fixture = try HookBridgeFixture()
        defer { fixture.cleanUp() }
        let input = try payload(event)
        let task = Task.detached { fixture.client.forwardEventAndWait(input, timeout: 5, pollInterval: 0.005) }
        do {
            let request = try await fixture.waitForRequest()
            #expect(UUID(uuidString: request.deletingPathExtension().lastPathComponent) != nil)
            #expect(try Data(contentsOf: request) == input)
            let responseURL = fixture.responseURL(for: request)
            let response = Data(#"{"decision":"block","reason":"User declined"}"#.utf8)
            try response.write(to: responseURL, options: .atomic)
            #expect(await task.value == response)
            #expect(!FileManager.default.fileExists(atPath: request.path))
            #expect(!FileManager.default.fileExists(atPath: responseURL.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.client.inboxDirectory.path).isEmpty)
        } catch {
            _ = await task.value
            throw error
        }
    }

    @Test func timeoutFailsClosedAndRemovesRequest() throws {
        let fixture = try HookBridgeFixture()
        defer { fixture.cleanUp() }
        let started = ProcessInfo.processInfo.systemUptime
        let result = fixture.client.forwardEventAndWait(HookBridgeClient.simulatedApprovalPayload(),
                                                        timeout: 0.05, pollInterval: 10)
        #expect(result == timedOut)
        #expect(ProcessInfo.processInfo.systemUptime - started < 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.client.inboxDirectory.path).isEmpty)
    }

    @Test func invalidAndOversizedPayloadsNeverReachInbox() throws {
        let fixture = try HookBridgeFixture()
        defer { fixture.cleanUp() }
        var oversized = HookBridgeClient.simulatedApprovalPayload()
        oversized.append(Data(repeating: 32, count: 65_537 - oversized.count))
        let invalid = [Data(), Data("{".utf8), Data("[]".utf8), Data("null".utf8),
                       Data(#"{"hook_event_name":"PermissionRequest"}"#.utf8),
                       Data(#"{"session_id":"session-1"}"#.utf8),
                       Data(#"{"hook_event_name":12,"session_id":"session-1"}"#.utf8),
                       Data(#"{"hook_event_name":"Stop","session_id":null}"#.utf8),
                       Data(#"{"hook_event_name":"Stop","session_id":" "}"#.utf8),
                       try payload("Unknown"), oversized]
        for input in invalid {
            #expect(fixture.client.forwardEventAndWait(input, timeout: 0.01) == invalidPayload)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.client.inboxDirectory.path))
    }

    @Test(arguments: ["Stop", "SessionEnd", "SessionStart", "PostToolUse", "Notification"])
    func lifecycleEventsReturnImmediatelyAndRemainForIngestion(event: String) throws {
        let fixture = try HookBridgeFixture()
        defer { fixture.cleanUp() }
        let input = try payload(event)
        let started = ProcessInfo.processInfo.systemUptime
        #expect(fixture.client.forwardEventAndWait(input, timeout: 0, pollInterval: 10) == approved)
        #expect(ProcessInfo.processInfo.systemUptime - started < 2)
        let request = try #require(fixture.requests().first)
        #expect(fixture.requests().count == 1)
        #expect(try Data(contentsOf: request) == input)
        #expect(!FileManager.default.fileExists(atPath: fixture.client.outboxDirectory.path))
    }

    @Test func acceptsExactly64KiB() throws {
        let fixture = try HookBridgeFixture()
        defer { fixture.cleanUp() }
        var input = try payload("Stop")
        input.append(Data(repeating: 32, count: 65_536 - input.count))
        #expect(fixture.client.forwardEventAndWait(input) == approved)
        let request = try #require(fixture.requests().first)
        #expect(try Data(contentsOf: request).count == 65_536)
    }

    @Test func simulatedPayloadIsAcceptedByController() throws {
        let controller = AgentApprovalController()
        let request = try #require(controller.ingestHookEvent(HookBridgeClient.simulatedApprovalPayload()))
        #expect(request.sessionID == "sim-session-1")
        #expect(request.agentName == "Claude Code")
        #expect(request.toolName == "Bash")
        #expect(request.summary == "git status --short")
        #expect(request.questionOptions.isEmpty)
        #expect(controller.submitDecision(.allowOnce, forRequestID: request.id))
    }

    @Test func simulatedQuestionPreservesEscapingAndOfferedOptions() throws {
        let controller = AgentApprovalController()
        let input = HookBridgeClient.simulatedApprovalPayload(
            sessionID: "question-session", agentName: "Test CLI", toolName: "AskUserQuestion",
            command: "ignored", question: "Build \"release\"?", options: ["Yes", "No \\ later"]
        )
        let request = try #require(controller.ingestHookEvent(input))
        #expect(request.sessionID == "question-session")
        #expect(request.agentName == "Test CLI")
        #expect(request.toolName == "AskUserQuestion")
        #expect(request.summary == "Build \"release\"?")
        #expect(request.questionOptions == ["Yes", "No \\ later"])
        #expect(controller.submitDecision(.answerQuestion(selectedOption: "No \\ later"), forRequestID: request.id))
    }

    @Test(arguments: ["symlink", "directory", "fifo", "oversized"])
    func unsafeResponsesFailClosed(kind: String) async throws {
        let fixture = try HookBridgeFixture()
        defer { fixture.cleanUp() }
        let target = fixture.root.appendingPathComponent("target.json")
        try approved.write(to: target)
        let task = Task.detached {
            fixture.client.forwardEventAndWait(HookBridgeClient.simulatedApprovalPayload(), timeout: 5, pollInterval: 0.005)
        }
        do {
            let request = try await fixture.waitForRequest()
            let response = fixture.responseURL(for: request)
            switch kind {
            case "symlink": try FileManager.default.createSymbolicLink(at: response, withDestinationURL: target)
            case "directory": try FileManager.default.createDirectory(at: response, withIntermediateDirectories: false)
            case "fifo": #expect(mkfifo(response.path, 0o600) == 0)
            default: try Data(repeating: 32, count: 16_385).write(to: response, options: .atomic)
            }
            #expect(await task.value == Data(#"{"decision":"block","reason":"Invalid approval response"}"#.utf8))
            #expect(fixture.requests().isEmpty)
            #expect(try Data(contentsOf: target) == approved)
        } catch {
            _ = await task.value
            throw error
        }
    }

    @Test func responseSizeBoundaryIsAccepted() async throws {
        let fixture = try HookBridgeFixture()
        defer { fixture.cleanUp() }
        let task = Task.detached {
            fixture.client.forwardEventAndWait(HookBridgeClient.simulatedApprovalPayload(), timeout: 5, pollInterval: 0.005)
        }
        do {
            let request = try await fixture.waitForRequest()
            var response = approved
            response.append(Data(repeating: 32, count: 16_384 - response.count))
            try response.write(to: fixture.responseURL(for: request), options: .atomic)
            #expect(await task.value == response)
        } catch {
            _ = await task.value
            throw error
        }
    }

    @Test(arguments: ["inbox", "outbox"])
    func symlinkDirectoriesAreRejected(name: String) throws {
        let fixture = try HookBridgeFixture()
        defer { fixture.cleanUp() }
        let target = fixture.root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let directory = name == "inbox" ? fixture.client.inboxDirectory : fixture.client.outboxDirectory
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: target)
        let result = fixture.client.forwardEventAndWait(HookBridgeClient.simulatedApprovalPayload(), timeout: 0.05)
        #expect(result == Data(#"{"decision":"block","reason":"Hook bridge unavailable"}"#.utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test func watcherCreatesInboxNotifiesAndCanRestart() async throws {
        let fixture = try HookBridgeFixture()
        defer { fixture.cleanUp() }
        let notifications = HookBridgeNotifications()
        let watcher = ApprovalInboxWatcher(inboxDirectory: fixture.client.inboxDirectory) { notifications.record() }
        defer { watcher.stop() }
        watcher.start()
        watcher.start()
        #expect(FileManager.default.fileExists(atPath: fixture.client.inboxDirectory.path))
        try approved.write(to: fixture.client.inboxDirectory.appendingPathComponent("first.json"), options: .atomic)
        #expect(try await notifications.waitForChange(after: 0))
        watcher.stop()
        watcher.stop()
        // Allow any callback already executing at cancellation to finish before taking a baseline.
        try await Task.sleep(for: .milliseconds(50))
        let stoppedCount = notifications.count
        try approved.write(to: fixture.client.inboxDirectory.appendingPathComponent("stopped.json"), options: .atomic)
        try await Task.sleep(for: .milliseconds(100))
        #expect(notifications.count == stoppedCount)
        watcher.start()
        try approved.write(to: fixture.client.inboxDirectory.appendingPathComponent("restarted.json"), options: .atomic)
        #expect(try await notifications.waitForChange(after: stoppedCount))
    }

    @Test func watcherRejectsSymlinkInbox() async throws {
        let fixture = try HookBridgeFixture()
        defer { fixture.cleanUp() }
        let target = fixture.root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.client.inboxDirectory, withDestinationURL: target)
        let notifications = HookBridgeNotifications()
        let watcher = ApprovalInboxWatcher(inboxDirectory: fixture.client.inboxDirectory) { notifications.record() }
        defer { watcher.stop() }
        watcher.start()
        try approved.write(to: target.appendingPathComponent("ignored.json"), options: .atomic)
        try await Task.sleep(for: .milliseconds(100))
        #expect(notifications.count == 0)
    }

    @Test func drainInboxIngestsRequestsWritesOutboxAndPrunesExpired() throws {
        let fixture = try HookBridgeFixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.client.inboxDirectory, withIntermediateDirectories: true)
        let expiredURL = fixture.client.inboxDirectory.appendingPathComponent("expired.json")
        try HookBridgeClient.simulatedApprovalPayload(sessionID: "expired-1").write(to: expiredURL, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-300)], ofItemAtPath: expiredURL.path)
        let requestURL = fixture.client.inboxDirectory.appendingPathComponent("req-1.json")
        try HookBridgeClient.simulatedApprovalPayload(sessionID: "drain-1").write(to: requestURL, options: .atomic)
        let controller = AgentApprovalController()
        let added = fixture.client.drainInbox(into: controller)
        #expect(added == 1)
        #expect(!FileManager.default.fileExists(atPath: expiredURL.path))
        #expect(!FileManager.default.fileExists(atPath: requestURL.path))
        let pending = try #require(controller.pendingRequests().first)
        #expect(pending.sessionID == "drain-1")
        #expect(controller.submitDecision(.allowOnce, forRequestID: pending.id))
        let responseURL = fixture.client.outboxDirectory.appendingPathComponent("req-1.response.json")
        #expect(try Data(contentsOf: responseURL) == approved)
    }
}
