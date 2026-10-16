import XCTest
@testable import AgentHUDCore

/// Each client's declaration holds to what exists: the hooks installed for it, the observers that run, the readers its
/// provider uses.
final class ClientDeclarationTests: XCTestCase {
    private let permissionHook = ClientDeclaration.Channel.hook("PermissionRequest")

    func testEveryClientHasOneDeclaration() {
        XCTAssertEqual(ClientDeclarations.all.map(\.client), AgentClient.allCases)
    }

    func testTheClientsWithSessionsAreTheAgentsTheSessionsAreGroupedUnder() {
        XCTAssertEqual(Set(AgentClient.allCases.compactMap(\.sessionVendor)), Set(SessionSource.agentVendors))
        for client in AgentClient.allCases {
            XCTAssertEqual(client.sessionVendor != nil, !ClientDeclarations[client].sessions.isEmpty, client.rawValue)
        }
    }

    func testTheLogsReadFromASavedPositionAreTheDeclaredAppendedOnes() {
        let appended = AgentClient.allCases.filter { client in
            ClientDeclarations[client].sessions.contains { if case .appended = $0 { true } else { false } }
        }
        XCTAssertEqual(Set(appended.map(\.rawValue)), [ClaudeTranscripts.source, CodexRollouts.source, HarnessLogs.source])
    }

    func testAnApprovalArrivesThroughThePermissionHookExactlyWhereOneIsInstalled() {
        for source in PermissionHooks.Source.allCases {
            let hooked = ClientDeclarations[source.client].requests.contains { $0.kind == .approval && $0.arrives == permissionHook }
            XCTAssertEqual(hooked, source.usesHook, source.rawValue)
        }
        let hookClients = Set(PermissionHooks.Source.allCases.filter(\.usesHook).map(\.client))
        for declaration in ClientDeclarations.all where !hookClients.contains(declaration.client) {
            XCTAssertFalse(declaration.channels.contains(permissionHook), declaration.client.rawValue)
        }
    }

    func testAlwaysAllowGoesBackThroughTheHookOnlyWhereTheClientAppliesARule() {
        for source in PermissionHooks.Source.allCases where source.usesHook {
            let approval = ClientDeclarations[source.client].requests.first { $0.kind == .approval && $0.arrives == permissionHook }
            XCTAssertEqual(approval?.answers.contains(.allowAlways), source.supportsPermissionUpdates, source.rawValue)
        }
    }

    /// Codex's hook never carries a question or a plan: Desktop's come from the thread it owns.
    func testAQuestionOrAPlanComesThroughTheHookOnlyWhereTheHUDDoesNotLeaveItToTheClient() {
        for source in PermissionHooks.Source.allCases where source.usesHook && source != .codex {
            let tools = source == .qwen ? (question: "ask_user_question", plan: "exit_plan_mode")
                : (question: "AskUserQuestion", plan: PermissionRequest.planTool)
            let kinds = Set(ClientDeclarations[source.client].requests.filter { $0.arrives == permissionHook }.map(\.kind))
            XCTAssertEqual(kinds.contains(.question), !source.unanswerableTools.contains(tools.question), source.rawValue)
            XCTAssertEqual(kinds.contains(.plan), !source.unanswerableTools.contains(tools.plan), source.rawValue)
        }
    }

    func testTheNativeObserversAreDeclaredAsTheChannelsTheyFollow() {
        XCTAssertEqual(ClientDeclarations[.antigravity].requests.map(\.arrives), [.poll("language server trajectories", every: 2)])
        XCTAssertTrue(ClientDeclarations[.codex].requests.contains { $0.arrives == .subscription("Codex Desktop thread") && $0.kind == .question })
        XCTAssertEqual(ClientDeclarations[.deepseek].requests.map(\.kind), [.question])
    }

    func testAStopHookIsDeclaredExactlyForTheClientsItIsInstalledFor() {
        let stopped = Set(CompletionHooks.Source.allCases.map(\.client))
        for declaration in ClientDeclarations.all {
            let hooked = (declaration.state[.waitingForReply] ?? []).contains { if case .hook = $0 { true } else { false } }
            XCTAssertEqual(hooked, stopped.contains(declaration.client), declaration.client.rawValue)
        }
    }

    func testTheAttentionHookIsDeclaredOnlyForClaudeCode() {
        let attention = AgentClient.allCases.filter { ClientDeclarations[$0].channels.contains(.hook("Notification")) }
        XCTAssertEqual(attention, AttentionHooks.Source.allCases.map { AgentClient(rawValue: $0.rawValue)! })
    }

    func testEveryRequestCanBeAnsweredOrIsAPlan() {
        for declaration in ClientDeclarations.all {
            for request in declaration.requests where request.kind != .plan {
                XCTAssertFalse(request.answers.isEmpty, "\(declaration.client.rawValue) \(request.kind.rawValue)")
            }
        }
    }

    /// The clients still read whole, which move onto appended reads one at a time; each move updates this list.
    func testTheClientsBelowTheBaselineAreTheOnesStillToMove() {
        let below = AgentClient.allCases.filter { !ClientDeclarations[$0].belowBaseline.isEmpty }
        XCTAssertEqual(below, [.antigravity, .grokCLI, .grokBot, .copilot, .openclaw, .hermes, .zcode, .codebuddy, .workbuddy,
                               .qwen, .opencode, .kimi, .pi])
    }
}
