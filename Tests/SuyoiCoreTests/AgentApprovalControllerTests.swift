import Foundation
import Dispatch
import Testing
@testable import SuyoiCore

private final class ApprovalResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []

    func record(_ data: Data) { lock.withLock { storage.append(data) } }
    var values: [[String: String]] {
        lock.withLock { storage.map { (try? JSONDecoder().decode([String: String].self, from: $0)) ?? [:] } }
    }
}

private final class ApprovalLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = true
    var active: Bool { lock.withLock { storage } }
    func revoke() { lock.withLock { storage = false } }
}

@Suite("Hook approvals and questions")
struct AgentApprovalControllerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let scope = ApprovalScope(
        process: ProcessIdentity(pid: 321, uid: 501, startTimeMicroseconds: 123, executablePath: "/bin/claude"),
        sessionID: "session-1", projectPath: "/workspace/sample", generation: UUID())


    private func event(_ kind: HookEventKind = .permissionRequest, session: String = "session-1",
                       tool: String = "Bash", input: [String: Any] = ["command": "swift build"],
                       fields: [String: Any] = [:]) throws -> Data {
        var object: [String: Any] = [
            "hook_event_name": kind.rawValue, "session_id": session, "agent_name": "Claude Code",
            "pid": 321, "cwd": "/workspace/sample", "tool_name": tool, "tool_input": input
        ]
        object.merge(fields) { _, new in new }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func question(session: String = "session-1") throws -> Data {
        try event(session: session, tool: "AskUserQuestion", input: [
            "questions": [["question": "Which target?", "options": [
                ["label": "Debug", "description": "Local build"],
                ["label": "Release", "description": "Optimized build"]
            ], "multiSelect": false]]
        ])
    }

    @Test func ingestsPermissionWithAllowlistedMetadata() throws {
        let controller = AgentApprovalController()
        let request = try #require(controller.ingestHookEvent(try event(fields: [
            "prompt": "ignored conversation", "env": ["TOKEN": "ignored value"]
        ]), now: now))
        #expect(!request.id.isEmpty)
        #expect(request.sessionID == "session-1")
        #expect(request.agentName == "Claude Code")
        #expect(request.pid == 321)
        #expect(request.projectPath == "/workspace/sample")
        #expect(request.toolName == "Bash")
        #expect(request.summary == "swift build")
        #expect(request.questionOptions.isEmpty)
        #expect(request.requestedAt == now)
        #expect(controller.pendingRequests() == [request])
        let encoded = try JSONEncoder().encode(request)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("ignored"))
        #expect(try JSONDecoder().decode(PendingApprovalRequest.self, from: encoded) == request)
    }

    @Test func publicContractsRoundTrip() throws {
        let decisions: [ApprovalDecision] = [.allowOnce, .allowForSession, .deny(reason: nil),
                                             .deny(reason: "No"), .answerQuestion(selectedOption: "Debug")]
        for decision in decisions {
            #expect(try JSONDecoder().decode(ApprovalDecision.self, from: JSONEncoder().encode(decision)) == decision)
        }
        let kinds: [HookEventKind] = [.sessionStart, .userPromptSubmit, .preToolUse, .postToolUse,
                                     .permissionRequest, .notification, .stop, .sessionEnd]
        for kind in kinds {
            #expect(try JSONDecoder().decode(HookEventKind.self, from: JSONEncoder().encode(kind)) == kind)
        }
    }

    @Test func allowOnceConsumesExactlyOneRequest() throws {
        let controller = AgentApprovalController(), responses = ApprovalResponses()
        let first = try #require(controller.ingestHookEvent(try event(), responder: { responses.record($0) }))
        let second = try #require(controller.ingestHookEvent(try event()))
        #expect(first.id != second.id)
        #expect(controller.submitDecision(.allowOnce, forRequestID: first.id))
        #expect(responses.values == [["decision": "approve"]])
        #expect(controller.pendingRequests() == [second])
        #expect(!controller.isSessionAutoApproved(for: first))
        #expect(!controller.submitDecision(.allowOnce, forRequestID: first.id))
        #expect(!controller.submitDecision(.deny(reason: nil), forRequestID: "missing"))
        #expect(responses.values.count == 1)
    }

    @Test func allowForSessionDrainsOnlyMatchingVerifiedToolRequests() throws {
        let controller = AgentApprovalController(), responses = ApprovalResponses()
        let payload = try event()
        let first = try #require(controller.ingestHookEvent(payload, scope: scope, isScopeCurrent: { true }, responder: { responses.record($0) }))
        controller.ingestHookEvent(payload, scope: scope, isScopeCurrent: { true }, responder: { responses.record($0) })
        let question = try #require(controller.ingestHookEvent(try question(), scope: scope, isScopeCurrent: { true }))
        let other = try #require(controller.ingestHookEvent(try event(fields: ["agent_name": "Codex", "pid": 88, "cwd": "/other"])))
        #expect(controller.canAutoApprove(request: first))
        #expect(!controller.canAutoApprove(request: question))
        #expect(!controller.canAutoApprove(request: other))
        #expect(!controller.submitDecision(.allowForSession, forRequestID: other.id))
        #expect(controller.submitDecision(.allowForSession, forRequestID: first.id))
        #expect(controller.isSessionAutoApproved(for: first))
        #expect(!controller.isSessionAutoApproved(for: other))
        #expect(controller.pendingRequests() == [question, other])
        #expect(responses.values == Array(repeating: ["decision": "approve"], count: 2))
        #expect(controller.ingestHookEvent(payload, scope: scope, isScopeCurrent: { true }, responder: { responses.record($0) }) == nil)
        #expect(responses.values.count == 3)
    }

    @Test func explicitAutoApproveCanBeRevoked() throws {
        let controller = AgentApprovalController(), responses = ApprovalResponses()
        let payload = try event()
        let request = try #require(controller.ingestHookEvent(payload, scope: scope, isScopeCurrent: { true },
                                                              responder: { responses.record($0) }))
        controller.setSessionAutoApprove(true, for: request)
        #expect(controller.activeAutoApproveRequests() == [request])
        #expect(responses.values == [["decision": "approve"]])
        controller.setSessionAutoApprove(false, for: request)
        #expect(controller.activeAutoApproveRequests().isEmpty)
        #expect(controller.ingestHookEvent(payload, scope: scope, isScopeCurrent: { true }) != nil)
    }

    @Test func denySerializesEscapedReasonAndOptionalReason() throws {
        for reason: String? in ["Do not run \"deploy\" \\ release", nil] {
            let controller = AgentApprovalController(), responses = ApprovalResponses()
            let request = try #require(controller.ingestHookEvent(try event(), responder: { responses.record($0) }))
            #expect(controller.submitDecision(.deny(reason: reason), forRequestID: request.id))
            var expected = ["decision": "block"]
            expected["reason"] = reason
            #expect(responses.values == [expected])
            #expect(controller.pendingRequests().isEmpty)
        }
    }

    @Test func nestedQuestionRequiresAnOfferedOption() throws {
        let controller = AgentApprovalController(), responses = ApprovalResponses()
        let request = try #require(controller.ingestHookEvent(try question(), responder: { responses.record($0) }))
        #expect(request.summary == "Which target?")
        #expect(request.questionOptions == ["Debug", "Release"])
        #expect(!controller.submitDecision(.allowOnce, forRequestID: request.id))
        #expect(!controller.submitDecision(.allowForSession, forRequestID: request.id))
        #expect(!controller.submitDecision(.answerQuestion(selectedOption: "Unlisted"), forRequestID: request.id))
        #expect(responses.values.isEmpty)
        #expect(controller.pendingRequests() == [request])
        #expect(controller.submitDecision(.answerQuestion(selectedOption: "Release"), forRequestID: request.id))
        #expect(responses.values == [["decision": "approve", "answer": "Release"]])
        #expect(controller.pendingRequests().isEmpty)
    }

    @Test func flatQuestionOptionsAndEmptyQuestionsNeverAutoApprove() throws {
        let controller = AgentApprovalController(), responses = ApprovalResponses()
        let request = try #require(controller.ingestHookEvent(try event(tool: "AskUserQuestion", input: [
            "question": "Continue?", "options": ["Yes", "No"]
        ]), responder: { responses.record($0) }))
        #expect(request.questionOptions == ["Yes", "No"])
        #expect(controller.submitDecision(.answerQuestion(selectedOption: "No"), forRequestID: request.id))
        #expect(responses.values == [["decision": "approve", "answer": "No"]])
        let empty = try #require(controller.ingestHookEvent(try event(tool: "AskUserQuestion", input: [:])))
        #expect(empty.questionOptions.isEmpty)
        #expect(!controller.submitDecision(.allowForSession, forRequestID: empty.id))
        #expect(controller.submitDecision(.deny(reason: nil), forRequestID: empty.id))
    }

    @Test func compoundQuestionsFailClosed() throws {
        let controller = AgentApprovalController(), responses = ApprovalResponses()
        for questions: [[String: Any]] in [[], [["question": "One"], ["question": "Two"]],
                                            [["question": "Several?", "multiSelect": true]]] {
            #expect(controller.ingestHookEvent(try event(tool: "AskUserQuestion", input: ["questions": questions]),
                                               responder: { responses.record($0) }) == nil)
        }
        #expect(controller.pendingRequests().isEmpty)
        #expect(responses.values.count == 3)
        #expect(responses.values.allSatisfy { $0["decision"] == "block" })
    }

    @Test func toolRequestsCannotBeAnsweredAsQuestions() throws {
        let controller = AgentApprovalController()
        let request = try #require(controller.ingestHookEvent(try event()))
        #expect(!controller.submitDecision(.answerQuestion(selectedOption: "Yes"), forRequestID: request.id))
        #expect(controller.pendingRequests() == [request])
    }

    @Test func ambiguousEmptyAndExcessiveOptionsFailClosed() throws {
        let controller = AgentApprovalController(), responses = ApprovalResponses()
        let choices = [["Yes", "Yes\n"], ["\u{0000}"], [String(repeating: "x", count: 513)],
                       (0..<33).map { "Option \($0)" }]
        for options in choices {
            #expect(controller.ingestHookEvent(try event(tool: "AskUserQuestion", input: [
                "question": "Which target?", "options": options
            ]), responder: { responses.record($0) }) == nil)
        }
        #expect(controller.pendingRequests().isEmpty)
        #expect(responses.values.count == choices.count)
        #expect(responses.values.allSatisfy { $0["decision"] == "block" })
    }

    @Test func questionAndDenialTextAreSanitized() throws {
        let controller = AgentApprovalController(), responses = ApprovalResponses()
        let request = try #require(controller.ingestHookEvent(try event(tool: "AskUserQuestion", input: [
            "question": "Build\ntarget?", "options": ["De\u{202E}bug", "Release"]
        ]), responder: { responses.record($0) }))
        #expect(request.summary == "Build target?")
        #expect(request.questionOptions == ["De bug", "Release"])
        #expect(controller.submitDecision(.answerQuestion(selectedOption: "De bug"), forRequestID: request.id))
        #expect(responses.values == [["decision": "approve", "answer": "De bug"]])
        let denied = try #require(controller.ingestHookEvent(try event(), responder: { responses.record($0) }))
        #expect(controller.submitDecision(.deny(reason: "No\npermission\u{0000}"), forRequestID: denied.id))
        #expect(responses.values.last == ["decision": "block", "reason": "No permission"])
    }

    @Test func revokedLifetimeBlocksQueuedRequests() throws {
        let controller = AgentApprovalController(), responses = ApprovalResponses()
        let lifetime = ApprovalLifetime()
        let payload = try event()
        let request = try #require(controller.ingestHookEvent(payload, scope: scope, isScopeCurrent: { lifetime.active },
                                                              responder: { responses.record($0) }))
        lifetime.revoke()
        #expect(!controller.canAutoApprove(request: request))
        #expect(!controller.submitDecision(.allowOnce, forRequestID: request.id))
        #expect(!controller.submitDecision(.allowForSession, forRequestID: request.id))
        #expect(controller.pruneExpiredRequests() == 1)
        #expect(responses.values.first?["decision"] == "block")
        #expect(controller.pendingRequests().isEmpty)
    }

    @Test func scopedStopCancelsOnlyRequestsFromEarlierInTheSameTurn() throws {
        let controller = AgentApprovalController(), responses = ApprovalResponses()
        let request = try question()
        controller.ingestHookEvent(request, scope: scope, now: now.addingTimeInterval(-1), isScopeCurrent: { true },
                                   responder: { responses.record($0) })
        controller.ingestHookEvent(request, scope: scope, now: now.addingTimeInterval(1), isScopeCurrent: { true },
                                   responder: { responses.record($0) })
        controller.ingestHookEvent(try event(.stop), scope: scope, now: now, isScopeCurrent: { true })
        #expect(controller.pendingRequests().count == 1)
        #expect(responses.values.first?["decision"] == "block")
    }

    @Test func notificationEventsAreIgnoredAndPreToolUseIsExplicitlyGated() throws {
        let controller = AgentApprovalController(), responses = ApprovalResponses()
        for kind: HookEventKind in [.sessionStart, .userPromptSubmit, .postToolUse, .notification] {
            #expect(controller.ingestHookEvent(try event(kind), responder: { responses.record($0) }) == nil)
        }
        #expect(controller.ingestHookEvent(try event(.preToolUse, fields: ["requires_approval": false])) == nil)
        #expect(controller.ingestHookEvent(try event(.preToolUse)) != nil)
        #expect(controller.ingestHookEvent(try event(.permissionRequest, fields: ["requires_approval": false])) != nil)
        #expect(controller.pendingRequests().count == 2)
        #expect(responses.values.isEmpty)
    }

    @Test func rejectsMalformedOversizedAndInvalidIdentifiers() throws {
        let controller = AgentApprovalController(), responses = ApprovalResponses()
        let payloads = [Data(), Data("{broken".utf8), Data("[]".utf8), Data("null".utf8),
                        Data(#"{"hook_event_name":"Unknown","session_id":"session-1"}"#.utf8),
                        Data(#"{"hook_event_name":"PermissionRequest"}"#.utf8),
                        try event(fields: ["pid": true]), try event(fields: ["tool_name": NSNull()]),
                        try event(fields: ["tool_input": ["options": [123]]]),
                        Data(repeating: 32, count: 65_537)]
        for payload in payloads {
            #expect(controller.ingestHookEvent(payload, responder: { responses.record($0) }) == nil)
        }
        for id in ["", " ", " session-1", "session-1\n", "session\u{202E}-1", String(repeating: "s", count: 257)] {
            #expect(controller.ingestHookEvent(try event(session: id), responder: { responses.record($0) }) == nil)
        }
        #expect(controller.pendingRequests().isEmpty)
        #expect(responses.values.count == payloads.count + 6)
        #expect(responses.values.allSatisfy { $0["decision"] == "block" })
    }

    @Test func acceptsExactly64KiBAndRejectsOneByteMore() throws {
        let controller = AgentApprovalController(), responses = ApprovalResponses()
        var data = try event()
        data.append(Data(repeating: 32, count: 65_536 - data.count))
        #expect(controller.ingestHookEvent(data) != nil)
        data.append(32)
        #expect(controller.ingestHookEvent(data, responder: { responses.record($0) }) == nil)
        #expect(controller.pendingRequests().count == 1)
        #expect(responses.values.first?["decision"] == "block")
    }

    @Test func sanitizesAndBoundsDisplayFieldsAndUsesClientFallback() throws {
        let controller = AgentApprovalController()
        let request = try #require(controller.ingestHookEvent(try event(input: ["file_path": "/src/\nfile.swift"], fields: [
            "agent_name": "", "client": "Codex\u{001B}", "cwd": "/workspace/\u{202E}sample", "pid": -1
        ])))
        #expect(request.agentName == "Codex")
        #expect(request.summary == "/src/ file.swift")
        #expect(request.projectPath == "/workspace/ sample")
        #expect(request.pid == nil)
        let long = try #require(controller.ingestHookEvent(try event(input: ["command": String(repeating: "x", count: 2_000)])))
        #expect(long.summary.count == 1_024)
        let fallback = try #require(controller.ingestHookEvent(try event(input: [:], fields: [
            "agent_name": NSNull(), "cwd": NSNull(), "pid": NSNull()
        ])))
        #expect(fallback.agentName == "Unknown")
        #expect(fallback.summary == "Bash")
        #expect(fallback.projectPath == nil)
    }

    @Test func overflowBlocksNewestWithoutEvictingWaiters() throws {
        let controller = AgentApprovalController(), responses = ApprovalResponses()
        let payload = try event()
        for _ in 0..<50 { #expect(controller.ingestHookEvent(payload) != nil) }
        let original = controller.pendingRequests()
        #expect(controller.ingestHookEvent(payload, responder: { responses.record($0) }) == nil)
        #expect(controller.pendingRequests() == original)
        #expect(responses.values.first?["decision"] == "block")
        #expect(controller.submitDecision(.deny(reason: nil), forRequestID: original[0].id))
        #expect(controller.ingestHookEvent(payload) != nil)
        #expect(controller.pendingRequests().count == 50)
    }

    @Test func callbacksMayReenterControllerAfterStateTransition() throws {
        let controller = AgentApprovalController(), responses = ApprovalResponses()
        let request = try #require(controller.ingestHookEvent(try event(), scope: scope, isScopeCurrent: { true }, responder: { data in
            #expect(controller.pendingRequests().isEmpty)
            if let grant = controller.activeAutoApproveRequests().first {
                controller.setSessionAutoApprove(false, for: grant)
            } else {
                Issue.record("Grant should be present when its response is delivered")
            }
            responses.record(data)
        }))
        #expect(controller.submitDecision(.allowForSession, forRequestID: request.id))
        #expect(responses.values == [["decision": "approve"]])
        #expect(controller.activeAutoApproveRequests().isEmpty)
    }

    @Test func concurrentIngestionAndDuplicateDecisionsRespondExactlyOnce() throws {
        let controller = AgentApprovalController(), responses = ApprovalResponses()
        let payload = try event()
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            controller.ingestHookEvent(payload, responder: { responses.record($0) })
            #expect(controller.pendingRequests().count <= 50)
        }
        let pending = controller.pendingRequests()
        #expect(pending.count == 50)
        #expect(Set(pending.map(\.id)).count == 50)
        #expect(responses.values.count == 150)
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            controller.submitDecision(.allowOnce, forRequestID: pending[index % 50].id)
        }
        #expect(controller.pendingRequests().isEmpty)
        #expect(responses.values.count == 200)
        #expect(responses.values.filter { $0["decision"] == "approve" }.count == 50)
    }

    @Test func concurrentAutoApprovalAndRevocationDoNotLoseResponders() throws {
        let controller = AgentApprovalController(), responses = ApprovalResponses()
        let payload = try event()
        DispatchQueue.concurrentPerform(iterations: 300) { index in
            if let request = controller.ingestHookEvent(payload, scope: scope, isScopeCurrent: { true },
                                                        responder: { responses.record($0) }), index % 2 == 0 {
                controller.setSessionAutoApprove(true, for: request)
            }
            for grant in controller.activeAutoApproveRequests() {
                controller.setSessionAutoApprove(false, for: grant)
            }
            #expect(controller.pendingRequests().count <= 50)
        }
        for request in controller.pendingRequests() {
            controller.submitDecision(.deny(reason: nil), forRequestID: request.id)
        }
        #expect(controller.pendingRequests().isEmpty)
        #expect(responses.values.count == 300)
    }

    @Test func snippetQuotesShellMetacharactersAndRejectsUnsafePaths() {
        let snippet = AgentApprovalController.hookSnippet(for: "Claude Code", bridgeExecutablePath: "/tools/bridge name")
        #expect(snippet == "# Claude Code hook command; pass hook JSON on stdin.\n'/tools/bridge name'")
        let quoted = AgentApprovalController.hookSnippet(for: "Codex\ninvalid", bridgeExecutablePath: "/tools/it's $(false);bridge")
        #expect(quoted == "# Codex invalid hook command; pass hook JSON on stdin.\n'/tools/it'\"'\"'s $(false);bridge'")
        for path in ["", "relative/bridge", "/tools/bridge\nfalse", "/tools/bridge\u{0000}", "/" + String(repeating: "x", count: 4_096)] {
            let result = AgentApprovalController.hookSnippet(for: "Claude Code", bridgeExecutablePath: path)
            #expect(result.hasPrefix("# An absolute bridge"))
            #expect(!result.contains("\n"))
        }
    }
}
