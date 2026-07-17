import Foundation
import Testing
@testable import KanbanCodeCore

@Suite("Codex CLI tmux runtime")
struct CodexCLITmuxRuntimeTests {
    final class FakeTmux: TmuxManagerPort, @unchecked Sendable {
        var sessions: [TmuxSession] = []
        var created: [(String, String, String?)] = []
        var prompts: [(String, String)] = []
        var available = true
        var createError: Error?
        var promptError: Error?

        func listSessions() async throws -> [TmuxSession] { sessions }
        func createSession(name: String, path: String, command: String?) async throws {
            if let createError { throw createError }
            created.append((name, path, command))
            sessions.append(TmuxSession(name: name, path: path, attached: false))
        }
        func killSession(name: String) async throws {}
        func sendPrompt(to sessionName: String, text: String) async throws {}
        func pastePrompt(to sessionName: String, text: String) async throws {
            if let promptError { throw promptError }
            prompts.append((sessionName, text))
        }
        func pasteText(to sessionName: String, text: String) async throws {}
        func submitPrompt(to sessionName: String) async throws {}
        func capturePane(sessionName: String) async throws -> String { "" }
        func sendBracketedPaste(to sessionName: String) async throws {}
        func findSessionForWorktree(sessions: [TmuxSession], worktreePath: String, branch: String?) -> TmuxSession? { nil }
        func isAvailable() async -> Bool { available }
    }

    final class FakeMetadata: CodexTmuxMetadataPort, @unchecked Sendable {
        var tags: [String: CodexTmuxOwnershipTag] = [:]
        var setError: Error?

        func ownershipTag(for sessionName: String) async throws -> CodexTmuxOwnershipTag? {
            tags[sessionName]
        }

        func setOwnershipTag(_ tag: CodexTmuxOwnershipTag, for sessionName: String) async throws {
            if let setError { throw setError }
            tags[sessionName] = tag
        }
    }

    private func request(cardId: String = "card-1", attempt: String = "attempt-1", generation: Int = 1) -> CodexRuntimeLaunchRequest {
        CodexRuntimeLaunchRequest(
            cardId: cardId,
            attemptId: attempt,
            generation: generation,
            lifecycleCapability: String(repeating: "a", count: 64),
            projectPath: "/tmp/project",
            prompt: "implement it"
        )
    }

    @Test("Launch uses reserved namespace, tags ownership, then submits prompt")
    func launchContract() async throws {
        let tmux = FakeTmux()
        let metadata = FakeMetadata()
        let runtime = CodexCLITmuxRuntime(
            tmux: tmux,
            metadata: metadata,
            codexExecutablePath: "/opt/homebrew/bin/codex"
        )

        let receipt = try await runtime.launch(request())
        let name = "kanban-code-card-1-1"

        #expect(tmux.created.count == 1)
        #expect(tmux.created.first?.0 == name)
        #expect(tmux.created.first?.2?.contains("KANBAN_CODE_CARD_ID='card-1'") == true)
        #expect(tmux.created.first?.2?.contains("KANBAN_CODE_LIFECYCLE_CAPABILITY='\(String(repeating: "a", count: 64))'") == true)
        #expect(tmux.created.first?.2?.hasSuffix("'/opt/homebrew/bin/codex' --no-alt-screen") == true)
        #expect(metadata.tags[name] == .init(cardId: "card-1", attemptId: "attempt-1", generation: 1))
        #expect(tmux.prompts.first?.0 == name)
        #expect(tmux.prompts.first?.1.contains("implement it") == true)
        #expect(tmux.prompts.first?.1.contains("review-ready") == true)
        #expect(receipt.binding.tmuxSessionName == name)
        #expect(receipt.binding.ownership == .managed)
    }

