import Foundation

/// Managed Codex App runtime built on the public App Server protocol.
/// The stable thread and turn identifiers are written back to the card by the
/// launch scheduler's caller.
public actor CodexAppServerRuntime: CodexRuntimePort {
    public nonisolated let backend: CodexRuntimeBackend = .app

    private let client: CodexAppServerClient
    private var initialized = false

    public init(client: CodexAppServerClient) {
        self.client = client
    }

    public func launch(_ request: CodexRuntimeLaunchRequest) async throws -> CodexRuntimeLaunchReceipt {
        do {
            try await ensureInitialized()
        } catch {
            throw CodexRuntimeError.unavailable(
                "Codex App Server could not initialize: \(error.localizedDescription)"
            )
        }

        let thread: CodexThread
        do {
            thread = try await client.startThread(cwd: request.projectPath)
        } catch {
            throw CodexRuntimeError.launchUncertain(
                "Codex App thread creation could not be acknowledged: \(error.localizedDescription)"
            )
        }

        let partialBinding = CodexExecutionBinding(
            backend: .app,
            ownership: .managed,
            evidence: .boardCreated,
            telemetryQuality: .limited,
            threadId: thread.id,
            boundAt: .now
        )
        do {
            let managedPrompt = CodexManagedPrompt.withReviewReadyInstruction(
                request.prompt,
                request: request,
                backend: .app,
                sessionID: thread.id
            )
            let turn = try await client.startTurn(threadID: thread.id, text: managedPrompt)
            return CodexRuntimeLaunchReceipt(binding: CodexExecutionBinding(
                backend: .app,
                ownership: .managed,
                evidence: .boardCreated,
                telemetryQuality: .precise,
                threadId: thread.id,
                turnId: turn.id,
                boundAt: .now
            ))
        } catch {
            throw CodexRuntimeError.partialLaunch(
                "Codex App thread \(thread.id) was created, but its first turn could not be acknowledged: \(error.localizedDescription)",
                partialBinding
            )
        }
    }

    public func recover(_ request: CodexRuntimeRecoveryRequest) async -> CodexRuntimeRecoveryResult {
        guard let binding = request.binding, let threadID = binding.threadId else {
            return .uncertain("The persisted App launch has no stable thread binding")
        }
        do {
            try await ensureInitialized()
            let thread = try await client.resumeThread(id: threadID)
            let recovered = CodexExecutionBinding(
                backend: .app,
                ownership: .managed,
                evidence: .boardCreated,
                telemetryQuality: .precise,
                threadId: thread.id,
                turnId: binding.turnId,
                boundAt: binding.boundAt
            )
            switch thread.status?.type {
            case "idle", "completed", "stopped":
                return .stopped(recovered)
            default:
                return .running(recovered)
            }
        } catch {
            return .uncertain("Could not reconcile Codex App thread \(threadID): \(error.localizedDescription)")
        }
    }

    public func sendFeedback(_ request: CodexRuntimeFeedbackRequest) async throws {
        guard request.binding.backend == .app,
              let threadID = request.binding.threadId else {
            throw CodexRuntimeError.invalidBinding("The task has no Codex App thread binding")
        }
        try await ensureInitialized()
        // Review feedback starts a new turn. Steering is reserved for a turn
        // that is still active; an In Review turn has already completed.
        _ = try await client.startTurn(threadID: threadID, text: request.body)
    }

    private func ensureInitialized() async throws {
        guard !initialized else { return }
        await client.start()
        _ = try await client.initialize(clientName: "kanban-code", clientVersion: "0.1.1")
        initialized = true
    }
}
