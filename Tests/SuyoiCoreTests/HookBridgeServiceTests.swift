import Darwin
import Dispatch
import Foundation
import Testing
@testable import SuyoiCore

private struct HookBridgeFixture: Sendable {
    let root: URL
    let client: HookBridgeClient

    init(owner: ObservedProcess? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        client = HookBridgeClient(inboxDirectory: root.appendingPathComponent("inbox", isDirectory: true),
                                  outboxDirectory: root.appendingPathComponent("outbox", isDirectory: true),
                                  hookOwner: { owner }, processLookup: { pid, uid in
                                      guard let owner, owner.pid == Int(pid), owner.uid == uid else { return nil }
                                      return owner
                                  })
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
    private let session = "00000000-0000-4000-8000-000000000123"
    private let project = "/workspace/sample"

    private func payload(_ event: String, extra: [String: Any] = [:]) throws -> Data {
        var fields: [String: Any] = ["hook_event_name": event, "session_id": session, "cwd": project,
                                     "tool_name": "Bash", "tool_input": ["command": "swift build"]]
        fields.merge(extra) { _, new in new }
        return try JSONSerialization.data(withJSONObject: fields)
    }

    private func decision(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = root["hookSpecificOutput"] as? [String: Any] else { return nil }
        return (output["permissionDecision"] as? String)
            ?? (output["decision"] as? [String: Any])?["behavior"] as? String
    }

    private func reducedFields(at url: URL) throws -> [String: Any] {
        let envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let encoded = try #require(envelope["fields"] as? String)
        let bytes = try #require(Data(base64Encoded: encoded))
        return try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    @Test func defaultDirectoriesUseProvidedHome() {
        let home = URL(fileURLWithPath: "/test-home", isDirectory: true)
        #expect(HookBridgeClient.defaultInboxDirectory(homeDirectory: home).path
                == "/test-home/Library/Application Support/Suyoi/approvals/inbox")
        #expect(HookBridgeClient.defaultOutboxDirectory(homeDirectory: home).path
                == "/test-home/Library/Application Support/Suyoi/approvals/outbox")
    }

    @Test(arguments: ["PermissionRequest", "PreToolUse"])
    func roundTripUsesProviderDecisionAndSpoolsOnlyRedactedFields(event: String) async throws {
        let fixture = try HookBridgeFixture()
        defer { fixture.cleanUp() }
        let input = try payload(event, extra: [
            "tool_input": ["command": "curl -H 'Bearer /secret+fixture~token=='", "description": "PRIVATE DESCRIPTION"],
            "tool_response": ["stdout": "PRIVATE STDOUT"], "prompt": "PRIVATE PROMPT"
        ])
        let task = Task.detached { fixture.client.forwardEventAndWait(input, timeout: 5, pollInterval: 0.005) }
        let request = try await fixture.waitForRequest()
        let fields = try reducedFields(at: request)
        #expect((fields["tool_input"] as? [String: String]) == ["command": "curl -H '[REDACTED]'"])
        #expect(fields["tool_response"] == nil && fields["prompt"] == nil)
        let controller = AgentApprovalController()
        #expect(fixture.client.drainInbox(into: controller) == 1)
        let pending = try #require(controller.pendingRequests().first)
        #expect(!controller.canAutoApprove(request: pending))
        #expect(controller.submitDecision(.allowOnce, forRequestID: pending.id))
        let response = await task.value
        let expected = event == "PreToolUse"
            ? #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}"#
            : #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#
        #expect(response == Data(expected.utf8))
        #expect(!FileManager.default.fileExists(atPath: request.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.responseURL(for: request).path))
    }

    @Test func timeoutFailsClosedAndRemovesRequest() throws {
        let fixture = try HookBridgeFixture()
        defer { fixture.cleanUp() }
        let started = ProcessInfo.processInfo.systemUptime
        let result = fixture.client.forwardEventAndWait(try payload("PermissionRequest"), timeout: 0.05, pollInterval: 10)
        #expect(decision(result) == "deny")
        #expect(ProcessInfo.processInfo.systemUptime - started < 2)
        #expect(fixture.requests().isEmpty)
    }