    @Test("Same lease is idempotent and never submits the prompt twice")
    func sameLeaseIsIdempotent() async throws {
        let tmux = FakeTmux()
        let metadata = FakeMetadata()
        let name = "kanban-code-card-1-1"
        tmux.sessions = [TmuxSession(name: name, path: "/tmp/project", attached: false)]
        metadata.tags[name] = .init(cardId: "card-1", attemptId: "attempt-1", generation: 1)
        let runtime = CodexCLITmuxRuntime(tmux: tmux, metadata: metadata)

        _ = try await runtime.launch(request())

        #expect(tmux.created.isEmpty)
        #expect(tmux.prompts.isEmpty)
    }

    @Test("Reserved-name collision without matching ownership is rejected")
    func collisionRejected() async {
        let tmux = FakeTmux()
        let metadata = FakeMetadata()
        let name = "kanban-code-card-1-1"
        tmux.sessions = [TmuxSession(name: name, path: "/tmp/other", attached: false)]
        metadata.tags[name] = .init(cardId: "other", attemptId: "other", generation: 1)
        let runtime = CodexCLITmuxRuntime(tmux: tmux, metadata: metadata)

        do {
            _ = try await runtime.launch(request())
            Issue.record("Expected ownership conflict")
        } catch let error as CodexRuntimeError {
            #expect(error == .ownershipConflict(
                "Refusing to reuse \(name): its ownership tag does not match this launch attempt"
            ))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(tmux.created.isEmpty)
    }

    @Test("Recovery distinguishes absent, owned, and ambiguous sessions")
    func recoveryContract() async {
        let tmux = FakeTmux()
        let metadata = FakeMetadata()
        let runtime = CodexCLITmuxRuntime(tmux: tmux, metadata: metadata)
        let lease = LaunchLease(attemptId: "attempt-1", backend: .cliTmux, generation: 1)
        let recovery = CodexRuntimeRecoveryRequest(cardId: "card-1", lease: lease)

        #expect(await runtime.recover(recovery) == .notStarted)

        let name = "kanban-code-card-1-1"
        tmux.sessions = [TmuxSession(name: name, path: "/tmp/project", attached: false)]
        if case .uncertain = await runtime.recover(recovery) {} else {
            Issue.record("Expected missing metadata to be uncertain")
        }

        metadata.tags[name] = .init(cardId: "card-1", attemptId: "attempt-1", generation: 1)
        if case .running(let binding) = await runtime.recover(recovery) {
            #expect(binding.tmuxSessionName == name)
        } else {
            Issue.record("Expected owned session to recover as running")
        }
    }

    @Test("Failure after tmux creation is classified as launch uncertain")
    func postCreationFailureIsUncertain() async {
        struct TestError: Error {}
        let tmux = FakeTmux()
        let metadata = FakeMetadata()
        metadata.setError = TestError()
        let runtime = CodexCLITmuxRuntime(tmux: tmux, metadata: metadata)

        do {
            _ = try await runtime.launch(request())
            Issue.record("Expected launch failure")
        } catch let error as CodexRuntimeError {
            #expect(error.mayHaveStartedWork)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(tmux.sessions.count == 1)
    }

    @Test("Feedback is only sent to the card-owned binding")
    func feedbackOwnership() async throws {
        let tmux = FakeTmux()
        let metadata = FakeMetadata()
        let name = "kanban-code-card-1-1"
        tmux.sessions = [TmuxSession(name: name, path: "/tmp/project", attached: false)]
        metadata.tags[name] = .init(cardId: "card-1", attemptId: "attempt-1", generation: 1)
        let runtime = CodexCLITmuxRuntime(tmux: tmux, metadata: metadata)
        let binding = CodexExecutionBinding(
            backend: .cliTmux,
            ownership: .managed,
            evidence: .boardCreated,
            telemetryQuality: .limited,
            tmuxSessionName: name
        )

        try await runtime.sendFeedback(.init(cardId: "card-1", binding: binding, body: "revise"))
        #expect(tmux.prompts.last?.1 == "revise")
    }
}