    @Test func invalidAndOversizedPayloadsNeverReachInbox() throws {
        let fixture = try HookBridgeFixture()
        defer { fixture.cleanUp() }
        var oversized = try payload("PreToolUse")
        oversized.append(Data(repeating: 32, count: 65_537 - oversized.count))
        let invalid = [Data(), Data("{".utf8), Data("[]".utf8), Data("null".utf8),
                       Data(#"{"hook_event_name":"PermissionRequest"}"#.utf8),
                       Data(#"{"session_id":"session-1"}"#.utf8),
                       Data(#"{"hook_event_name":12,"session_id":"session-1"}"#.utf8),
                       try payload("Unknown"), oversized]
        for input in invalid {
            #expect(!fixture.client.forwardEventAndWait(input, timeout: 0.01).isEmpty)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.client.inboxDirectory.path))
    }

    @Test(arguments: ["Stop", "SessionEnd", "SessionStart", "PostToolUse", "Notification"])
    func unusedOrUnverifiedLifecycleEventsDoNotWriteSpool(event: String) throws {
        let fixture = try HookBridgeFixture()
        defer { fixture.cleanUp() }
        let input = try payload(event, extra: ["tool_response": ["stdout": "PRIVATE STDOUT"]])
        #expect(fixture.client.forwardEventAndWait(input, timeout: 0, pollInterval: 10).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.client.inboxDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.client.outboxDirectory.path))
    }

    @Test func acceptsExactly64KiBWithoutSpoolingUnusedInput() throws {
        let fixture = try HookBridgeFixture()
        defer { fixture.cleanUp() }
        var input = try payload("PostToolUse")
        input.append(Data(repeating: 32, count: 65_536 - input.count))
        #expect(fixture.client.forwardEventAndWait(input).isEmpty)
        #expect(fixture.requests().isEmpty)
    }

    @Test func sessionEndInvalidatesOldRequestsBeforeDrainAndStartCannotReuseGrant() async throws {
        let owner = ObservedProcess(pid: 123_456, parentPID: 12, uid: Int(getuid()), cpuPercent: 0, residentBytes: 0,
                                    executable: "/tools/claude", startTimeMicroseconds: 1_000, cwd: project)
        let fixture = try HookBridgeFixture(owner: owner)
        defer { fixture.cleanUp() }
        let controller = AgentApprovalController()
        let start = try payload("SessionStart")
        let end = try payload("SessionEnd", extra: ["cwd": "/changed-project"])
        let permission = try payload("PreToolUse")
        #expect(fixture.client.forwardEventAndWait(start).isEmpty)
        let original = Task.detached { fixture.client.forwardEventAndWait(permission, timeout: 5) }
        _ = try await fixture.waitForRequest()
        #expect(fixture.client.drainInbox(into: controller) == 1)
        let pending = try #require(controller.pendingRequests().first)
        #expect(controller.canAutoApprove(request: pending))
        #expect(controller.submitDecision(.allowForSession, forRequestID: pending.id))
        #expect(decision(await original.value) == "allow")

        let automatic = Task.detached { fixture.client.forwardEventAndWait(permission, timeout: 5) }
        _ = try await fixture.waitForRequest()
        #expect(fixture.client.drainInbox(into: controller) == 0)
        #expect(decision(await automatic.value) == "allow")

        let restartedController = AgentApprovalController()
        let afterAppRestart = Task.detached { fixture.client.forwardEventAndWait(permission, timeout: 5) }
        _ = try await fixture.waitForRequest()
        #expect(fixture.client.drainInbox(into: restartedController) == 1)
        let restartRequest = try #require(restartedController.pendingRequests().first)
        #expect(restartedController.submitDecision(.deny(reason: nil), forRequestID: restartRequest.id))
        #expect(decision(await afterAppRestart.value) == "deny")

        let queuedBeforeEnd = Task.detached { fixture.client.forwardEventAndWait(permission, timeout: 5) }
        _ = try await fixture.waitForRequest()
        #expect(fixture.client.forwardEventAndWait(end).isEmpty)
        #expect(fixture.client.forwardEventAndWait(start).isEmpty)
        #expect(fixture.client.drainInbox(into: controller) == 0)
        #expect(decision(await queuedBeforeEnd.value) == "deny")
        #expect(controller.activeAutoApproveRequests().isEmpty)

        let newSession = Task.detached { fixture.client.forwardEventAndWait(permission, timeout: 5) }
        _ = try await fixture.waitForRequest()
        #expect(fixture.client.drainInbox(into: controller) == 1)
        let newRequest = try #require(controller.pendingRequests().first)
        #expect(controller.canAutoApprove(request: newRequest))
        #expect(controller.submitDecision(.deny(reason: "No"), forRequestID: newRequest.id))
        #expect(decision(await newSession.value) == "deny")
    }

    @Test func structuredQuestionAnswerUsesOriginalProviderInputWithoutSpoolingIt() async throws {
        let fixture = try HookBridgeFixture()
        defer { fixture.cleanUp() }
        let question = ["question": "Which build?", "multiSelect": false, "options": [["label": "Release", "description": "PRIVATE DETAILS"]]] as [String: Any]
        let input = try payload("PreToolUse", extra: ["tool_name": "AskUserQuestion", "tool_input": ["questions": [question]]])
        let task = Task.detached { fixture.client.forwardEventAndWait(input, timeout: 5, pollInterval: 0.005) }
        let request = try await fixture.waitForRequest()
        let reduced = try #require(try reducedFields(at: request)["tool_input"] as? [String: Any])
        #expect(reduced["questions"] == nil)
        #expect(reduced["options"] as? [String] == ["Release"])
        let controller = AgentApprovalController()
        #expect(fixture.client.drainInbox(into: controller) == 1)
        let pending = try #require(controller.pendingRequests().first)
        #expect(controller.submitDecision(.answerQuestion(selectedOption: "Release"), forRequestID: pending.id))
        let result = await task.value
        #expect(decision(result) == "allow")
        let object = try #require(JSONSerialization.jsonObject(with: result) as? [String: Any])
        let output = try #require(object["hookSpecificOutput"] as? [String: Any])
        let updated = try #require(output["updatedInput"] as? [String: Any])
        #expect(updated["answers"] as? [String: String] == ["Which build?": "Release"])
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
            #expect(decision(await task.value) == "deny")
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
            let url = fixture.responseURL(for: request)
            let staged = url.deletingLastPathComponent().appendingPathComponent(".test-response")
            try response.write(to: staged)
            try #require(chmod(staged.path, 0o600) == 0)
            try FileManager.default.moveItem(at: staged, to: url)
            #expect(decision(await task.value) == "allow")
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
        #expect(decision(result) == "deny")
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

    @Test func drainInboxPrunesExpiredAndRejectsUnversionedInput() throws {
        let fixture = try HookBridgeFixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.client.inboxDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let expiredURL = fixture.client.inboxDirectory.appendingPathComponent("expired.json")
        try payload("PreToolUse").write(to: expiredURL)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-300)], ofItemAtPath: expiredURL.path)
        let requestURL = fixture.client.inboxDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try payload("PreToolUse").write(to: requestURL)
        #expect(chmod(requestURL.path, 0o600) == 0)
        let controller = AgentApprovalController()
        #expect(fixture.client.drainInbox(into: controller) == 0)
        #expect(!FileManager.default.fileExists(atPath: expiredURL.path))
        #expect(!FileManager.default.fileExists(atPath: requestURL.path))
        #expect(controller.pendingRequests().isEmpty)
    }
}
